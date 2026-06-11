<#
    .SYNOPSIS
    Detects drift in the Microsoft Secure Score and emails a report when changes are found. Designed to run standalone in an Azure Automation account using a Managed Identity.
    .DESCRIPTION
    Authenticates to Microsoft Graph using the Managed Identity of the host (Azure Automation / VM / App Service) through
    direct HTTPS calls (no module dependencies). Retrieves secure score snapshots for today and DaysBack days ago (skipping
    anything in between) plus the current control profiles, then compares them. When drift is detected, an HTML report is emailed
    via Graph sendMail with a click-through to the Secure Score portal.

    Drift that is reported:
    - Overall score changes (above the threshold)
    - Product (service) score changes (above the threshold), new or removed products
    - New or removed controls (recommendations)
    - Per-control score changes (above the threshold)
    - Exclusion/inclusion changes (control marked as Ignored / Third Party / Reviewed / Default since the previous snapshot)

    Deliberately ignored (noise):
    - Max score changes, snapshot/retrieval datetimes, user counts, comparative averages
    - Implementation status texts: Graph only populates the dynamic values (counts, true/false) in the most recent
      snapshot, older snapshots contain blanked-out template text, so comparing these always yields false positives.
      Real status changes surface as score changes instead.
    - Score changes smaller than ScoreChangeThreshold: device-percentage based controls drift fractionally every day
      as device/user counts fluctuate, which isn't worth a notification.
    .PARAMETER MailTo
    Email address (or comma separated addresses) that receives the drift report.
    .PARAMETER MailFrom
    UPN of the mailbox the report is sent from. The Managed Identity needs Mail.Send permission (ideally scoped to this mailbox with an application access policy).
    .PARAMETER DaysBack
    How many days back to use as the comparison baseline. Default is 1 (compare today against yesterday). Use 7 to compare today against the same day last week. Only the two endpoint snapshots are compared; anything in between is ignored.
    .PARAMETER ScoreChangeThreshold
    Minimum score change (in points) before it is reported as drift. Defaults to 0.5, which suppresses the daily fractional wobble of device-count based controls.
    .EXAMPLE
    .\get-secureScores.ps1 -MailTo "soc@contoso.com" -MailFrom "automation@contoso.com"
    .EXAMPLE
    .\get-secureScores.ps1 -MailTo "soc@contoso.com" -MailFrom "automation@contoso.com" -DaysBack 7
    .NOTES
    Author: Jos Lieben / Lieben Consultancy
    Website: https://www.lieben.nu
    Free for non-commercial use. Commercial use requires a license:
    https://www.lieben.nu/liebensraum/commercial-use/

    Required Graph application permissions for the Managed Identity:
    - SecurityEvents.Read.All
    - Mail.Send
    
    Use https://lieben.nu/tools/SPNRoleMgr to easily assign above permissions to the managed identity of your automation account
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)][string]$MailTo,
    [Parameter(Mandatory = $true)][string]$MailFrom,
    [ValidateRange(1, 89)][int]$DaysBack = 1,
    [double]$ScoreChangeThreshold = 0.5
)

$ErrorActionPreference = 'Stop'

#friendly names for the 'service' property on control profiles, so reports group by recognizable product names
$productDisplayNames = @{
    "AzureAD"             = "Microsoft Entra ID"
    "AAD"                 = "Microsoft Entra ID"
    "MDI"                 = "Defender for Identity"
    "AzureATP"            = "Defender for Identity"
    "MDE"                 = "Defender for Endpoint"
    "MDATP"               = "Defender for Endpoint"
    "WindowsDefenderATP"  = "Defender for Endpoint"
    "EXO"                 = "Exchange Online"
    "Exchange"            = "Exchange Online"
    "MDO"                 = "Defender for Office 365"
    "OfficeATP"           = "Defender for Office 365"
    "SPO"                 = "SharePoint Online"
    "SharePoint"          = "SharePoint Online"
    "Teams"               = "Microsoft Teams"
    "MicrosoftTeams"      = "Microsoft Teams"
    "Skype"               = "Skype for Business"
    "OneDrive"            = "OneDrive for Business"
    "MIP"                 = "Purview Information Protection"
    "MCAS"                = "Defender for Cloud Apps"
    "Intune"              = "Microsoft Intune"
    "MEM"                 = "Microsoft Intune"
    "DLP"                 = "Purview DLP"
    "M365"                = "Microsoft 365"
    "App Governance"      = "App Governance"
}

