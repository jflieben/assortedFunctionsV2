Function get-SpOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -teamName: the name of the Team to scan
        -siteUrl: the URL of the Team (or any sharepoint location) to scan (e.g. if name is not unique)
        -expandGroups: if set, group memberships will be expanded to individual users
        -outputFormat: 
            HTML
            XLSX
            CSV
            Default (output to Out-GridView)
            Any combination of above is possible
        -ignoreCurrentUser: do not add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
    #>        
    Param(
        [Switch]$expandGroups,
        [parameter(Mandatory=$true)]
        [ValidateSet('HTML','XLSX','CSV','Default')]
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

    $global:statObj = [PSCustomObject]@{
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
        $global:statObj."Total objects scanned"++
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleAssignment.roleDefinitionId }
        New-EntraPermissionEntry -path $roleAssignment.directoryScopeId -type "PermanentRole" -principalId $roleAssignment.principal.id -roleDefinitionId $roleAssignment.roleDefinitionId -principalName $roleAssignment.principal.displayName -principalUpn $roleAssignment.principal.userPrincipalName -principalType $roleAssignment.principal."@odata.type".Split(".")[2] -roleDefinitionName $roleDefinition.displayName
    }

    #get eligible assignments
    #/roleManagement/directory/roleEligibilityScheduleRequests

    $global:statObj."Scan end time" = Get-Date
    $global:statistics += $global:statObj  
    Write-Host "All permissions retrieved, writing reports..."

    $permissionRows = foreach($row in $global:EntraPermissions.Keys){
        $global:EntraPermissions.$row
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
                $global:statistics | Export-Excel -Path $targetPath -WorksheetName "Statistics" -TableName "Statistics" -TableStyle Medium10 -Append -AutoSize
                Write-Host "XLSX report saved to $targetPath"
            }
            "CSV" { 
                $targetPath = $basePath.Replace("@@@","csv")
                $permissionRows | Export-Csv -Path "M365Permissions-Entra.csv" -NoTypeInformation  -Append
                Write-Host "CSV report saved to $targetPath"
            }

            "Default" { $permissionRows | out-gridview }
        }
    }
}