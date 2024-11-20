Function get-AllEntraPermissions{
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
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
    #>        
    Param(
        [Switch]$expandGroups,
        [Switch]$includeCurrentUser,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    $global:includeCurrentUser = $includeCurrentUser.IsPresent

    Write-Host "Performing Entra scan using: $($global:currentUser.userPrincipalName)"
    Write-Progress -Id 1 -PercentComplete 0 -Activity "Scanning Entra ID" -Status "Retrieving role definitions"
    $global:EntraPermissions = @{}

    $global:statObjRoles = [PSCustomObject]@{
        "Module version" = $global:moduleVersion
        "Category" = "Entra"
        "Subject" = "Roles"
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $global:currentUser.userPrincipalName
    }

    #get role definitions
    $roleDefinitions = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/directoryRoleTemplates' -Method GET

    Write-Progress -Id 1 -PercentComplete 5 -Activity "Scanning Entra ID" -Status "Retrieving fixed assigments"

    #get fixed assignments
    $roleAssignments = New-GraphQuery -Uri 'https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments?$expand=principal' -Method GET

    Write-Progress -Id 1 -PercentComplete 15 -Activity "Scanning Entra ID" -Status "Processing fixed assigments"

    foreach($roleAssignment in $roleAssignments){
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleAssignment.roleDefinitionId }
        $principalType = $roleAssignment.principal."@odata.type".Split(".")[2]
        if($principalType -eq "group" -and $expandGroups){
            $groupMembers = get-entraGroupMembers -groupId $principal.id        
            foreach($groupMember in $groupMembers){
                New-EntraPermissionEntry -path $roleAssignment.directoryScopeId -type "PermanentRole" -principalId $groupMember.id -roleDefinitionId $roleAssignment.roleDefinitionId -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupMember."@odata.type".Split(".")[2] -roleDefinitionName $roleDefinition.displayName -through "SecurityGroup" -parent $roleAssignment.principal.id
            }
        }else{
            New-EntraPermissionEntry -path $roleAssignment.directoryScopeId -type "PermanentRole" -principalId $roleAssignment.principal.id -roleDefinitionId $roleAssignment.roleDefinitionId -principalName $roleAssignment.principal.displayName -principalUpn $roleAssignment.principal.userPrincipalName -principalType $principalType -roleDefinitionName $roleDefinition.displayName
        }
    }

    Write-Progress -Id 1 -PercentComplete 25 -Activity "Scanning Entra ID" -Status "Retrieving flexible assigments"

    #get eligible role assignments
    try{
        $roleEligibilities = (New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances' -Method GET -NoRetry | Where-Object {$_})
    }catch{
        Write-Warning "Failed to retrieve flexible assignments, this is fine if you don't use PIM and/or don't have P2 licensing. Error details: $_"
        $roleEligibilities = @()
    }

    Write-Progress -Id 1 -PercentComplete 35 -Activity "Scanning Entra ID" -Status "Processing flexible assigments"

    $count = 0
    foreach($roleEligibility in $roleEligibilities){
        $count++
        Write-Progress -Id 2 -PercentComplete $(try{$count / $roleEligibilities.Count *100}catch{1}) -Activity "Processing flexible assignments" -Status "[$count / $($roleEligibilities.Count)]"
        $roleDefinition = $roleDefinitions | Where-Object { $_.id -eq $roleEligibility.roleDefinitionId }
        $principalType = "Unknown"
        try{
            $principal = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($roleEligibility.principalId)" -Method GET
            $principalType = $principal."@odata.type".Split(".")[2]
        }catch{
            Write-Warning "Failed to resolve principal $($roleEligibility.principalId) to a directory object, was it deleted?"    
            $principal = $Null
        }
        if($principalType -eq "group" -and $expandGroups){
            $groupMembers = get-entraGroupMembers -groupId $principal.id
            foreach($groupMember in $groupMembers){
                New-EntraPermissionEntry -path $roleEligibility.directoryScopeId -type "Eligible" -principalId $groupMember.id -roleDefinitionId $roleEligibility.roleDefinitionId -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupMember."@odata.type".Split(".")[2] -roleDefinitionName $roleDefinition.displayName -startDateTime $roleEligibility.startDateTime -endDateTime $roleEligibility.endDateTime -parent $principal.id -through "SecurityGroup"
            }
        }else{
            New-EntraPermissionEntry -path $roleEligibility.directoryScopeId -type "Eligible" -principalId $principal.id -roleDefinitionId $roleEligibility.roleDefinitionId -principalName $principal.displayName -principalUpn $principal.userPrincipalName -principalType $principalType -roleDefinitionName $roleDefinition.displayName -startDateTime $roleEligibility.startDateTime -endDateTime $roleEligibility.endDateTime
        }
    }
    Write-Progress -Id 2 -Completed -Activity "Processing flexible assignments"
    $global:statObjRoles."Scan end time" = Get-Date    


    $global:statObjEntities = [PSCustomObject]@{
        "Module version" = $global:moduleVersion
        "Category" = "Entra"
        "Subject" = "Entities"
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $global:currentUser.userPrincipalName
    }    
    Write-Progress -Id 1 -PercentComplete 45 -Activity "Scanning Entra ID" -Status "Getting users and groups" 
    $groupMemberRows = @()
    $allGroups = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/groups' -Method GET
    $count = 0
    foreach($group in $allGroups){
        $count++
        Write-Progress -Id 2 -PercentComplete $(try{$count / $allGroups.Count *100}catch{1}) -Activity "Processing groups" -Status "[$count / $($allGroups.Count)] $($group.displayName)"

        if($group.groupTypes -contains "Unified"){
            $groupType = "Microsoft 365 Group"
        }elseif($group.mailEnabled -and $group.securityEnabled){
            $groupType = "Mail-enabled Security Group"
        }elseif($group.mailEnabled -and -not $group.securityEnabled){
            $groupType = "Distribution Group"
        }elseif($group.membershipRule){
            $groupType = "Dynamic Security Group"
        }else{
            $groupType = "Security Group"
        }
        try{
            $groupOwners = $Null; $groupOwners = get-entraGroupOwners -groupId $group.id
        }catch{
            Write-Verbose "Failed to get owners for $($group.displayName) because $_"
        }
        $groupMembers = $Null; $groupMembers = get-entraGroupMembers -groupId $group.id
        foreach($groupMember in $groupMembers){
            $global:statObjEntities."Total objects scanned"++
            $memberRoles = "Member"
            if($groupOwners.id -contains $groupMember.id){
                $memberRoles = "Member, Owner"
            }
            $groupMemberRows += [PSCustomObject]@{
                "GroupName" = $group.displayName
                "GroupType" = $groupType
                "GroupID" = $group.id
                "MemberName" = $groupMember.displayName
                "MemberID" = $groupMember.id
                "MemberType" = $groupMember."@odata.type".Split(".")[2]
                "Roles" = $memberRoles
            }
        }
        foreach($groupOwner in $groupOwners){
            $global:statObjEntities."Total objects scanned"++
            if($groupMemberRows.MemberID -notcontains $groupOwner.id){
                $groupMemberRows += [PSCustomObject]@{
                    "GroupName" = $group.displayName
                    "GroupType" = $groupType
                    "GroupID" = $group.id
                    "MemberName" = $groupOwner.displayName
                    "MemberID" = $groupOwner.id
                    "MemberType" = $groupOwner."@odata.type".Split(".")[2]
                    "Roles" = "Owner"
                }
            }
        }
    }
    
    Write-Progress -Id 2 -Completed -Activity "Processing groups"
    $global:statObjEntities."Scan end time" = Get-Date

    Write-Progress -Id 1 -PercentComplete 90 -Activity "Scanning Entra ID" -Status "Writing report..."

    $permissionRows = foreach($row in $global:EntraPermissions.Keys){
        foreach($permission in $global:EntraPermissions.$row){
            [PSCustomObject]@{
                "Path" = $row
                "Type" = $permission.Type
                "principalName" = $permission.principalName
                "roleDefinitionName" = $permission.roleDefinitionName               
                "principalUpn" = $permission.principalUpn
                "principalType" = $permission.principalType
                "through" = $permission.through
                "parent" = $permission.parent
                "startDateTime" = $permission.startDateTime
                "endDateTime" = $permission.endDateTime
                "principalId"    = $permission.principalId                
                "roleDefinitionId" = $permission.roleDefinitionId
            }
        }
    }

    add-toReport -statistics $global:statObjRoles -formats $outputFormat -permissions $groupMemberRows -category "GroupsAndMembers"
    add-toReport -statistics $global:statObjEntities -formats $outputFormat -permissions $permissionRows -category "Entra"

    Write-Progress -Id 1 -Completed -Activity "Scanning Entra ID"
}