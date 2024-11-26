Function get-AllExOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -includeFolderLevelPermissions: if set, folder level permissions for each mailbox will be retrieved. This can be (very) slow
        -outputFormat: 
            XLSX
            CSV
            Default (output to Out-GridView)
            Any combination of above is possible
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
    #>        
    Param(
        [Switch]$expandGroups,
        [Switch]$includeCurrentUser,
        [Switch]$includeFolderLevelPermissions,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    $global:octo.includeCurrentUser = $includeCurrentUser.IsPresent

    $activity = "Scanning Exchange Online"

    if($includeFolderLevelPermissions){
        Write-Host "Including folder level permissions, this will lengthen the scan duration significantly" -ForegroundColor Yellow
    }

    Write-Progress -Id 1 -PercentComplete 1 -Activity $activity -Status "Scanning roles..."
    get-ExORoles -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent
    Write-Progress -Id 1 -PercentComplete 1 -Activity $activity -Status "Retrieving all recipients..."
    $global:octo.recipients = (New-ExOQuery -cmdlet "Get-Recipient" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object{$_ -and !$_.Identity.StartsWith("DiscoverySearchMailbox")}
    foreach($recipient in $global:octo.recipients){
        New-ScanJob -Title $activity -Target $recipient.displayName -FunctionToRun "get-ExOPermissions" -FunctionArguments @{
            "recipientIdentity" = $recipient.Identity
            "outputFormat" = $outputFormat
            "expandGroups" = $expandGroups.IsPresent
            "includeFolderLevelPermissions" = $includeFolderLevelPermissions.IsPresent
        }
    }
    Start-ScanJobs -Title $activity
    Write-Progress -Id 1 -Completed -Activity $activity
}