function Get-ProductDisplayName {
    param([string]$Service)
    if ([string]::IsNullOrWhiteSpace($Service)) { return "Unknown" }
    if ($productDisplayNames.ContainsKey($Service)) { return $productDisplayNames[$Service] }
    return $Service
}

function Get-GraphToken {
    #acquires a Graph token using the Managed Identity, without any module dependencies
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        #Azure Automation / App Service style managed identity endpoint
        $uri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com/&api-version=2019-08-01"
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER; "Metadata" = "True" }
    } else {
        #Azure VM / VMSS IMDS endpoint
        $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com/"
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ "Metadata" = "true" }
    }
    if (-not $response.access_token) {
        Throw "Failed to acquire a Graph token using the Managed Identity"
    }
    return $response.access_token
}

function Invoke-GraphRequest {
    #thin wrapper around Invoke-RestMethod with auth header and basic throttling retry
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $null
    )

    $attempts = 0
    while ($true) {
        $attempts++
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = @{ "Authorization" = "Bearer $($script:graphToken)" }
                ContentType = "application/json; charset=utf-8"
            }
            if ($Body) {
                $params["Body"] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 15))
            }
            return Invoke-RestMethod @params
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            if ($statusCode -in @(429, 503, 504) -and $attempts -lt 5) {
                $retryAfter = 10
                try { $retryAfter = [int]($_.Exception.Response.Headers.GetValues("Retry-After") | Select-Object -First 1) } catch {}
                Write-Output "Graph returned $statusCode, retrying in $retryAfter seconds (attempt $attempts)..."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            Throw $_
        }
    }
}

