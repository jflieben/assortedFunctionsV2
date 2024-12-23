﻿Function get-AllPBIPermissions{
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
    }

    if(!$hasPowerBI){
        Write-Error "You do not have a PowerBI license, this function requires a PowerBI license assigned to the user you're logged in with" -ErrorAction Continue
        return $Null
    }

    Write-Host "Starting PowerBI scan..."
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

    Write-Progress -Id 1 -PercentComplete 10 -Activity $activity -Status "Waiting for scan jobs to complete..."
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
        foreach($report in $scanResults[$s].reports){
            Update-StatisticsObject -category "PowerBI" -subject "Securables"
            foreach($user in $report.users){
                $groupMembers = $null
                if($user.principalType -eq "Group" -and $expandGroups.IsPresent){
                    try{
                        $groupMembers = get-entraGroupMembers -groupId $user.graphId
                    }catch{
                        Write-Warning "Failed to retrieve group members for $($user.displayName), adding as group principal type instead"
                    }
                    foreach($groupMember in $groupMembers){
                        New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/reports/$($report.name)" -type "Report" -principalId $groupMember.id -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupmember.principalType -roleDefinitionName $user.reportUserAccessRight -through "Group" -parent $user.graphId -created $report.createdDateTime -modified $report.modifiedDateTime
                    }
                }
                if(!$groupMembers){
                    New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/reports/$($report.name)" -type "Report" -principalId $user.graphId -principalName $user.displayName -principalUpn $user.identifier -principalType "$($user.principalType) ($($user.userType))" -roleDefinitionName $user.reportUserAccessRight -created $report.createdDateTime -modified $report.modifiedDateTime
                }
            }
        }
        foreach($dataset in $scanResults[$s].datasets){
            Update-StatisticsObject -category "PowerBI" -subject "Securables"
            foreach($user in $dataset.users){
                $groupMembers = $Null
                if($user.principalType -eq "Group" -and $expandGroups.IsPresent){
                    try{
                        $groupMembers = get-entraGroupMembers -groupId $user.graphId
                    }catch{
                        Write-Warning "Failed to retrieve group members for $($user.displayName), adding as group principal type instead"
                    }
                    foreach($groupMember in $groupMembers){
                        New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/datasets/$($dataset.name)" -type "Dataset" -principalId $groupMember.id -principalName $groupMember.displayName -principalUpn $groupMember.userPrincipalName -principalType $groupmember.principalType -roleDefinitionName $user.datasetUserAccessRight -through "Group" -parent $user.graphId -created $dataset.createdDate
                    }
                }
                if(!$groupMembers){
                    New-PBIPermissionEntry -path "/workspaces/$($scanResults[$s].name)/datasets/$($dataset.name)" -type "Dataset" -principalId $user.graphId -principalName $user.displayName -principalUpn $user.identifier -principalType "$($user.principalType) ($($user.userType))" -roleDefinitionName $user.datasetUserAccessRight -created $dataset.createdDate
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