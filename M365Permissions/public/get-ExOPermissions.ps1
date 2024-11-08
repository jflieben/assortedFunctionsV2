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
        [parameter(Mandatory=$true)]
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat
    )

    if(!$global:currentUser){
        $global:currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    }
    Write-Host "Performing ExO scan using: $($currentUser.userPrincipalName)"
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Exchange Online" -Status "Retrieving all role assignments"
    $global:ExOPermissions = @{}

    $global:statObj = [PSCustomObject]@{
        "Module version" = $MyInvocation.MyCommand.Module.Version
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

    Write-Progress -Id 1 -PercentComplete 25 -Activity "Scanning Exchange Online" -Status "Parsing role assignments"

    $identityCache = @{}
    foreach($assignedManagementRole in $assignedManagementRoles){
        $global:statObj."Total objects scanned"++
        try{
            $mailbox = $Null; $mailbox = $identityCache.$($assignedManagementRole.EffectiveUserName)
            if($Null -eq $mailbox){
                $mailbox = (New-ExOQuery -cmdlet "Get-Mailbox" -cmdParams @{Identity = $assignedManagementRole.EffectiveUserName})
                if(!$mailbox){
                    $identityCache.$($assignedManagementRole.EffectiveUserName) = $False
                }
            }
        }catch{
            $identityCache.$($assignedManagementRole.EffectiveUserName) = $False
        }
        if($false -eq $identityCache.$($assignedManagementRole.EffectiveUserName)){
            #non existent role assignment (eg a group that is expanded in a later return value)? Check for apps later
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
    
    Write-Progress -Id 1 -PercentComplete 75 -Activity "Scanning Exchange Online" -Status "Writing report..."

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

    $global:statObj."Scan end time" = Get-Date    

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
                $global:statObj | Export-Excel -Path $targetPath -WorksheetName "Statistics" -TableName "Statistics" -TableStyle Medium10 -Append -AutoSize
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