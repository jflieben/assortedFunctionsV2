Function get-EntraPermissions{
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

    if(!$global:LCCachedToken){
        get-AuthorizationCode
    }

    if(!$global:tenantName){
        $global:tenantName = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' -NoPagination | Where-Object -Property isInitial -EQ $true).id.Split(".")[0]
    }
    if(!$global:currentUser){
        $global:currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    }
    Write-Host "Performing Entra scan using: $($currentUser.userPrincipalName)"

    
    $global:EntraPermissions = @{}

    $statObj = [PSCustomObject]@{
        "Module version" = $MyInvocation.MyCommand.Module.Version
        "Category" = "Entra"
        "Subject" = "Roles"
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $currentUser.userPrincipalName
    }

    #get role definitions
    $roleDefinitions = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/directoryRoleTemplates' -Method GET

    #get fixed assignments
    $roleAssignments = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$expand=principal' -Method GET

    foreach($roleAssignment in $roleAssignments){
        $statObj."Total objects scanned"++
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleAssignment.roleDefinitionId }
        New-EntraPermissionEntry -path $roleAssignment.directoryScopeId -type "PermanentRole" -principalId $roleAssignment.principal.id -roleDefinitionId $roleAssignment.roleDefinitionId -principalName $roleAssignment.principal.displayName -principalUpn $roleAssignment.principal.userPrincipalName -principalType $roleAssignment.principal."@odata.type".Split(".")[2] -roleDefinitionName $roleDefinition.displayName
    }

    #get eligible role assignments
    $roleEligibilities = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleRequests' -NoPagination -Method GET
    foreach($roleEligibility in $roleEligibilities){
        $statObj."Total objects scanned"++
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleEligibility.roleDefinitionId }
        $principal = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($roleEligibility.principalId)" -Method GET
        New-EntraPermissionEntry -path $roleEligibility.directoryScopeId -type "EligibleRole" -principalId $principal.id -roleDefinitionId $roleEligibility.roleDefinitionId -principalName $principal.displayName -principalUpn $principal.userPrincipalName -principalType $principal."@odata.type".Split(".")[2] -roleDefinitionName $roleDefinition.displayName
    }
    
    $statObj."Scan end time" = Get-Date
    Write-Host "All permissions retrieved, writing reports..."
    $permissionRows = foreach($row in $global:EntraPermissions.Keys){
        foreach($permission in $global:EntraPermissions.$row){
            [PSCustomObject]@{
                "Path" = $row
                "Type" = $permission.Type
                "principalId"    = $permission.principalId
                "principalName" = $permission.principalName
                "principalUpn" = $permission.principalUpn
                "roleDefinitionId" = $permission.roleDefinitionId
                "roleDefinitionName" = $permission.roleDefinitionName         
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
                $permissionRows | Export-Excel -Path $targetPath -WorksheetName "EntraPermissions" -TableName "EntraPermissions" -TableStyle Medium10 -Append -AutoSize
                $statObj | Export-Excel -Path $targetPath -WorksheetName "Statistics" -TableName "Statistics" -TableStyle Medium10 -Append -AutoSize
                Write-Host "XLSX report saved to $targetPath"
            }
            "CSV" { 
                $targetPath = $basePath.Replace(".@@@","-Entra.csv")
                $permissionRows | Export-Csv -Path $targetPath -NoTypeInformation  -Append
                Write-Host "CSV report saved to $targetPath"
            }

            "Default" { $permissionRows | out-gridview }
        }
    }
}