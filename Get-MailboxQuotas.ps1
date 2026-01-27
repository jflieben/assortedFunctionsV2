<#
.SYNOPSIS
    Scans all mailboxes and email a report of mailboxes close to or over their storage quota.
    Author: Jos Lieben

.DESCRIPTION
    Uses Managed Identity (Connect-MgGraph -Identity).
    Outputs an HTML table and emails it to the specified address.

.REQUIREMENTS (Managed Identity Graph APP permissions)
    - Exchange Online View-Only Organization Management role
    - Exchange.ManageAsApp
    - Mail.Send (or at the EXO level)
    - Graph module installed in your automation account
    - ExchangeOnlineManagement module installed in your automation account

.PARAMETER emailAddress
    Recipient (and sending mailbox) for the report.

.PARAMETER ThresholdPercent
    Percentage usage at/above which a mailbox is reported (default 85).
#>
param(
    [string]$emailAddress = "you@yourdomain.com",
    [int]$ThresholdPercent = 90
)

if($ThresholdPercent -lt 1 -or $ThresholdPercent -gt 100){
    throw "ThresholdPercent must be between 1 and 100."
}

Write-Output "Connecting to Exchange Online using Managed Identity..."

Connect-ExchangeOnline -ManagedIdentity -Organization "$($emailAddress.Split("@"[1]))"
$mailboxes = Get-EXOMailbox -ResultSize Unlimited -Properties ProhibitSendQuota

$allMailboxes = $mailboxes | ForEach-Object -Parallel {
    $mbx = $_
    $stats = Get-ExoMailboxStatistics -Identity $mbx.Guid.Guid -Properties TotalItemSize -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        DisplayName       = $mbx.DisplayName
        MailboxGuid       = $mbx.Guid.Guid
        TotalItemSize     = $stats.TotalItemSize
        ProhibitSendQuota = $mbx.ProhibitSendQuota
    }
} -ThrottleLimit 10

Write-Output "Connected to Exchange Online and got $($allMailboxes.count) Mailboxes. Now connecting to Microsoft Graph..."

Write-Output "Connecting to Microsoft Graph..."
Connect-MgGraph -Identity -NoWelcome

$report = @()

Write-Output "Enumerating mailboxes and evaluating Mailbox quota (threshold: $ThresholdPercent%)..."
foreach($mailbox in $allMailboxes) {
    
    # Parse Quota to rounded MB (handle both object and string representation)
    $quota = 0
    if ($null -ne $mailbox.ProhibitSendQuota.Value) {
        $quota = [math]::Round($mailbox.ProhibitSendQuota.Value.ToBytes() / 1MB)
    } elseif ($mailbox.ProhibitSendQuota -match "\(([\d,]+)\s*bytes\)") {
        $quota = [math]::Round(([int64]($matches[1] -replace ",","")) / 1MB)
    }

    # Parse Used to rounded MB
    $used = 0
    if ($null -ne $mailbox.TotalItemSize.Value) {
        $used = [math]::Round($mailbox.TotalItemSize.Value.ToBytes() / 1MB)
    } elseif ($mailbox.TotalItemSize -match "\(([\d,]+)\s*bytes\)") {
        $used = [math]::Round(([int64]($matches[1] -replace ",","")) / 1MB)
    }

    # Safety for unlimited or parse failure to avoid division by zero
    if ($quota -eq 0) { $quota = [int]::MaxValue }

    Write-Output "Mailbox: $($mailbox.DisplayName) - Storage Used (MB): $($used) - Storage Quota (MB): $($quota)"
    $percent = [math]::Round(($used / $quota) * 100,2)
    $alert = $false
    if($percent -ge $ThresholdPercent){
        $alert = $true
    }
    if($alert){
        $report += [pscustomobject]@{
            'Display Name' = $mailbox.DisplayName
            'Percent Used' = $percent
            'Used (GB)' = [math]::Round($used / 1024,2)
            'Quota (GB)' = [math]::Round($quota / 1024,2)
        }
    }
}

Write-Output "Finished scanning. Matches: $($report.Count)"

if($report.Count -eq 0){
    Write-Output "No mailboxes near or over quota. Exiting."
    exit 0
}

$style = @"
<style>
body { font-family: Calibri, Arial, sans-serif; }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid #ddd; padding: 6px 8px; font-size: 13px; }
th { background:#f2f2f2; text-align:left; }
tr:nth-child(even){ background:#fafafa; }
</style>
"@

$html = $report |
    Sort-Object 'Percent Used' -Descending |
    ConvertTo-Html -Head $style -Title "Mailboxes Quota Alert" -PreContent "<h2>Mailboxes Near / Over Quota</h2><p>Threshold: $ThresholdPercent%. Generated: $(Get-Date -Format u)</p>" |
    Out-String

Write-Output "Sending email with $($report.Count) rows..."
$emailParams = @{
    UserId        = $emailAddress
    BodyParameter = @{
        message = @{
            subject      = "Mailboxes Quota Alert ($($report.Count) mailboxes)"
            body         = @{
                contentType = "HTML"
                content     = $html
            }
            toRecipients = @(
                @{ emailAddress = @{ address = $emailAddress } }
            )
        }
        saveToSentItems = "true"
    }
}

try{
    Send-MgUserMail @emailParams
    Write-Output "Email sent successfully."
}catch{
    Write-Output "Failed to send email: $_"
    exit 1
}