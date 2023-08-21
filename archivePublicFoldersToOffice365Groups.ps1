######## 
#Archive on prem Public Folders to Office 365 Groups
#Copyright:         Free to use, please leave this header intact 
#Author:            Jos Lieben (OGD)
#Company:           OGD (http://www.ogd.nl) 
#Script help:       http://www.lieben.nu
#Purpose:           This script will scan your current public folders, determine the number of required O365 groups, create a migration endpoint, create O365 groups and create+start batches untill all are done
#How-To:
#1. Copy this script to your Exchange server hosting public folders
#2. On Exchange 2010, make sure you are compliant with https://technet.microsoft.com/library/mt843875(v=exchg.150).aspx
#3. On Exchange 2013, make sure you are compliant with https://technet.microsoft.com/library/mt843873(v=exchg.150).aspx
#4. On Exchange 2016, make sure you are compliant with https://technet.microsoft.com/library/mt843873(v=exchg.160).aspx
#5. If you have multiple PF or OWA servers, you may have to modify lines 109 through 114 of this script
#6. Open an exchange local shell and run this script
#7. If you need to resume the script at any time, simply re-run it, if the $reportFilePath has an existing file, the script will resume where it left off

#Notes:
#created groups are private, with the owner you decide in the script config
#email addresses of public folders are NOT copied
#permissions are NOT copied
#Migration might take long, especially if you have many subfolders
#contacts are not copied

Param(
    [Parameter(Mandatory=$true)][String]$O365GroupBaseName = "PF_ARCHIVE", #this will determine the O365 group names, a number will be suffixed
    [Parameter(Mandatory=$true)][Int]$maxGroupMailboxSize = 40, #in GB, at the time of writing, O365Groups have a 50GB limit, allowing for slight growth as we're just archiving, this is set to 40GB by default here. Smaller numbers mean more groups but also faster migrations
    [Parameter(Mandatory=$true)][String]$desiredO365GroupOwner = "group or user UPN or GUID", #the group or user here will be the ONLY person with access to the new groups created
    [Parameter(Mandatory=$true)][String]$onPremAdminUserName, #User name of on prem public folder admin that Office 365 can use to pull data with
    [ValidateSet(2010,2013,2016)][String]$exchangeVersion, #Version of your Exchange environment 
    [Parameter(Mandatory=$true)]$reportFilePath, #a csv file will be stored here containing all folders and current progress. If a file already exists, the script assumes you're resuming an existing migration and will skip a lot of stuff
    [Switch]$noNewModule
)

$o365GroupNames = @()
$nameIndex = 0
$PFtoGroupMapping = @()
#convert to KB
$maxGroupMailboxSize = $maxGroupMailboxSize*1024*1024
$existingMigration = [System.IO.File]::Exists($reportFilePath)

Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Asking for credentials..." -PercentComplete 0 -Id 1
if($existingMigration){
    Read-Host "You're resuming a migration, we'll just ask you for an admin login and get you on your way"
}else{
    Read-Host "We'll need to create some Office 365 groups, they'll be called $O365GroupBaseName[NUMBER]. But first we'll validate if your intended owner exists, press any key to proceed and log in to Office 365"
}

#connect to Exchange Online
try{
    $o365Creds = Get-Credential -ErrorAction Stop
    if(!$noNewModule){
        $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $o365Creds -Authentication Basic -AllowRedirection
        Import-PSSession $Session -AllowClobber -DisableNameChecking
    }
}catch{
    Write-Error "Failed to connect to Exchange Online! Check your login + password"
    Write-Error $_ -ErrorAction Stop    
}

Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Importing EXO module and saving it..." -PercentComplete 0 -Id 1
#export the ExO session
try{
    $temporaryModulePath = (Join-Path $Env:TEMP -ChildPath "temporaryEXOModule")
    if(!$noNewModule){
        Export-PSSession -Session $Session -CommandName * -OutputModule $temporaryModulePath -AllowClobber -Force
    }
    $temporaryModulePath = Join-Path $temporaryModulePath -ChildPath "temporaryEXOModule.psm1"
    Write-Host "Exchange module saved to $temporaryModulePath"
}catch{
    Write-Error "Failed to save ExO module!"
    Write-Error $_ -ErrorAction Stop    
}

Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Scanning and rewriting EXO module on the fly, this could take a few minutes..." -PercentComplete 5 -Id 1
try{
    if(!$noNewModule){
        $newContent = ""
        $found = $False
        (Get-Content $temporaryModulePath) | % {
            if(!$found -and $_.IndexOf("host.UI.PromptForCredential(") -ge 0){
                $line = "-Credential `$global:o365Creds ``"
                if($line){
                    $found = $True
                }
            }
            if($line){
                $newContent += $line
                $line=$Null
            }else{
                $newContent += $_
            }
            $newContent += "`r`n"
        }
        $newContent | Out-File -FilePath $temporaryModulePath -Force -Confirm:$False -ErrorAction Stop
    }
}catch{
    Write-Error "Failed to rewrite ExO module!"
    Write-Error $_ -ErrorAction Stop  
}

Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Module rewritten, reloading..." -PercentComplete 10 -Id 1

