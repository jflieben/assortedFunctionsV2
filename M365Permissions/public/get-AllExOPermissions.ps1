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

    $global:includeCurrentUser = $includeCurrentUser.IsPresent

    if($includeFolderLevelPermissions){
        Write-Host "Including folder level permissions, this can take several hours per 1000 users depending on mailbox use" -ForegroundColor Yellow
    }

    Write-Progress -Id 1 -PercentComplete 1 -Activity "Scanning Exchange Online" -Status "Scanning roles..."
    get-ExORoles -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent
    Write-Progress -Id 1 -PercentComplete 1 -Activity "Scanning Exchange Online" -Status "Retrieving all recipients..."
    $global:recipients = (New-ExOQuery -cmdlet "Get-Recipient" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object{$_ -and !$_.Identity.StartsWith("DiscoverySearchMailbox")}
    $count = 0
    foreach($recipient in $recipients){
        $count++
        Write-Progress -Id 1 -PercentComplete (($count/$recipients.Count)*100) -Activity "Scanning Exchange Online" -Status "Examining $($recipient.displayName) ($($count) of $($recipients.Count))"
        get-ExOPermissions -recipientIdentity $recipient.Identity -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -includeFolderLevelPermissions:$includeFolderLevelPermissions.IsPresent
    }
}