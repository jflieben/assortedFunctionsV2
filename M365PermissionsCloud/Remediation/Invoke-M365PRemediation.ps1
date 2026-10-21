#Requires -Version 7.0
<#
.SYNOPSIS
    Fixes the findings M365Permissions reports, as the administrator running it, after showing exactly
    what it is going to change.

.DESCRIPTION
    Run this in Azure Cloud Shell or on your own machine. The portal composes the whole command for you,
    including the findings to act on, so you should not have to type any of the parameters by hand.

    Every run is the same three steps, and the first two never change anything:

      1. check    the findings are parsed, the handlers that know how to fix them are loaded, the
                  permissions and sign in they need are checked, and anything that cannot be done is
                  reported with the reason
      2. plan     each finding is looked up live and turned into a list of concrete changes, printed
                  one per line, with the ones that cannot be undone marked
      3. apply    only after you type yes. Every change is logged as it happens, and the ones that can
                  be reversed are written to a rollback file

    Nothing here acts as an application. Every change is made with your own delegated access, so the
    audit trail in Entra, SharePoint and Azure names you rather than a service principal. That also
    means you can only change what you are already allowed to change.

    The product's own identities are never touched: a run that would remove the scanner's or the
    portal's access skips it and says so.

.PARAMETER Items
    The findings, as JSON, from the portal. Accepts raw JSON, base64 encoded JSON, or base64 encoded
    gzipped JSON, which is what the portal sends because it keeps the command short enough to paste.
    See README.md in this folder for the fields each reason needs.

.PARAMETER ItemsPath
    A file containing that same JSON. Use this instead of -Items for batches too large to pass on a
    command line.

.PARAMETER WhatIf
    Stop after the plan. Nothing is changed, and the plan is still written to the log.

.PARAMETER Approve
    Skip the typed confirmation. For scripted use only: the plan is still printed and logged in full,
    but nobody is asked. Leave it off if a person is running this.

.PARAMETER MaxItems
    Refuse a run with more findings than this. Defaults to 50, which is also the ceiling. Lower it for a
    cautious run; to do more than 50, use -ItemsPath.

.PARAMETER LinkExpiryDays
    How far out to put an expiry date when fixing a sharing link that has none. Defaults to 30.

.PARAMETER ProtectedAppIds
    Application ids that must never be changed, on top of the ones detected automatically.

.PARAMETER Rollback
    A rollback file from an earlier run. Replays the inverse of everything in it, with the same plan and
    approval steps.

.PARAMETER DeviceCode
    Sign in with a device code instead of borrowing an existing session. Never used unless asked for,
    because conditional access blocks the flow in many tenants. Worth passing in two cases: the machine
    has no Azure session and no browser, or you want the gentler sharing changes, which need Graph
    scopes an existing session does not carry (see the sign in section of README.md).

.PARAMETER LocalSource
    Load the engine and handlers from a folder instead of from the internet. For development.

