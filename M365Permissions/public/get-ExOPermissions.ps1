Function get-ExOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -outputFormat: 
            XLSX
            CSV
            Default (output to Out-GridView)
            Any combination of above is possible
        -ignoreCurrentUser: do not add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
    #>        
    Param(
        [Switch]$expandGroups,
        [Switch]$ignoreCurrentUser,
        [parameter(Mandatory=$true)]
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat
    )

    $global:ignoreCurrentUser = $ignoreCurrentUser.IsPresent

    Write-Host "Performing ExO scan using: $($currentUser.userPrincipalName)"
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
        "Scan performed by" = $currentUser.userPrincipalName
    }

    $params = @{
        GetEffectiveUsers = $True
    }
    $assignedManagementRoles = $Null;$assignedManagementRoles = (New-ExOQuery -cmdlet "Get-ManagementRoleAssignment" -cmdParams $params)

    Write-Progress -Id 1 -PercentComplete 5 -Activity "Scanning Exchange Online" -Status "Parsing role assignments"

    $identityCache = @{}
    $count = 0
    foreach($assignedManagementRole in $assignedManagementRoles){
        $count++
        Write-Progress -Id 2 -PercentComplete ($count/$assignedManagementRoles.Count*100) -Activity "Scanning Roles" -Status "Examining role $($count) of $($assignedManagementRoles.Count)"
        $global:statObj."Total objects scanned"++
        try{
            $mailbox = $Null; $mailbox = $identityCache.$($assignedManagementRole.EffectiveUserName)
            if($Null -eq $mailbox){
                $mailbox = (New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{Identity = $assignedManagementRole.EffectiveUserName})
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
                    principalType = "DELETED OBJECT"               
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
        "Scan performed by" = $currentUser.userPrincipalName
    }

    Write-Progress -Id 1 -PercentComplete 15 -Activity "Scanning Exchange Online" -Status "Retrieving mailboxes..."
    
    $mailboxes = (New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{"ResultSize" = "Unlimited"}) | Where-Object {$_.RecipientTypeDetails -ne "DiscoveryMailbox"}
        
    Write-Progress -Id 1 -PercentComplete 35 -Activity "Scanning Exchange Online" -Status "Checking mailboxes for non default permissions..."

    $count = 0
    foreach($mailbox in $mailboxes){
        $count++
        Write-Progress -Id 2 -PercentComplete ($count/$mailboxes.Count*100) -Activity "Scanning Mailboxes" -Status "Examining mailbox $($count) of $($mailboxes.Count)"
        $global:statObj."Total objects scanned"++
        $permissions = $Null; $permissions = (New-ExOQuery -cmdlet "Get-Mailboxpermission" -cmdParams @{Identity = $mailbox.Guid}) | Where-Object {$_.User -like "*@*"}
        foreach($permission in $permissions){
            foreach($AccessRight in $permission.AccessRights){
                $splat = @{
                    path = "/$($mailbox.UserPrincipalName)"
                    type = "Mailbox"
                    principalUpn = $permission.User
                    role = $AccessRight
                    through = $(if($permission.IsInherited){ "Inherited" }else{ "Direct" })
                    kind = $(if($permission.Deny -eq "False"){ "Allow" }else{ "Deny" })
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

    if((get-location).Path){
        $basePath = Join-Path -Path (get-location).Path -ChildPath "M365Permissions.@@@"
    }else{
        $basePath = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "M365Permissions.@@@"
    }

    foreach($format in $outputFormat){
        switch($format){
            "XLSX" { 
                $targetPath = $basePath.Replace("@@@","xlsx")
                $permissionRows | Export-Excel -Path $targetPath -WorksheetName "ExOPermissions" -TableName "ExOPermissions" -TableStyle Medium10 -Append -AutoSize
                $global:exoStatObjects | Export-Excel -Path $targetPath -WorksheetName "Statistics" -TableName "Statistics" -TableStyle Medium10 -Append -AutoSize
                Write-Host "XLSX report saved to $targetPath"
            }
            "CSV" { 
                $targetPath = $basePath.Replace(".@@@","-ExO.csv")
                $permissionRows | Export-Csv -Path $targetPath -NoTypeInformation  -Append
                Write-Host "CSV report saved to $targetPath"
            }
            "Default" { $permissionRows | out-gridview }
        }
    }
    Write-Progress -Id 1 -Completed -Activity "Scanning Exchange Online"
}