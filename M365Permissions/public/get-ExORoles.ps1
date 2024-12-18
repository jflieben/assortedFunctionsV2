Function get-ExORoles{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -includeFolderLevelPermissions: if set, folder level permissions for each mailbox will be retrieved. This can be (very) slow
    #>        
    Param(
        [Switch]$expandGroups
    )

    Write-Host "Starting Exo role scan..."
    
    Write-Progress -Id 2 -PercentComplete 0 -Activity "Scanning Exchange Roles" -Status "Retrieving all role assignments"
    $global:ExOPermissions = @{}
    New-StatisticsObject -category "ExoRoles" -subject "AdminRoles"

    $assignedManagementRoles = $Null;$assignedManagementRoles = (New-ExOQuery -cmdlet "Get-ManagementRoleAssignment" -cmdParams @{GetEffectiveUsers = $True})

    Write-Progress -Id 2 -PercentComplete 5 -Activity "Scanning Exchange Roles" -Status "Parsing role assignments"

    $identityCache = @{}
    $count = 0
    foreach($assignedManagementRole in $assignedManagementRoles){
        $count++
        Write-Progress -Id 3 -PercentComplete (($count/$assignedManagementRoles.Count)*100) -Activity "Scanning Roles" -Status "Examining role $($count) of $($assignedManagementRoles.Count)"
        Update-StatisticsObject -category "ExoRoles" -subject "AdminRoles"
        try{
            $mailbox = $Null; $mailbox = $identityCache.$($assignedManagementRole.EffectiveUserName)
            if($Null -eq $mailbox){
                $mailbox = (New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{Identity = $assignedManagementRole.EffectiveUserName} -retryCount 1)[0]
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

    Write-Progress -Id 3 -Completed -Activity "Scanning Roles"

    Stop-StatisticsObject -category "ExoRoles" -subject "AdminRoles"

    Write-Progress -Id 2 -PercentComplete 75 -Activity "Scanning Exchange Roles" -Status "Writing report..."

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

    Add-ToReportQueue -permissions $permissionRows -category "ExoRoles" -statistics @($global:unifiedStatistics."ExoRoles"."AdminRoles") 
    Remove-Variable -Name permissionRows -Force -Confirm:$False
    Reset-ReportQueue
    Write-Progress -Id 2 -Completed -Activity "Scanning Exchange Roles"
}