try{
    if(!$noNewModule){
        $Session | Remove-PSSession -Confirm:$False
    }
    Import-Module -Name $temporaryModulePath -Prefix EXO -DisableNameChecking -WarningAction SilentlyContinue -Force
}catch{
    Write-Error "Failed to reconnect to ExO!"
    Write-Error $_ -ErrorAction Stop  
}


if(!$existingMigration){
    Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Connected to Exchange Online..." -PercentComplete 0 -Id 1
    #Validate that the user supplied as owner of groups to be created, actually exists
    try{
        $mailbox = get-EXOmailbox -identity $desiredO365GroupOwner
        if($mailbox){
            #Mailbox found, good, we can exit
        }else{
            try{
                $group = get-EXOdistributiongroup -identity $desiredO365GroupOwner
                if($group){
                    #group found, fine too
                }else{
                    Throw "No mailbox or group found using $desiredO365GroupOwner as search parameter"
                }
            }catch{$_}
        }
    }catch{
        Write-Error $_ -ErrorAction Stop
    }

    Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Validated existence of $desiredO365GroupOwner" -PercentComplete 10 -Id 1
    $tenantDomain = @(get-EXOAcceptedDomain | Where-Object {$_.Name -Match ".onmicrosoft.com" -and $_.Name -NotMatch "mail.onmicrosoft.com"})[0].Name
    Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Exchange Online checkup" -Status "Discovered $tenantDomain domain" -PercentComplete 10 -Id 1

    #add first entry to the group names array
    $o365GroupNames += "$($O365GroupBaseName)$($nameIndex)@$($tenantDomain)"

    try{
        Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Onprem Exchange checkup" -Status "Discovering configuration" -PercentComplete 10 -Id 1
        Read-Host "Please enter the credentials for $onPremAdminUSerName in the following prompt, press any key when ready"
        $onpremCredential = Get-Credential
        if($exchangeVersion -eq 2010){
            $onPremAdminUserLegacyExchangeDN = @(Get-Mailbox $onPremAdminUserName)[0].LegacyExchangeDN
            Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Onprem Exchange checkup" -Status "Onprem admin DN: $onPremAdminUserLegacyExchangeDN" -PercentComplete 10 -Id 1
            $onPremExchangeServerDN = @(Get-ExchangeServer)[0].ExchangeLegacyDN ##NOTE: THIS ASSUMES YOUR FIRST SERVER IS YOUR PUBLIC FOLDER SERVER! Modify if needed
            Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Onprem Exchange checkup" -Status "Onprem exchange DN: $onPremExchangeServerDN" -PercentComplete 10 -Id 1
        }
        $outlookAnywhereHostname = @(Get-OutlookAnywhere)[0].ExternalHostName.HostNameString ##NOTE: THIS ASSUMES YOUR FIRST SERVER IS YOUR OWA SERVER! Modify if needed
    }catch{
        Write-Error $_ -ErrorAction Stop
    }

    try{
        Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Onprem Exchange checkup" -Status "Reading current public folder layout" -PercentComplete 10 -Id 1

        $reportFilePath = Join-Path $Env:Temp -childPath "pfToO365GroupsMigrationStatus.csv"
        #loop over all public folders
        $stats = get-publicfolderstatistics -ResultSize Unlimited | sort-object -Property FolderPath
        ac $reportFilePath "topLevelFolder,folderPath,size,itemCount,contactCount,targetGroup,migrationStatus,errorCount,itemsMigrated,dataMigrated" -Encoding UTF8
        $currentCount = 0
        $totalSize = 0
        $resettableSize = 0
        $topLevelFolderName = $Null
        ForEach($folder in $stats) {
            if($folder.FolderPath.StartsWith("SCHEDULE+")){#should be skipped
                continue
            }
            $currentCount++
            Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Onprem Exchange checkup" -Status "$currentCount / $($stats.Count) analysing $($folder.FolderPath)" -PercentComplete 10 -Id 1
            #check if we are in a top level folder
            if($folder.FolderPath.IndexOf("\") -eq -1){
                $topLevelFolderName = $folder.FolderPath
            
            }
            $thisFolderSize = $folder.TotalItemSize.value.ToKb()
            $totalSize += $thisFolderSize
            $resettableSize += $thisFolderSize
            if($resettableSize -ge $maxGroupMailboxSize){
                $resettableSize=0
                $nameIndex++
                $o365GroupNames += "$($O365GroupBaseName)$($nameIndex)@$($tenantDomain)"
                write-host "$($O365GroupBaseName)$($nameIndex)@$($tenantDomain)"
            }
            try{
                ac $reportFilePath "`"$topLevelFolderName`",`"$($folder.FolderPath.Trim())`",$($thisFolderSize/1024/1024),$($folder.itemCount),$($folder.contactCount),`"$($O365GroupBaseName)$($nameIndex)@$($tenantDomain)`",`"PENDING`",0,0,0" -ErrorAction Stop -Encoding UTF8
            }catch{
                sleep -s 2
                ac $reportFilePath "`"$topLevelFolderName`",`"$($folder.FolderPath.Trim())`",$($thisFolderSize/1024/1024),$($folder.itemCount),$($folder.contactCount),`"$($O365GroupBaseName)$($nameIndex)@$($tenantDomain)`",`"PENDING`",0,0,0" -Encoding UTF8
            }

        }
        Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Sleeping a few seconds to show you the final numbers" -Status "Folders: $totalFolders, Total size: $([math]::Round($totalSize/1024))MB, Required Groups: $($nameIndex+1)" -PercentComplete 30 -Id 1
        sleep -s 10
    }catch{
        Write-Error "Failed to analyze current public folders, make sure you run this in your local Exchange Shell"
        Write-Error $_ -ErrorAction Stop
    }

    #create the required number of O365 Groups
    Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Creating Office 365 groups" -Status "Reading group list" -PercentComplete 30 -Id 1
    foreach($group in $o365GroupNames){
        Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Creating Office 365 groups" -Status "Creating $group" -PercentComplete 35 -Id 1
        $createdGroup = New-EXOUnifiedGroup -accesstype Private -alias $group.Split("@")[0] -DisplayName $group.Split("@")[0] -Name $group.Split("@")[0] -Owner $desiredO365GroupOwner
    }
    Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Creating Office 365 groups" -Status "$($o365GroupNames.Count) Groups created" -PercentComplete 40 -Id 1

    Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Checking migration endpoint" -Status "Discovering" -PercentComplete 45 -Id 1
    #Check the endpoint in ExO:
    $PfEndpoint = Get-EXOMigrationEndpoint | where {$_.Identity -eq "PFToGroupEndpointByScript" -and $_}
    if($PfEndpoint.Identity -ne "PFToGroupEndpointByScript"){
        Write-Progress -Activity "Preparing your Public Folders for Archiving to Office 365 Groups" -CurrentOperation "Checking migration endpoint" -Status "Does not exist -> Creating" -PercentComplete 50 -Id 1
        try{
            if($exchangeVersion -eq 2010){
                $PfEndpoint = New-EXOMigrationEndpoint -PublicFolderToUnifiedGroup -Name PFToGroupEndpointByScript -RPCProxyServer $outlookAnywhereHostname -Credentials $onpremCredential -SourceMailboxLegacyDN $onPremAdminUserLegacyExchangeDN -PublicFolderDatabaseServerLegacyDN $onPremExchangeServerDN -Authentication Basic
            }else{
                $PfEndpoint = New-EXOMigrationEndpoint -PublicFolderToUnifiedGroup -Name PFToGroupEndpointByScript -RemoteServer $outlookAnywhereHostname -Credentials $onpremCredential
            }
        }catch{
            Write-Error "Failed to create migration endpoint in Exchange Online!"
            Write-Error $_ -ErrorAction Stop
        }
    }
}

Write-Progress -Activity "Archiving Public Folders" -CurrentOperation "Preparing batches" -Status "...." -PercentComplete 0 -Id 1
$currentJobId = $Null
$scriptBlock = {
    Param(
        $reportFilePath,
        $o365Creds,
        $modulePath
    )
    $global:o365Creds = $o365Creds
    Get-PSSession | Remove-PSSession -Confirm:$False
    Import-Module -Name $modulePath -Prefix EXO -DisableNameChecking -WarningAction SilentlyContinue
    $PfEndpoint = Get-EXOMigrationEndpoint | where {$_.Identity -eq "PFToGroupEndpointByScript" -and $_}
    $tempCSVPath = Join-Path $Env:TEMP -ChildPath "TempCSVForImport.csv"
    $mappingData = Import-CSV -Delimiter "," -Path $reportFilePath
    $o365UniqueGroupNames = $mappingData | select-object -unique -Property targetGroup
    $o365GroupNames = @()
    foreach($group in $o365UniqueGroupNames){
        $o365GroupNames += $group.targetGroup    
    }
    $ErrorActionPreference = "Stop"
    $totalFolders = $mappingData.Count
    foreach($targetGroup in $o365GroupNames){
        $folderLoopCounter = -1
        foreach($folder in $mappingData){
            $folderLoopCounter++
            if($folder.targetGroup -ne $targetGroup){
                continue
            }
            #SUBMIT NEW BATCH JOB
            if($folder.migrationStatus -eq "PENDING"){
                #IF EMPTY folder, set it to ready and move to next group
                if($folder.itemCount -le 0 -or $folder.size -le 0){
                    $mappingData[$folderLoopCounter].migrationStatus = "COMPLETED"
                    write-output "$folderLoopCounter $($folder.folderPath) skipping because it is empty"
                    continue
                }
                #CHECK EXISTING BATCH JOB (in case of new session):
                try{
                    $existingBatch = Get-EXOMigrationBatch -Identity "PFToGroupEndpointByScriptMigrationBatch$($folderLoopCounter)" -erroraction stop
                    $mappingData[$folderLoopCounter].migrationStatus = "IN PROGRESS"
                    write-output "$folderLoopCounter $($folder.folderPath) already in progress"
                    break
                }catch{
                    $Null
                }
                #SUBMIT BATCH JOB CODE HERE:
                try{Remove-Item $tempCSVPath -Force -ErrorAction SilentlyContinue}catch{$Null}
                try{
                    Add-Content $tempCSVPath "FolderPath,TargetGroupMailbox" -Force -Encoding UTF8
                    Add-Content $tempCSVPath "`"\$($folder.FolderPath.Trim())`",$targetGroup" -Force -Encoding UTF8
                    $res = New-EXOMigrationBatch -Name "PFToGroupEndpointByScriptMigrationBatch$($folderLoopCounter)" -PublicFolderToUnifiedGroup -CSVData ([System.IO.File]::ReadAllBytes($tempCSVPath)) -SourceEndpoint $PfEndpoint.Identity -BadItemLimit unlimited -autostart
                    write-output "$folderLoopCounter $($folder.folderPath) submitted to group $targetGroup"
                    $mappingData[$folderLoopCounter].migrationStatus = "IN PROGRESS"
                }catch{
                    write-output "$folderLoopCounter $($folder.folderPath) failed to submit batchjob! reason:"
                    write-output $_
                }
                break
            }
            #CHECK ON RUNNING BATCH JOB
            if($folder.migrationStatus -eq "IN PROGRESS"){
                try{
                    $jobStatistics = Get-EXOMigrationUserStatistics -Identity $folder.targetGroup
                }catch{
                    write-output "$folderLoopCounter $targetGroup was in progress, but no job found, resubmitting job later"
                    $mappingData[$folderLoopCounter].migrationStatus = "PENDING"
                    break
                }
                #Update CSV and remove batch job once status is completed
                if($jobStatistics.PercentageComplete -eq 100 -or $jobStatistics.Status -like "Failed"){
                    #job done!
                    if($jobStatistics.Status -like "Failed"){
                        $mappingData[$folderLoopCounter].dataMigrated = $jobStatistics.ErrorSummary
                        $mappingData[$folderLoopCounter].migrationStatus = "FAILED"
                        write-output "$folderLoopCounter $targetGroup FAILED"
                    }else{
                        $mappingData[$folderLoopCounter].migrationStatus = "COMPLETED" 
                        write-output "$folderLoopCounter $targetGroup SUCCEEDED"   
                        $mappingData[$folderLoopCounter].dataMigrated = $jobStatistics.BytesTransferred 
                    }
                    $mappingData[$folderLoopCounter].errorCount = $jobStatistics.SkippedItemCount
                    $mappingData[$folderLoopCounter].itemsMigrated = $jobStatistics.SyncedItemCount
                    #REMOVE BATCH JOB:
                    try{
                        $res = Remove-EXOMigrationBatch -Identity "PFToGroupEndpointByScriptMigrationBatch$($folderLoopCounter)" -Confirm:$False
                        continue
                    }catch{
                        Sleep -s 30
                        try{
                            $res = Remove-EXOMigrationBatch -Identity "PFToGroupEndpointByScriptMigrationBatch$($folderLoopCounter)" -Confirm:$False
                        }catch{$Null}
                    }
                }else{
                    write-output "$folderLoopCounter $targetGroup in progress at $($jobStatistics.PercentageComplete) %"
                }             
                break
            }
            
        }    
    }
    try{
        $mappingData | Export-CSV -Path $reportFilePath -Force -Delimiter "," -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }catch{
        sleep -s 1
        $mappingData | Export-CSV -Path $reportFilePath -Force -Delimiter "," -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }
    Get-PSSession | Remove-PSSession -Confirm:$False
}
Write-Progress -Activity "Archiving Public Folders" -Status "Submitting first job before checking overall state" -CurrentOperation "..." -PercentComplete 0 -Id 1
$mappingData = Import-CSV -Delimiter "," -Path $reportFilePath
$o365UniqueGroupNames = $mappingData | select-object -unique -Property targetGroup
$currentJobId = (Start-Job -Name "pfMigrationJob" -ScriptBlock $scriptBlock -ArgumentList $reportFilePath, $o365Creds, $temporaryModulePath).Id
while($true){
    if($currentJobId -ne $Null){
        $currentJob = Get-Job -Id $currentJobId
        if($currentJob.State -ne "Running"){
            if($currentJob.State -eq "Completed"){
                $jobValue = Receive-Job -Id $currentJobId
                Write-Host $jobValue
                Get-Job | Remove-Job -Force -Confirm:$False
                $mappingData = Import-CSV -Delimiter "," -Path $reportFilePath
                $failedJobCount = @($mappingData | where-object {$_.migrationStatus -eq "FAILED"}).Count
                $succeededJobCount = @($mappingData | where-object {$_.migrationStatus -eq "COMPLETED"}).Count
                $totalJobCount = $mappingData.Count
                $pendingJobCount = $totalJobCount-$succeededJobCount-$failedJobCount
                try{$percentComplete = (1-($pendingJobCount/$totalJobCount))*100}catch{$percentComplete = 0}
                try{$percentFailed = (($failedJobCount/$totalJobCount))*100}catch{$percentFailed = 0}
                try{$percentSucceeded = (($succeededJobCount/$totalJobCount))*100}catch{$percentSucceeded = 0}
                Write-Progress -Activity "Archiving Public Folders" -Status "Uploading data, $([math]::Round($percentComplete,2))% done" -CurrentOperation "Remaining folders: $pendingJobCount/$totalJobCount  |  $failedJobCount failed ($([math]::Round($percentFailed,2))%)  |  $succeededJobCount succeeded ($([math]::Round($percentSucceeded,2))%)" -PercentComplete $percentComplete -Id 1
                $progressCounts = 2
                foreach($group in $o365UniqueGroupNames){
                    $pendingJobCount = @($mappingData | where-object {$_.migrationStatus -eq "PENDING" -and $_.targetGroup -eq  $($group.targetGroup)}).Count
                    if($pendingJobCount -gt 0){
                        $failedJobCount = @($mappingData | where-object {$_.migrationStatus -eq "FAILED" -and $_.targetGroup -eq  $($group.targetGroup)}).Count
                        $succeededJobCount = @($mappingData | where-object {$_.migrationStatus -eq "COMPLETED" -and $_.targetGroup -eq  $($group.targetGroup)}).Count
                        $currentJob = @($mappingData | where-object {$_.migrationStatus -eq "IN PROGRESS" -and $_.targetGroup -eq  $($group.targetGroup)})[0]
                        $totalJobCount = $pendingJobCount+$failedJobCount+$succeededJobCount
                        try{$percentComplete = (1-($pendingJobCount/$totalJobCount))*100}catch{$percentComplete = 0}
                        Write-Progress -Activity "-------> $($group.targetGroup)" -Status "$pendingJobCount folders left | failed: $failedJobCount, current: $($currentJob.folderPath) ($($currentJob.itemCount) items)" -PercentComplete $percentComplete -ParentId 1 -id $progressCounts
                        $progressCounts++
                    }
                }                
                $currentJobId = (Start-Job -Name "pfMigrationJob" -ScriptBlock $scriptBlock -ArgumentList $reportFilePath, $o365Creds, $temporaryModulePath).Id
            }else{
                Write-Host "Error in job?" -ForegroundColor Red
                Receive-Job -Id $currentJobId
                Sleep -s 10
                $currentJobId = (Start-Job -Name "pfMigrationJob" -ScriptBlock $scriptBlock -ArgumentList $reportFilePath, $o365Creds, $temporaryModulePath).Id
                Sleep -s 10
            } 
        }else{
            Sleep -s 10
        }
    }else{
        Write-Host "ERROR SUBMITTING FIRST JOB!" 
        Sleep -Seconds 300
    }    
}