.EXAMPLE
    & ([scriptblock]::Create((irm https://m365permissions.com/Remediation/Invoke-M365PRemediation.ps1))) -Items '<base64 from the portal>'

.EXAMPLE
    & ([scriptblock]::Create((irm https://m365permissions.com/Remediation/Invoke-M365PRemediation.ps1))) -ItemsPath ./findings.json -WhatIf

.NOTES
    Author: Jos Lieben
    Docs:   https://m365permissions.com/docs/remediation
#>
[CmdletBinding()]
Param(
    [String]$Items,
    [String]$ItemsPath,
    [Switch]$WhatIf,
    [Switch]$Approve,
    [Int]$MaxItems = 50,
    [Int]$LinkExpiryDays = 30,
    [String[]]$ProtectedAppIds = @(),
    [String]$Rollback,
    [Switch]$DeviceCode,
    [String]$TenantId,
    [String]$LogFolder,
    [String]$BaseUri = "https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/Remediation",
    [String]$LocalSource
)

$ErrorActionPreference = "Stop"

#One cap for the whole run, not per reason: what it protects is the administrator's ability to read the
#plan before approving it, and that does not care which reasons are in the batch. Compressed, fifty
#findings is about a thousand characters, so the command line is not what binds. Larger batches go
#through -ItemsPath, where nobody has to read a pasted command.
$script:M365PHardMaxItems = 50

function Get-M365PSourceText {
    <#
        .SYNOPSIS
        The text of one engine or handler file, from disk when developing and over https otherwise.

        .DESCRIPTION
        Returns the text rather than loading it, because the caller has to dot source it at script
        scope: a dot source inside a function would leave every function it defines inside that
        function. Downloading and dot sourcing is what makes this a single command to run, with nothing
        to install, and lets handlers be added without changing what the portal tells people to paste.
    #>
    Param([Parameter(Mandatory = $true)][String]$RelativePath)

    if ($LocalSource) {
        $path = Join-Path -Path $LocalSource -ChildPath $RelativePath
        if (!(Test-Path -Path $path)) { Throw "No $RelativePath in $LocalSource" }
        return (Get-Content -Path $path -Raw)
    }

    $uri = "$($BaseUri.TrimEnd('/'))/$RelativePath"
    try {
        return (Invoke-RestMethod -Uri $uri -ErrorAction Stop)
    }catch {
        Throw "Could not download $uri : $($_.Exception.Message)"
    }
}

function ConvertFrom-M365PItemPayload {
    <#
        .SYNOPSIS
        The findings, whichever of the three shapes they arrived in.

        .DESCRIPTION
        Raw JSON is what a person would hand write. Base64 is what survives a shell without quoting
        trouble. Gzipped base64 is what the portal sends, because findings repeat long urls and compress
        to roughly a fifth, which is the difference between a command that pastes and one that does not.
    #>
    Param([Parameter(Mandatory = $true)][String]$Payload)

    $text = $Payload.Trim()
    if ($text.StartsWith("[") -or $text.StartsWith("{")) { return ($text | ConvertFrom-Json) }

    $bytes = $Null
    try { $bytes = [Convert]::FromBase64String($text) } catch { Throw "The findings are neither JSON nor base64" }

    #1f 8b is the gzip header, which is how the compressed form is recognised without a flag for it
    if ($bytes.Length -gt 2 -and $bytes[0] -eq 0x1f -and $bytes[1] -eq 0x8b) {
        $input = [System.IO.MemoryStream]::new($bytes)
        $gzip = [System.IO.Compression.GZipStream]::new($input, [System.IO.Compression.CompressionMode]::Decompress)
        $reader = [System.IO.StreamReader]::new($gzip)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose(); $gzip.Dispose(); $input.Dispose() }
    }else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    return ($text | ConvertFrom-Json)
}

function Normalize-M365PItem {
    <#
        .SYNOPSIS
        One finding, with the short field names the portal sends expanded to the long ones handlers read.

        .DESCRIPTION
        The portal sends short keys to keep the command short. Both spellings are accepted so a hand
        written file stays readable.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Raw)

    $map = @{
        i  = "id";            id                = "id"
        r  = "reason";        reason            = "reason"
        c  = "category";      category          = "category"
        p  = "targetPath";    targetPath        = "targetPath"
        tt = "targetType";    targetType        = "targetType"
        ti = "targetId";      targetId          = "targetId"
        pi = "principalId";   principalId       = "principalId"
        pn = "principalName"; principalName     = "principalName"
        pu = "principalUpn";  principalUpn      = "principalUpn"
        ps = "principalSysId"; principalSysId   = "principalSysId"
        pt = "principalType"; principalType     = "principalType"
        ro = "role";          role              = "role"
        th = "through";       through           = "through"
        cd = "createdDateTime"; createdDateTime = "createdDateTime"
        sd = "startDateTime"; startDateTime     = "startDateTime"
        ed = "endDateTime";   endDateTime       = "endDateTime"
    }

    $item = [Ordered]@{}
    foreach ($property in $Raw.PSObject.Properties) {
        $name = if ($map.ContainsKey($property.Name)) { $map[$property.Name] } else { $property.Name }
        $item[$name] = $property.Value
    }
    return [PSCustomObject]$item
}

# ------------------------------------------------------------------------------------------------
# 1. Load
# ------------------------------------------------------------------------------------------------

#dot sourced here rather than inside the helper, so everything it defines lands in this script's scope
. ([ScriptBlock]::Create((Get-M365PSourceText -RelativePath "remediation-lib.ps1")))

$runLogFolder = Start-M365PRemediationLog -LogFolder $LogFolder
$script:M365PTenantId = $TenantId

Write-M365PLine ""
Write-M365PLine "M365Permissions remediation" -Colour White
Write-M365PDetail "Logging to $runLogFolder"

Write-M365PStep "Loading what this version knows how to fix"
foreach ($handlerFile in @("Sharing.ps1", "OrphanedPermission.ps1", "AppRoles.ps1", "OnedriveNonOwner.ps1")) {
    . ([ScriptBlock]::Create((Get-M365PSourceText -RelativePath "handlers/$handlerFile")))
}
$handlers = Get-M365PHandlers
Write-M365PDetail "$($handlers.Count) reasons: $((@($handlers.Reason) | Sort-Object) -join ", ")"

# ------------------------------------------------------------------------------------------------
# 2. Input
# ------------------------------------------------------------------------------------------------

if ($Rollback) {
    Write-M365PStep "Rollback"
    if (!(Test-Path -Path $Rollback)) { Write-M365PBad "No rollback file at $Rollback"; return }
    $entries = @(Get-Content -Path $Rollback -Raw | ConvertFrom-Json)
    Write-M365PDetail "$($entries.Count) change(s) to put back"

    $actions = foreach ($entry in $entries) {
        New-M365PAction -Item ([PSCustomObject]@{ id = $Null; reason = "Rollback"; targetPath = $entry.undo.uri }) `
            -Summary $entry.summary -Target "$($entry.undo.uri)" `
            -State @{ Undo = $entry.undo } `
            -Apply {
            Param($action, $context)
            $undo = $action.State.Undo
            switch ($undo.type) {
                "patchPermission" { $Null = Invoke-M365PCall -Uri $undo.uri -Method "PATCH" -Body $undo.body }
                "postJson" { $Null = Invoke-M365PCall -Uri $undo.uri -Method "POST" -Body $undo.body }
                "sharePointPost" { $Null = Invoke-M365PCall -Audience $undo.audience -Uri $undo.uri -Method "POST" }
                "sharePointMerge" {
                    $Null = Invoke-M365PCall -Audience $undo.audience -Uri $undo.uri -Method "MERGE" `
                        -ContentType $undo.contentType -ExtraHeaders @{ "IF-MATCH" = "*" } -Body $undo.body
                }
                default { Throw "This version does not know how to undo a '$($undo.type)' change" }
            }
        }
    }

    $actions = @($actions)
    if ($actions.Count -eq 0) { Write-M365PWarn "Nothing reversible in that file"; return }
    if (Show-M365PPlan -Actions $actions -Approve:$Approve -PlanOnly:$WhatIf) {
        $Null = Invoke-M365PActions -Actions $actions -Context ([PSCustomObject]@{ LinkExpiryDays = $LinkExpiryDays })
    }
    return
}

if (!$Items -and !$ItemsPath) {
    Write-M365PBad "Nothing to do: pass -Items (what the portal gives you) or -ItemsPath."
    return
}

$payload = if ($ItemsPath) {
    if (!(Test-Path -Path $ItemsPath)) { Write-M365PBad "No file at $ItemsPath"; return }
    Get-Content -Path $ItemsPath -Raw
}else { $Items }

$rawFindings = @(ConvertFrom-M365PItemPayload -Payload $payload)
#not $items: that is the same variable as the [String]$Items parameter, so an array assigned to it comes
#back out as one string
$findings = @($rawFindings | ForEach-Object { Normalize-M365PItem -Raw $_ })

Write-M365PStep "Checking the findings"
Write-M365PDetail "$($findings.Count) finding(s) handed over"

if ($MaxItems -gt $script:M365PHardMaxItems) {
    Write-M365PWarn "-MaxItems $MaxItems is above the ceiling of $($script:M365PHardMaxItems), using $($script:M365PHardMaxItems)"
    $MaxItems = $script:M365PHardMaxItems
}
if ($findings.Count -gt $MaxItems) {
    Write-M365PBad "$($findings.Count) findings is more than the $MaxItems this run allows. Ask the portal for smaller batches, or put them in a file and use -ItemsPath."
    return
}

#Group by reason first, so a contract problem or an over-large batch of one risky reason is reported
#before anything is looked up, and the administrator is not waiting on reads that will be discarded.
$usable = [System.Collections.Generic.List[Object]]::new()
foreach ($group in ($findings | Group-Object reason)) {
    $handler = Get-M365PHandler -Reason $group.Name
    if (!$handler) {
        Write-M365PWarn "$($group.Count)x $($group.Name): this version cannot fix that reason, skipping"
        foreach ($item in $group.Group) { Add-M365PSkip -Item $item -Why "No handler for this reason in this version" }
        continue
    }
    foreach ($item in $group.Group) {
        if ($item.category -and @($handler.Categories) -notcontains "$($item.category)") {
            Add-M365PSkip -Item $item -Why "$($group.Name) can be fixed in $((@($handler.Categories)) -join ', '), but this one is in $($item.category)"
            continue
        }
        $missing = @($handler.RequiredFields | Where-Object { !"$($item.$_)" })
        if ($missing.Count -gt 0) {
            Add-M365PSkip -Item $item -Why "Missing field(s) $($missing -join ', '), which this reason cannot be fixed without"
            continue
        }
        $usable.Add($item)
    }
}

if ($usable.Count -eq 0) {
    Write-M365PWarn "Nothing left to do after checking the findings."
    $Null = Show-M365PPlan -Actions @() -PlanOnly
    return
}

# ------------------------------------------------------------------------------------------------
# 3. Sign in and permissions
# ------------------------------------------------------------------------------------------------

Write-M365PStep "Checking your sign in and permissions"

$neededScopes = @($usable | ForEach-Object { (Get-M365PHandler -Reason $_.reason).RequiredScopes } | Where-Object { $_ } | Select-Object -Unique)
$graphToken = Get-M365PToken -Audience "graph" -Scopes $neededScopes -DeviceCode:$DeviceCode
$claims = Get-M365PTokenClaims -Token $graphToken
if (!$script:M365PTenantId -and $claims.tid) { $script:M365PTenantId = $claims.tid }
Write-M365PDetail "Signed in as $($claims.upn ?? $claims.preferred_username ?? $claims.unique_name) in tenant $($claims.tid)"

$missingScopes = Test-M365PTokenScopes -Token $graphToken -Required $neededScopes
if ($missingScopes.Count -gt 0) {
    Write-M365PWarn "Your token does not carry: $($missingScopes -join ", ")"
    if ($DeviceCode) {
        Write-M365PBad "Sign in again with an account that can consent to those, or fix the findings by hand."
        return
    }
    Write-M365PDetail "Signing in again with a device code, which can ask for exactly those permissions."
    $script:M365PTokens.Remove("graph")
    $graphToken = Get-M365PToken -Audience "graph" -Scopes $neededScopes -DeviceCode
    $missingScopes = Test-M365PTokenScopes -Token $graphToken -Required $neededScopes
    if ($missingScopes.Count -gt 0) {
        Write-M365PBad "Still missing: $($missingScopes -join ", "). Nothing was changed."
        return
    }
}
Write-M365PGood "Permissions look sufficient for the findings handed over"

$protected = Initialize-M365PProtection -ProtectedAppIds $ProtectedAppIds
Write-M365PDetail "$($protected.Count) identity(ies) marked as the product's own and excluded"

#Which route the sharing handlers take. Borrowed sessions cannot change sharing through Graph, so the
#default is SharePoint's own API, which the same session can reach. Said out loud here because it
#changes what the plan will offer: adjusting a link, or removing it.
$useGraphSharing = Test-M365PHasGraphSharing
if ($useGraphSharing) {
    Write-M365PGood "Your token can change sharing through Graph, so links can be expired or downgraded instead of removed"
}else {
    Write-M365PDetail "Sharing will be changed through SharePoint's own API, which removes a link rather than adjusting it"
    Write-M365PDetail "For the gentler version, sign in with -DeviceCode or an account whose token carries Sites.ReadWrite.All"
}

# ------------------------------------------------------------------------------------------------
# 4. Plan
# ------------------------------------------------------------------------------------------------

Write-M365PStep "Working out what needs to change"

$context = [PSCustomObject]@{
    LinkExpiryDays  = $LinkExpiryDays
    TenantId        = $script:M365PTenantId
    UseGraphSharing = $useGraphSharing
}

$actions = [System.Collections.Generic.List[Object]]::new()
$index = 0
foreach ($item in $usable) {
    $index++
    Write-M365PDetail "$index/$($usable.Count) $($item.reason) on $($item.targetPath)"
    $handler = Get-M365PHandler -Reason $item.reason
    try {
        foreach ($action in @(& $handler.Plan $item $context)) {
            if ($action) { $actions.Add($action) }
        }
    }catch {
        Add-M365PSkip -Item $item -Why "Could not work out what to change: $($_.Exception.Message)"
    }
}

if ($actions.Count -eq 0) {
    Write-M365PLine ""
    Write-M365PWarn "No changes to make. Everything handed over was either already fixed or needs doing by hand."
    $Null = Show-M365PPlan -Actions @() -PlanOnly
    return
}

# ------------------------------------------------------------------------------------------------
# 5. Approve and apply
# ------------------------------------------------------------------------------------------------

if (Show-M365PPlan -Actions $actions.ToArray() -Approve:$Approve -PlanOnly:$WhatIf) {
    $result = Invoke-M365PActions -Actions $actions.ToArray() -Context $context
    Write-M365PLine ""
    Write-M365PDetail "Re-scan the affected targets in the portal to clear the findings, or wait for the next scan."
    if ($result.Applied -gt 0) {
        Write-M365PDetail "To put this back: -Rollback $($script:M365PRollbackFile)"
    }
}