function Get-GraphCollection {
    #retrieves all pages of a Graph collection
    param([Parameter(Mandatory = $true)][string]$Uri)

    $items = @()
    $nextLink = $Uri
    while ($nextLink) {
        $response = Invoke-GraphRequest -Uri $nextLink
        if ($response.value) {
            $items += $response.value
        }
        $nextLink = $response.'@odata.nextLink'
    }
    return $items
}

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Format-Score {
    param($Value)
    if ($null -eq $Value) { return "-" }
    return [math]::Round([double]$Value, 2).ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-ScoreDelta {
    #renders 'old -> new (+x.xx)' with a colored arrow
    param($OldValue, $NewValue)
    $delta = [math]::Round(([double]$NewValue - [double]$OldValue), 2)
    $color = if ($delta -ge 0) { "#107c10" } else { "#d13438" }
    $arrow = if ($delta -ge 0) { "&#9650;" } else { "&#9660;" }
    $sign = if ($delta -ge 0) { "+" } else { "" }
    return "$(Format-Score $OldValue) &rarr; $(Format-Score $NewValue) <span style=`"color:$color;font-weight:bold;`">$arrow $sign$delta</span>"
}

# --- Connect to Microsoft Graph using the Managed Identity ---
Write-Output "Acquiring Graph token using Managed Identity..."
$script:graphToken = Get-GraphToken
Write-Output "Token acquired"

# --- Retrieve control profiles (metadata: title, product, remediation, state) ---
Write-Output "Retrieving secure score control profiles..."
$controlProfiles = Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/security/secureScoreControlProfiles?`$top=400"
Write-Output "Retrieved $($controlProfiles.Count) control profiles"

#index profiles by id for fast lookup when merging with the score snapshots
$profilesById = @{}
foreach ($controlProfile in $controlProfiles) {
    $profilesById[$controlProfile.id] = $controlProfile
}

# --- Retrieve snapshots: today + DaysBack days ago (only those two are compared) ---
$fetchCount = $DaysBack + 1
Write-Output "Retrieving $fetchCount secure score snapshots to compare today against $DaysBack day(s) ago..."
$secureScores = Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/security/secureScores?`$top=$fetchCount"
$secureScores = @($secureScores | Sort-Object createdDateTime -Descending | Select-Object -First $fetchCount)
if ($secureScores.Count -lt $fetchCount) {
    Write-Output "Only $($secureScores.Count) snapshot(s) available; need $fetchCount to compare today against $DaysBack day(s) ago. Exiting."
    return
}
$currentSnapshot = $secureScores[0]
$previousSnapshot = $secureScores[$DaysBack]
$tenantId = $currentSnapshot.azureTenantId
Write-Output "Comparing snapshot $($previousSnapshot.createdDateTime) ($DaysBack day(s) ago) with $($currentSnapshot.createdDateTime) (today)"

# --- Normalize both snapshots into comparable structures ---
function ConvertTo-NormalizedSnapshot {
    param($Snapshot, $ProfilesById)

    #implementationStatus is deliberately not captured: Graph only fills in its dynamic values (counts, true/false)
    #for the most recent snapshot, so cross-snapshot comparison of that field always yields false positives
    $controls = @{}
    foreach ($controlScore in $Snapshot.controlScores) {
        $controlProfile = $ProfilesById[$controlScore.controlName]
        $controls[$controlScore.controlName] = [PSCustomObject]@{
            controlName  = $controlScore.controlName
            title        = if ($controlProfile -and $controlProfile.title) { $controlProfile.title } else { $controlScore.controlName }
            product      = Get-ProductDisplayName -Service $(if ($controlProfile) { $controlProfile.service } else { $null })
            category     = $controlScore.controlCategory
            currentScore = [math]::Round([double]$controlScore.score, 2)
            deprecated   = if ($controlProfile) { [bool]$controlProfile.deprecated } else { $false }
        }
    }

    #aggregate per product, deprecated controls excluded so retired items don't skew product totals
    $productScores = @{}
    foreach ($group in ($controls.Values | Where-Object { -not $_.deprecated } | Group-Object product)) {
        $productScores[$group.Name] = [math]::Round(($group.Group | Measure-Object currentScore -Sum).Sum, 2)
    }

    return [PSCustomObject]@{
        snapshotDateTime = $Snapshot.createdDateTime
        currentScore     = [math]::Round([double]$Snapshot.currentScore, 2)
        maxScore         = [math]::Round([double]$Snapshot.maxScore, 2)
        controls         = $controls
        productScores    = $productScores
    }
}

$current = ConvertTo-NormalizedSnapshot -Snapshot $currentSnapshot -ProfilesById $profilesById
$previous = ConvertTo-NormalizedSnapshot -Snapshot $previousSnapshot -ProfilesById $profilesById

# --- Drift detection ---
#each drift entry: Category, Item, Detail (pre-escaped HTML in Detail where noted)
$driftItems = [System.Collections.Generic.List[object]]::new()

#1) overall score change (max score changes and datetime fields are deliberately ignored as noise)
if ([math]::Abs($current.currentScore - $previous.currentScore) -ge $ScoreChangeThreshold) {
    $driftItems.Add([PSCustomObject]@{
        Category   = "Overall score"
        Item       = "Total secure score"
        DetailHtml = Format-ScoreDelta -OldValue $previous.currentScore -NewValue $current.currentScore
    })
}

#2) product level: new/removed products and product score changes
$allProducts = @($previous.productScores.Keys) + @($current.productScores.Keys) | Sort-Object -Unique
foreach ($product in $allProducts) {
    $inPrevious = $previous.productScores.ContainsKey($product)
    $inCurrent = $current.productScores.ContainsKey($product)
    if ($inCurrent -and -not $inPrevious) {
        $driftItems.Add([PSCustomObject]@{
            Category   = "Products"
            Item       = ConvertTo-HtmlSafe $product
            DetailHtml = "New product detected (score $(Format-Score $current.productScores[$product]))"
        })
    } elseif ($inPrevious -and -not $inCurrent) {
        $driftItems.Add([PSCustomObject]@{
            Category   = "Products"
            Item       = ConvertTo-HtmlSafe $product
            DetailHtml = "Product no longer present (previous score $(Format-Score $previous.productScores[$product]))"
        })
    } elseif ([math]::Abs($current.productScores[$product] - $previous.productScores[$product]) -ge $ScoreChangeThreshold) {
        $driftItems.Add([PSCustomObject]@{
            Category   = "Products"
            Item       = ConvertTo-HtmlSafe $product
            DetailHtml = Format-ScoreDelta -OldValue $previous.productScores[$product] -NewValue $current.productScores[$product]
        })
    }
}

#3) control level: new/removed controls and score changes above the threshold
$allControlNames = @($previous.controls.Keys) + @($current.controls.Keys) | Sort-Object -Unique
foreach ($controlName in $allControlNames) {
    $oldControl = $previous.controls[$controlName]
    $newControl = $current.controls[$controlName]

    if ($newControl -and -not $oldControl) {
        $driftItems.Add([PSCustomObject]@{
            Category   = "New controls"
            Item       = "$(ConvertTo-HtmlSafe $newControl.title) <span style=`"color:#605e5c;`">($(ConvertTo-HtmlSafe $newControl.product))</span>"
            DetailHtml = "New recommendation, current score $(Format-Score $newControl.currentScore)"
        })
        continue
    }
    if ($oldControl -and -not $newControl) {
        $driftItems.Add([PSCustomObject]@{
            Category   = "Removed controls"
            Item       = "$(ConvertTo-HtmlSafe $oldControl.title) <span style=`"color:#605e5c;`">($(ConvertTo-HtmlSafe $oldControl.product))</span>"
            DetailHtml = "Recommendation no longer present (previous score $(Format-Score $oldControl.currentScore))"
        })
        continue
    }

    if ([math]::Abs($newControl.currentScore - $oldControl.currentScore) -ge $ScoreChangeThreshold) {
        $driftItems.Add([PSCustomObject]@{
            Category   = "Control score changes"
            Item       = "$(ConvertTo-HtmlSafe $newControl.title) <span style=`"color:#605e5c;`">($(ConvertTo-HtmlSafe $newControl.product))</span>"
            DetailHtml = Format-ScoreDelta -OldValue $oldControl.currentScore -NewValue $newControl.currentScore
        })
    }
}

