Function get-AllPBIPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -excludeGroupsAndUsers: exclude group and user memberships from the report, only show role assignments
    #>        
    Param(
        [Switch]$expandGroups
    )

    $activity = "Scanning PowerBI"

    #check if user has a powerbi license or this function will fail
    if($global:octo.authMode -eq "Delegated"){
        $powerBIServicePlans = @("PBI_PREMIUM_EM1_ADDON","PBI_PREMIUM_EM2_ADDON","BI_AZURE_P_2_GOV","PBI_PREMIUM_P1_ADDON_GCC","PBI_PREMIUM_P1_ADDON","BI_AZURE_P3","BI_AZURE_P2","BI_AZURE_P1")
        $hasPowerBI = $False
        $licenses = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/users/$($global:octo.currentUser.userPrincipalName)/licenseDetails" -Method GET
        if($licenses){
            foreach($servicePlan in $licenses.servicePlans.servicePlanName){
                if($powerBIServicePlans -contains $servicePlan){
                    $hasPowerBI = $True
                    break
                }
            }
        }

        if(!$hasPowerBI){
            Write-Error "You do not have a PowerBI license, this function requires a PowerBI license assigned to the user you're logged in with" -ErrorAction Continue
            return $Null
        }
    }

    Write-Host "Starting PowerBI scan..."
    New-StatisticsObject -category "PowerBI" -subject "Securables"
    Write-Progress -Id 1 -PercentComplete 0 -Activity $activity -Status "Retrieving workspaces..."

    $global:PBIPermissions = @{}

    $workspaces = New-GraphQuery -Uri "https://api.powerbi.com/v1.0/myorg/admin/groups?`$top=5000" -resource "https://api.fabric.microsoft.com" -method "GET"
    $workspaceParts = [math]::ceiling($workspaces.Count / 100)

    if($workspaceParts -gt 500){
        Throw "More than 50000 workspaces detected, this module does not support environments with > 50000 workspaces yet. Submit a feature request."
    }

    Write-Progress -Id 1 -PercentComplete 5 -Activity $activity -Status "Submitting $workspaceParts scanjobs for $($workspaces.count) workspaces..."

    $scanJobs = @()
    for($i=0;$i -lt $workspaceParts;$i++){
        $body = @{"workspaces" = $workspaces.id[($i*100)..($i*100+99)]} | ConvertTo-Json
        if($i/16 -eq 1){
            Write-Host "Sleeping for 60 seconds to prevent throttling..."
            Start-Sleep -Seconds 60
        }
        $scanJobs += New-GraphQuery -Uri "https://api.powerbi.com/v1.0/myorg/admin/workspaces/getInfo?datasourceDetails=True&getArtifactUsers=True" -Method POST -Body $body -resource "https://api.fabric.microsoft.com"
    }

    if($global:octo.authMode -eq "Delegated"){
        Write-Progress -Id 1 -PercentComplete 10 -Activity $activity -Status "Retrieving gateways..."
        $gateways = New-GraphQuery -Uri "https://api.powerbi.com/v2.0/myorg/gatewayclusters?`$expand=permissions&`$skip=0&`$top=5000" -resource "https://api.fabric.microsoft.com" -method "GET"
        for($g = 0; $g -lt $gateways.count; $g++){
            Update-StatisticsObject -category "PowerBI" -subject "Securables"
            Write-Progress -Id 2 -PercentComplete $(Try{ ($g/$gateways.count)*100 } catch {0}) -Activity "Analyzing gateways..." -Status "$($g+1)/$($gateways.count) $($gateways[$g].id)"
            foreach($user in $gateways[$g].permissions){
                if($user.principalType -eq "Group"){
                    $groupMembers = $null
                    if($expandGroups.IsPresent){
                        try{
                            $groupMembers = get-entraGroupMembers -groupId $user.graphId
                            foreach($groupMember in $groupMembers){
                                New-PBIPermissionEntry -path "/gateways/$($gateways[$g].type)/$($gateways[$g].id)" -type "Gateway" -principalId $groupMember.id -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupmember.principalType -roleDefinitionName $user.role -through "Group" -parent $user.id
                            }                        
                        }catch{
                            Write-Warning "Failed to retrieve group members for $($user.id), adding as group principal type instead"
                        }
                    }
                    if(!$groupMembers){
                        New-PBIPermissionEntry -path "/gateways/$($gateways[$g].type)/$($gateways[$g].id)" -type "Gateway" -principalId $user.graphId -principalName $user.displayName -principalUpn "N/A" -principalType "$($user.principalType) ($($user.userType))" -roleDefinitionName $user.role
                    }
                }else{
                    $userId = $Null; $userId = $user.id.Replace("app-","")
                    if($user.id.startsWith("app-")){
                        $userMetaData = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/serviceprincipals(appId='$userId')" -Method GET
                    }else{
                        try{
                            $userMetaData = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/users/$userId" -Method GET -maxAttempts 2
                        }catch{
                            $userMetaData = @{
                                displayName = "Unknown (deleted user?)"
                                userPrincipalName = "Unknown"
                            }
                        }
                    }
                    New-PBIPermissionEntry -path "/gateways/$($gateways[$g].type)/$($gateways[$g].id)" -type "Gateway" -principalId $userId -principalName $userMetaData.displayName -principalUpn $userMetaData.userPrincipalName -principalType $user.principalType -roleDefinitionName $user.role
                }
            }
        }

        Write-Progress -Id 2 -Completed -Activity "Analyzing gateways..."
    }else{
        Write-Warning "Skipping gateway analysis, this function requires delegated authentication mode"
    }

    Write-Progress -Id 1 -PercentComplete 15 -Activity $activity -Status "Waiting for scan jobs to complete..."
    foreach($scanJob in $scanJobs){
        do{
            $res = New-GraphQuery -Uri "https://api.powerbi.com/v1.0/myorg/admin/workspaces/scanStatus/$($scanJob.id)" -Method GET -resource "https://api.fabric.microsoft.com"
            if($res.status -ne "Succeeded"){
                Write-Host "Scan job $($scanJob.id) status $($res.status), sleeping for 30 seconds..."
                Start-Sleep -Seconds 30
            }
        }until($res.status -eq "Succeeded")
        Write-Host "Scan job $($scanJob.id) completed"
    }

    Write-Progress -Id 1 -PercentComplete 25 -Activity $activity -Status "Receiving scan job results..."
    $scanResults = @()
    foreach($scanJob in $scanJobs){
        $scanResults += (New-GraphQuery -Uri "https://api.powerbi.com/v1.0/myorg/admin/workspaces/scanResult/$($scanJob.id)" -Method GET -resource "https://api.fabric.microsoft.com").workspaces
    }
    
    Write-Progress -Id 1 -PercentComplete 45 -Activity $activity -Status "Processing PowerBI securables..."
    for($s=0;$s -lt $scanResults.count; $s++){
        Write-Progress -Id 2 -PercentComplete $(Try{ ($s/$scanResults.count)*100 } catch {0}) -Activity "Analyzing securables..." -Status "$($s+1)/$($scanResults.count) $($scanResults[$s].name)"
        $secureableTypes = @{
            "reports" = @{
                "Type" = "Report"
                "UserAccessRightProperty" = "reportUserAccessRight"
                "CreatedProperty" = "createdDateTime"
                "ModifiedProperty" = "modifiedDateTime"
            }
            "datasets" = @{
                "Type" = "Dataset"
                "UserAccessRightProperty" = "datasetUserAccessRight"
                "CreatedProperty" = "createdDate"
                "ModifiedProperty" = "N/A"
            }    
            "Lakehouse" = @{
                "Type" = "Lakehouse"
                "UserAccessRightProperty" = "artifactUserAccessRight"
                "CreatedProperty" = "createdDate"
                "ModifiedProperty" = "lastUpdatedDate"
            } 
            "warehouses" = @{
                "Type" = "Warehouse"
                "UserAccessRightProperty" = "datamartUserAccessRight"
                "CreatedProperty" = "N/A"
                "ModifiedProperty" = "modifiedDateTime"
            }                                              
        }

        foreach($secureableType in $secureableTypes.Keys){
            foreach($secureable in $scanResults[$s].$secureableType){
                Update-StatisticsObject -category "PowerBI" -subject "Securables"
                $created = $secureableTypes.$secureableType.CreatedProperty -eq "N/A" ? "Unknown" : $secureable.$($secureableTypes.$secureableType.CreatedProperty)
                $modified = $secureableTypes.$secureableType.ModifiedProperty -eq "N/A" ? "Unknown" : $secureable.$($secureableTypes.$secureableType.ModifiedProperty)
                foreach($user in $secureable.users){
                    if($user.principalType -eq "Group"){
                        $groupMembers = $null;
                        if($expandGroups.IsPresent){
                            try{
                                 $groupMembers = get-entraGroupMembers -groupId $user.graphId
                                foreach($groupMember in $groupMembers){
                                    New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/$secureableType/$($secureable.name)" -type $secureableTypes.$secureableType.Type -principalId $groupMember.id -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupmember.principalType -roleDefinitionName $user.$($secureableTypes.$secureableType.UserAccessRightProperty) -through "Group" -parent $user.graphId -created $created -modified $modified
                                }                                
                            }catch{
                                Write-Warning "Failed to retrieve group members for $($user.displayName), adding as group principal type instead"
                            }                          
                        }
                        if(!$groupMembers){
                            New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/$secureableType/$($secureable.name)" -type $secureableTypes.$secureableType.Type -principalId $user.graphId -principalName $user.displayName -principalUpn "N/A" -principalType "$($user.principalType) ($($user.userType))" -roleDefinitionName $user.$($secureableTypes.$secureableType.UserAccessRightProperty) -created $created -modified $modified
                        }                                                            
                    }else{
                        New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/$secureableType/$($secureable.name)" -type $secureableTypes.$secureableType.Type -principalId $user.graphId -principalName $user.displayName -principalUpn $user.identifier -principalType "$($user.principalType) ($($user.userType))" -roleDefinitionName $user.$($secureableTypes.$secureableType.UserAccessRightProperty) -created $created -modified $modified
                    }
                }                  
            }
        }
    }

    Write-Progress -Id 2 -Completed -Activity "Analyzing securables..."

    Stop-StatisticsObject -category "PowerBI" -subject "Securables"

    Write-Progress -Id 1 -PercentComplete 90 -Activity $activity -Status "Writing report..."

    $permissionRows = foreach($row in $global:PBIPermissions.Keys){
        foreach($permission in $global:PBIPermissions.$row){
            [PSCustomObject]@{
                "Path" = $row
                "Type" = $permission.Type
                "principalName" = $permission.principalName
                "roleDefinitionName" = $permission.roleDefinitionName               
                "principalUpn" = $permission.principalUpn
                "principalType" = $permission.principalType
                "through" = $permission.through
                "parent" = $permission.parent
                "principalId"    = $permission.principalId  
                "created" = $permission.created
                "modified" = $permission.modified       
            }
        }
    }

    Add-ToReportQueue -permissions $permissionRows -category "PowerBI" -statistics @($global:unifiedStatistics."PowerBI"."Securables")
    Reset-ReportQueue
    Write-Progress -Id 1 -Completed -Activity $activity
}