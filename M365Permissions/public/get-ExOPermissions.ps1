Function get-ExOPermissions{
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
        [parameter(Mandatory=$true)][String]$recipientIdentity,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    $global:includeCurrentUser = $includeCurrentUser.IsPresent

    $global:ExOPermissions = @{}

    if(!$global:recipients){
        Write-Progress -Id 2 -PercentComplete 1 -Activity "Scanning Recipient" -Status "Retrieving recipients for cache..."
        $global:recipients = (New-ExOQuery -cmdlet "Get-Recipient" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object{$_ -and !$_.Identity.StartsWith("DiscoverySearchMailbox")}
    }

    $recipient = $global:recipients | Where-Object {$_.Identity -eq $recipientIdentity}

    $global:statObj = [PSCustomObject]@{
        "Module version" = $global:moduleVersion
        "Category" = "ExoRecipients"
        "Subject" = $recipient.displayName
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $global:currentUser.userPrincipalName
    }

    $ignoredFolderTypes = @("RecoverableItemsSubstrateHolds","RecoverableItemsPurges","RecoverableItemsVersions","RecoverableItemsDeletions","RecoverableItemsDiscoveryHolds","Audits","CalendarLogging","RecoverableItemsRoot","SyncIssues","Conflicts","LocalFailures","ServerFailures")
    $global:statObj."Total objects scanned"++
    if(!$recipient.PrimarySmtpAddress){
        Write-Warning "skipping $($recipient.identity) as it has no primary smtp address"
        return $Null
    }
    
    #mailboxes have mailbox permissions
    if($recipient.RecipientTypeDetails -like "*Mailbox*" -and $recipient.RecipientTypeDetails -ne "GroupMailbox"){
        Write-Progress -Id 2 -PercentComplete 5 -Activity "Scanning $($recipient.Identity)" -Status "Checking recipient for SendOnBehalf permissions..."
        #get mailbox meta for SOB permissions
        $mailbox = $Null; $mailbox = New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{Identity = $recipient.Guid} -retryCount 2
        if($mailbox.GrantSendOnBehalfTo){
            foreach($sendOnBehalf in $mailbox.GrantSendOnBehalfTo){
                $entity = $Null; $entity= @($global:recipients | Where-Object {$_.DisplayName -eq $sendOnBehalf})[0]
                $splat = @{
                    path = "/$($recipient.PrimarySmtpAddress)"
                    type = $recipient.RecipientTypeDetails
                    principalUpn = if($entity.PrimarySmtpAddress){$entity.PrimarySmtpAddress}else{$entity.windowsLiveId}
                    principalName = $sendOnBehalf
                    principalEntraId = $entity.ExternalDirectoryObjectId
                    principalType = $entity.RecipientTypeDetails
                    role = "SendOnBehalf"
                    through = "Direct"
                    kind = "Allow"
                }
                New-ExOPermissionEntry @splat
            }
        }           
        
        if($mailbox){
            Write-Progress -Id 2 -PercentComplete 15 -Activity "Scanning $($recipient.Identity)" -Status "Checking recipient for Mailbox permissions..."
            $mailboxPermissions = $Null; $mailboxPermissions = (New-ExOQuery -cmdlet "Get-Mailboxpermission" -cmdParams @{Identity = $mailbox.Guid}) | Where-Object {$_.User -like "*@*"}
            foreach($mailboxPermission in $mailboxPermissions){
                foreach($AccessRight in $mailboxPermission.AccessRights){
                    $entity = $Null; $entity= @($global:recipients | Where-Object {$_.PrimarySmtpAddress -eq $mailboxPermission.User -or $_.windowsLiveId -eq $mailboxPermission.User})[0]
                    $splat = @{
                        path = "/$($recipient.PrimarySmtpAddress)"
                        type = $recipient.RecipientTypeDetails
                        principalUpn = if($entity.PrimarySmtpAddress){$entity.PrimarySmtpAddress}else{$entity.windowsLiveId}
                        principalName = $entity.Identity
                        principalEntraId = $entity.ExternalDirectoryObjectId
                        principalType = $entity.RecipientTypeDetails
                        role = $AccessRight
                        through = $(if($mailboxPermission.IsInherited){ "Inherited" }else{ "Direct" })
                        kind = $(if($mailboxPermission.Deny -eq "False"){ "Allow" }else{ "Deny" })
                    }
                    New-ExOPermissionEntry @splat
                }
            }
        }
        
        #retrieve individual folder permissions if -includeFolderLevelPermissions is set
        if($mailbox.UserPrincipalName -and $includeFolderLevelPermissions){
            Write-Progress -Id 2 -PercentComplete 25 -Activity "Scanning $($recipient.Identity)" -Status "Checking recipient for folder permissions..."

            Write-Progress -Id 3 -PercentComplete 1 -Activity "Scanning folders" -Status "Retrieving folder list for $($mailbox.UserPrincipalName)"
            try{
                $folders = $Null; $folders = New-ExOQuery -cmdlet "Get-MailboxFolderStatistics" -cmdParams @{"ResultSize"="unlimited";"Identity"= $mailbox.UserPrincipalName}
            }catch{
                Write-Warning "Failed to retrieve folder list for $($mailbox.UserPrincipalName)"
            }      

            $folderCounter = 0
            foreach($folder in $folders){
                $global:statObj."Total objects scanned"++
                $folderCounter++
                Write-Progress -Id 3 -PercentComplete (($folderCounter/$folders.Count)*100) -Activity "Scanning folders" -Status "Examining $($folder.Name) ($($folderCounter) of $($folders.Count))"
                if($ignoredFolderTypes -contains $folder.FolderType -or $folder.Name -in @("SearchDiscoveryHoldsFolder")){
                    Write-Verbose "Ignoring folder $($folder.Name) as it is in the ignored list"
                    continue
                }
                try{
                    $folderPermissions = $Null; $folderPermissions = New-ExoQuery -cmdlet "Get-MailboxFolderPermission" -cmdParams @{Identity = "$($mailbox.UserPrincipalName):$($folder.FolderId)"}
                    foreach($folderPermission in $folderPermissions){
                        $entity = $Null; $entity= @($global:recipients | Where-Object {$_.Identity -eq $folderPermission.User})[0]
                        if(!$entity){
                            $entity = $Null; $entity= @($global:recipients | Where-Object {$_.DisplayName -eq $folderPermission.User})[0] 
                        }
                        if($entity -and $entity.Identity -eq $recipient.Identity){
                            Write-Verbose "Skipping permission $($folderPermission.AccessRights) scoped at $($mailbox.UserPrincipalName)$($folder.FolderPath) for $($recipient.Identity) as it is the owner"
                            continue
                        }
                        #handle external permissions for e.g. calendars
                        if($folderPermission.User.StartsWith("ExchangePublishedUser")){
                            $entity = [PSCustomObject]@{
                                PrimarySmtpAddress = $folderPermission.User.Replace("ExchangePublishedUser.","")
                                ExternalDirectoryObjectId = "N/A"
                                RecipientTypeDetails = "ExternalUser"
                            }
                        }
                        if($folderPermission.AccessRights -notcontains "None"){
                            foreach($AccessRight in $folderPermission.AccessRights){
                                $splat = @{
                                    path = "/$($mailbox.UserPrincipalName)$($folder.FolderPath)"
                                    type = "MailboxFolder"
                                    principalUpn = if($entity.PrimarySmtpAddress){$entity.PrimarySmtpAddress}else{$entity.windowsLiveId}
                                    principalName = $folderPermission.User
                                    principalEntraId = $entity.ExternalDirectoryObjectId
                                    principalType = $entity.RecipientTypeDetails
                                    role = $AccessRight
                                    through = "Direct"
                                    kind = "Allow"
                                }
                                New-ExOPermissionEntry @splat
                            }
                        }
                    }
                }catch{
                    Write-Warning "Failed to retrieve folder permissions for $($mailbox.UserPrincipalName)$($folder.FolderPath)"
                }
            }
            Write-Progress -Id 3 -Completed -Activity "Scanning folders"
        }
    }
    
    #all recipients can have recipient permissions
    Write-Progress -Id 2 -PercentComplete 85 -Activity "Scanning $($recipient.Identity)" -Status "Checking recipient for SendAs permissions..."

    $recipientPermissions = (New-ExOQuery -cmdlet "Get-RecipientPermission" -cmdParams @{"ResultSize" = "Unlimited"; "Identity" = $recipient.Guid}) | Where-Object {$_.Trustee -ne "NT Authority\SELF" }
    foreach($recipientPermission in $recipientPermissions){
        $entity = $Null; $entity= $global:recipients | Where-Object {$_.PrimarySmtpAddress -eq $recipientPermission.Trustee}
        foreach($AccessRight in $recipientPermission.AccessRights){
            $splat = @{
                path = "/$($recipient.PrimarySmtpAddress)"
                type = $recipient.RecipientTypeDetails
                principalUpn = $recipientPermission.Trustee
                principalName = $entity.displayName
                principalEntraId = $entity.ExternalDirectoryObjectId
                principalType = $entity.RecipientTypeDetails
                role = $AccessRight
                through = $(if($recipientPermission.IsInherited){ "Inherited" }else{ "Direct" })
                kind = $recipientPermission.AccessControlType
            }
            New-ExOPermissionEntry @splat
        }
    }     

    Write-Progress -Id 2 -PercentComplete 95 -Activity "Scanning $($recipient.Identity)" -Status "Writing report..."
    $global:statObj."Scan end time" = Get-Date

    $permissionRows = foreach($row in $global:ExOPermissions.Keys){
        foreach($permission in $global:ExOPermissions.$row){
            [PSCustomObject]@{
                "Path" = $permission.Path
                "Type" = $permission.Type
                "PrincipalEntraId" = $permission.PrincipalEntraId
                "PrincipalUpn" = $permission.PrincipalUpn
                "PrincipalName" = $permission.PrincipalName
                "PrincipalType" = $permission.PrincipalType
                "Role" = $permission.Role
                "Through" = $permission.Through
                "Kind" = $permission.Kind
            }
        }
    }  

    add-toReport -statistics $global:statObj -formats $outputFormat -permissions $permissionRows -category "ExoRecipients"

    Write-Progress -Id 2 -Completed -Activity "Scanning $($recipient.Identity)"
}