#4) exclusion/inclusion changes: control state (Ignored / ThirdParty / Reviewed / Default) only exists on the current
#profiles, so a state change is detected when its update timestamp falls after the previous snapshot was taken
$previousSnapshotTime = [datetime]$previous.snapshotDateTime
foreach ($controlProfile in $controlProfiles) {
    if (-not $controlProfile.controlStateUpdates) { continue }
    $latestStateUpdate = $controlProfile.controlStateUpdates | Sort-Object updatedDateTime -Descending | Select-Object -First 1
    if (-not $latestStateUpdate -or -not $latestStateUpdate.updatedDateTime) { continue }
    if ([datetime]$latestStateUpdate.updatedDateTime -gt $previousSnapshotTime) {
        $product = Get-ProductDisplayName -Service $controlProfile.service
        $driftItems.Add([PSCustomObject]@{
            Category   = "Exclusion / inclusion changes"
            Item       = "$(ConvertTo-HtmlSafe $controlProfile.title) <span style=`"color:#605e5c;`">($(ConvertTo-HtmlSafe $product))</span>"
            DetailHtml = "Marked as <b>$(ConvertTo-HtmlSafe $latestStateUpdate.state)</b> by $(ConvertTo-HtmlSafe $latestStateUpdate.updatedBy) on $(([datetime]$latestStateUpdate.updatedDateTime).ToString('yyyy-MM-dd HH:mm')) UTC"
        })
    }
}

if ($driftItems.Count -eq 0) {
    Write-Output "No drift detected between $($previous.snapshotDateTime) and $($current.snapshotDateTime). No email sent."
    return
}

Write-Output "Detected $($driftItems.Count) drift item(s), composing email..."

# --- Compose the HTML drift report ---
$portalUrl = "https://security.microsoft.com/securescore"
$scorePercentage = if ($current.maxScore -gt 0) { [math]::Round(($current.currentScore / $current.maxScore) * 100, 1) } else { 0 }

