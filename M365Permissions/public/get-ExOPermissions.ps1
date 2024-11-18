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
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    $global:includeCurrentUser = $includeCurrentUser.IsPresent

    Write-Host "Performing ExO scan using: $($global:currentUser.userPrincipalName)"
    if($includeFolderLevelPermissions){
        Write-Host "Including folder level permissions, this can take a VERY long time to complete. Get-ExOPermissions without -includeFolderLevelPermissions" -ForegroundColor Yellow
    }
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Exchange Online" -Status "Retrieving all role assignments"
    $global:ExOPermissions = @{}
    $global:exoStatObjects = @()

    $global:statObj = [PSCustomObject]@{
        "Module version" = $global:moduleVersion
        "Category" = "ExO"
        "Subject" = "Roles"
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $global:currentUser.userPrincipalName
    }

    $assignedManagementRoles = $Null;$assignedManagementRoles = (New-ExOQuery -cmdlet "Get-ManagementRoleAssignment" -cmdParams @{GetEffectiveUsers = $True})

    Write-Progress -Id 1 -PercentComplete 5 -Activity "Scanning Exchange Online" -Status "Parsing role assignments"

    $identityCache = @{}
    $count = 0
    foreach($assignedManagementRole in $assignedManagementRoles){
        $count++
        Write-Progress -Id 2 -PercentComplete (($count/$assignedManagementRoles.Count)*100) -Activity "Scanning Roles" -Status "Examining role $($count) of $($assignedManagementRoles.Count)"
        $global:statObj."Total objects scanned"++
        try{
            $mailbox = $Null; $mailbox = $identityCache.$($assignedManagementRole.EffectiveUserName)
            if($Null -eq $mailbox){
                $mailbox = (New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{Identity = $assignedManagementRole.EffectiveUserName} -retryCount 2)
                if(!$mailbox){
                    $identityCache.$($assignedManagementRole.EffectiveUserName) = $False
                }else{
                    $identityCache.$($assignedManagementRole.EffectiveUserName) = $mailbox
                }
            }
        }catch{
            $identityCache.$($assignedManagementRole.EffectiveUserName) = $False
        }
        if($false -eq $identityCache.$($assignedManagementRole.EffectiveUserName)){
            #mailbox not found, but its a guid (instead of e.g. a group), so probably a deleted mailbox
            if([guid]::TryParse($assignedManagementRole.EffectiveUserName, $([ref][guid]::Empty))){
                $splat = @{
                    path = "/"
                    type = "AdminRole"
                    principalEntraId = "Unknown"
                    principalUpn = $assignedManagementRole.EffectiveUserName
                    principalName = "Unknown"
                    principalType = "DELETED?"               
                    role = "$($assignedManagementRole.Role)"
                    through = "$($assignedManagementRole.RoleAssignee)"
                    kind = "$($assignedManagementRole.RoleAssignmentDelegationType)"
                }
                New-ExOPermissionEntry @splat
            }
        }else{
            $splat = @{
                path = "/"
                type = "AdminRole"
                principalEntraId = $mailbox.ExternalDirectoryObjectId
                principalUpn = $mailbox.UserPrincipalName
                principalName = $mailbox.DisplayName
                principalType = $mailbox.RecipientTypeDetails                
                role = "$($assignedManagementRole.Role)"
                through = "$($assignedManagementRole.RoleAssignee)"
                kind = "$($assignedManagementRole.RoleAssignmentDelegationType)"
            }
            New-ExOPermissionEntry @splat
        }
        
    }

    Write-Progress -Id 2 -Completed -Activity "Scanning Roles"

    $global:statObj."Scan end time" = Get-Date  
    $global:exoStatObjects += $global:statObj
    
    $global:statObj = [PSCustomObject]@{
        "Module version" = $global:moduleVersion
        "Category" = "ExO"
        "Subject" = "Mailboxes"
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $global:currentUser.userPrincipalName
    }

    Write-Progress -Id 1 -PercentComplete 15 -Activity "Scanning Exchange Online" -Status "Retrieving mailboxes and other objects..."
    $recipients = (New-ExOQuery -cmdlet "Get-Recipient" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object{$_ -and !$_.Identity.StartsWith("DiscoverySearchMailbox")}

    Write-Progress -Id 1 -PercentComplete 35 -Activity "Scanning Exchange Online" -Status "Checking recipients for non default permissions..."

    $count = 0
    $ignoredFolderTypes = @("RecoverableItemsSubstrateHolds","RecoverableItemsPurges","RecoverableItemsVersions","RecoverableItemsDeletions","RecoverableItemsDiscoveryHolds","Audits","CalendarLogging","RecoverableItemsRoot","Root","SyncIssues","Conflicts","LocalFailures","ServerFailures")
    foreach($recipient in $recipients){
        $count++
        $global:statObj."Total objects scanned"++
        if(!$recipient.PrimarySmtpAddress){
            Write-Warning "skipping $($recipient.identity) as it has no primary smtp address"
            continue
        }

        Write-Progress -Id 2 -PercentComplete (($count/$recipients.Count)*100) -Activity "Scanning recipients" -Status "Examining $($recipient.displayName) ($($count) of $($recipients.Count))"
        
        #mailboxes have mailbox permissions
        if($recipient.RecipientTypeDetails -like "*Mailbox*" -and $recipient.RecipientTypeDetails -ne "GroupMailbox"){
            #get mailbox meta for SOB permissions
            $mailbox = $Null; $mailbox = New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{Identity = $recipient.Guid} -retryCount 2
            if($mailbox.GrantSendOnBehalfTo){
                foreach($sendOnBehalf in $mailbox.GrantSendOnBehalfTo){
                    $entity = $Null; $entity= @($recipients | Where-Object {$_.DisplayName -eq $sendOnBehalf})[0]
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
            $mailboxPermissions = $Null; $mailboxPermissions = (New-ExOQuery -cmdlet "Get-Mailboxpermission" -cmdParams @{Identity = $recipient.Guid}) | Where-Object {$_.User -like "*@*"}
            foreach($mailboxPermission in $mailboxPermissions){
                foreach($AccessRight in $mailboxPermission.AccessRights){
                    $entity = $Null; $entity= @($recipients | Where-Object {$_.PrimarySmtpAddress -eq $mailboxPermission.User -or $_.windowsLiveId -eq $mailboxPermission.User})[0]
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
            #retrieve individual folder permissions if -includeFolderLevelPermissions is set
            if($mailbox.UserPrincipalName -and $includeFolderLevelPermissions){
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
                            if($folderPermission.AccessRights -notcontains "None"){
                                foreach($AccessRight in $folderPermission.AccessRights){
                                    $splat = @{
                                        path = "/$($mailbox.UserPrincipalName)$($folder.FolderPath)"
                                        type = "MailboxFolder"
                                        principalUpn = $Null
                                        principalName = $folderPermission.User
                                        principalEntraId = $Null
                                        principalType = $Null
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

            }
        }
        
        #all recipients can have recipient permissions
        $recipientPermissions = (New-ExOQuery -cmdlet "Get-RecipientPermission" -cmdParams @{"ResultSize" = "Unlimited"; "Identity" = $recipient.Guid}) | Where-Object {$_.Trustee -ne "NT Authority\SELF" }
        foreach($recipientPermission in $recipientPermissions){
            $entity = $Null; $entity= $recipients | Where-Object {$_.PrimarySmtpAddress -eq $recipientPermission.Trustee}
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
    }

    Write-Progress -Id 2 -Completed -Activity "Scanning Mailboxes"

    Write-Progress -Id 1 -PercentComplete 75 -Activity "Scanning Exchange Online" -Status "Writing report..."
    $global:statObj."Scan end time" = Get-Date
    $global:exoStatObjects += $global:statObj

    Write-Host "All permissions retrieved, writing reports..."
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

    add-toReport -statistics $global:exoStatObjects -formats $outputFormat -permissions $permissionRows -category "Exo"

    Write-Progress -Id 1 -Completed -Activity "Scanning Exchange Online"
}