$categoryOrder = @("Overall score", "Products", "New controls", "Removed controls", "Control score changes", "Exclusion / inclusion changes")
$sectionsHtml = ""
foreach ($category in $categoryOrder) {
    $items = @($driftItems | Where-Object { $_.Category -eq $category })
    if ($items.Count -eq 0) { continue }
    $rows = ""
    foreach ($item in $items) {
        $rows += "<tr><td style=`"padding:8px 12px;border-bottom:1px solid #edebe9;font-size:13px;color:#323130;`">$($item.Item)</td><td style=`"padding:8px 12px;border-bottom:1px solid #edebe9;font-size:13px;color:#323130;white-space:nowrap;`">$($item.DetailHtml)</td></tr>"
    }
    $sectionsHtml += @"
<h3 style="margin:24px 0 8px 0;font-size:15px;color:#201f1e;">$category</h3>
<table style="border-collapse:collapse;width:100%;background-color:#ffffff;border:1px solid #edebe9;border-radius:4px;">$rows</table>
"@
}

$bodyHtml = @"
<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;background-color:#f3f2f1;font-family:'Segoe UI',Arial,sans-serif;">
<div style="max-width:720px;margin:0 auto;padding:24px;">
    <div style="background-color:#0a2540;border-radius:8px 8px 0 0;padding:24px 32px;">
        <h1 style="margin:0;color:#ffffff;font-size:20px;font-weight:600;">Secure Score drift detected</h1>
        <p style="margin:8px 0 0 0;color:#a7c4e0;font-size:13px;">Tenant $tenantId &middot; comparing $(([datetime]$previous.snapshotDateTime).ToString('yyyy-MM-dd')) with $(([datetime]$current.snapshotDateTime).ToString('yyyy-MM-dd'))</p>
    </div>
    <div style="background-color:#ffffff;padding:24px 32px;border:1px solid #edebe9;border-top:none;">
        <table style="width:100%;border-collapse:collapse;">
            <tr>
                <td style="padding:0;">
                    <p style="margin:0;font-size:13px;color:#605e5c;">Current secure score</p>
                    <p style="margin:4px 0 0 0;font-size:28px;font-weight:600;color:#201f1e;">$(Format-Score $current.currentScore) <span style="font-size:15px;color:#605e5c;font-weight:400;">/ $(Format-Score $current.maxScore) ($scorePercentage%)</span></p>
                </td>
                <td style="padding:0;text-align:right;vertical-align:middle;">
                    <a href="$portalUrl" style="display:inline-block;background-color:#0078d4;color:#ffffff;text-decoration:none;font-size:14px;font-weight:600;padding:10px 20px;border-radius:4px;">Open Secure Score portal</a>
                </td>
            </tr>
        </table>
        $sectionsHtml
    </div>
    <div style="background-color:#faf9f8;border:1px solid #edebe9;border-top:none;border-radius:0 0 8px 8px;padding:16px 32px;">
        <p style="margin:0;font-size:11px;color:#a19f9d;">Generated by the Secure Score drift runbook &middot; Lieben Consultancy &middot; <a href="$portalUrl" style="color:#0078d4;">security.microsoft.com/securescore</a></p>
    </div>
</div>
</body>
</html>
"@

# --- Send the report via Graph sendMail as the configured mailbox ---
$recipients = @($MailTo -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
    @{ emailAddress = @{ address = $_ } }
})

$mailBody = @{
    message         = @{
        subject      = "Secure Score drift detected: $($driftItems.Count) change(s) on $(([datetime]$current.snapshotDateTime).ToString('yyyy-MM-dd'))"
        body         = @{
            contentType = "HTML"
            content     = $bodyHtml
        }
        toRecipients = $recipients
    }
    saveToSentItems = $false
}

Write-Output "Sending drift report to $MailTo from $MailFrom..."
Invoke-GraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($MailFrom))/sendMail" -Body $mailBody | Out-Null
Write-Output "Done. Drift report with $($driftItems.Count) change(s) sent to $MailTo"
