Function Get-ChangedPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -oldPermissionsFilePath: the path to the old permissions file. Leave one empty to auto-detect both
        -newPermissionsFilePath: the path to the new permissions file. Leave one empty to auto-detect both
        -tabs: the tabs to compare, default is all tabs
    #>        
    Param(
        [String]$oldPermissionsFilePath,
        [String]$newPermissionsFilePath,
        [String[]]$tabs = @("Onedrive","Teams","O365Group","PowerBI","GroupsAndMembers","Entra","ExoRecipients","ExoRoles")
    )

    $excludeProps = @("modified")

    if(!$oldPermissionsFilePath -or !$newPermissionsFilePath){
        $reportFiles = Get-ChildItem -Path $global:octo.outputFolder -Filter "*.xlsx" | Where-Object { $_.Name -notlike "*delta*" }
        if($reportFiles.Count -lt 2){
            Write-Error "Less than 2 XLSX reports found in $($global:octo.outputFolder). Please run a scan first or make sure you set the output format to XLSX. Comparison is not possible when scanning to CSV format." -ErrorAction Stop
        }
        $lastTwoReportFiles = $reportFiles | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 2
        $oldPermissionsFile = $lastTwoReportFiles[1]
        Write-Host "Auto detected old permissions file: $($oldPermissionsFile.FullName)"
        $newPermissionsFile = $lastTwoReportFiles[0]
        Write-Host "Auto detected new permissions file: $($newPermissionsFile.FullName)"
    }else{
        $oldPermissionsFile = Get-Item -Path $oldPermissionsFilePath
        $newPermissionsFile = Get-Item -Path $newPermissionsFilePath
    }

    Write-Host ""

    $diffResults = @{}
    $count = 0
    foreach ($tabName in $tabs) {
        $count++
        try{$percentComplete = (($count  / ($tabs.Count)) * 100)}catch{$percentComplete = 0}
        Write-Progress -Id 1 -Activity "Comparing $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "$tabName Loading previous permissions..." -PercentComplete $percentComplete
        if(!$diffResults.$($tabName)){
            $diffResults.$($tabName) = @()
        }

        try{
            $oldTab = $Null; $oldTab = Import-Excel -Path $oldPermissionsFile.FullName -WorksheetName $tabName -DataOnly
        }catch{$null}

        Write-Progress -Id 1 -Activity "Comparing $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "$tabName Loading current permissions..." -PercentComplete $percentComplete
        
        try{
            $newTab = $Null; $newTab = Import-Excel -Path $newPermissionsFile.FullName -WorksheetName $tabName -DataOnly
        }catch{$null}

        #current workload not found in new file
        if ($null -eq $newTab) {
            if($oldTab.Count -gt 0){
                $diffResults.$($tabName) += [PSCustomObject]@{
                    "ERROR" = "Worksheet $($tabName) not found in NEW file, did you include this in the latest scan?"
                }
            }
            continue
        }

        #current workload not found in old file
        if ($null -eq $oldTab) {
            if($newTab.Count -gt 0){
                $diffResults.$($tabName) += [PSCustomObject]@{
                    "ERROR" = "Worksheet $($tabName) not found in OLD file, did you include this in the previous scan?"
                }
            }
            continue
        }        

        $newJsonSet = @{}
        foreach ($item in $newTab) {
            $json = $item | Select-Object -Property ($item.PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps }) | ConvertTo-Json -Depth 10
            $newJsonSet[$json] = $true  # Store JSON as keys in a hash table
        }      
        
        $oldJsonSet = @{}
        foreach ($item in $oldTab) {
            $json = $item | Select-Object -Property ($item.PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps }) | ConvertTo-Json -Depth 10
            $oldJsonSet[$json] = $true  # Store JSON as keys in a hash table
        }            

        #current workload found, check for removals
        for($i=0;$i -lt $oldTab.Count;$i++){
            try{$percentComplete = ((($i+1)  / ($oldTab.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing removals for $tabName" -Status "$($i+1) / $($oldTab.Count))" -PercentComplete $percentComplete
        
            $oldRow = $oldTab[$i] | Select-Object -Property ($oldTab[$i].PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps })  | ConvertTo-Json -Depth 10
            
            $existed = $newJsonSet.ContainsKey($oldRow)  
            if (!$existed) {
                [PSCustomObject]$diffItem = $oldTab[$i]
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "Removed"
                $diffResults.$($tabName) += $diffItem
            }
        }
        Write-Host "Found $($diffResults.$($tabName).count) removed permissions for $tabName"
        Write-Progress -Id 2 -Activity "Processing removals for $tabName" -Completed      

        #current workload found, check for additions
        for($i=0;$i -lt $newTab.Count;$i++){
            try{$percentComplete = ((($i+1)  / ($newTab.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing additions for $tabName" -Status "$($i+1) / $($newTab.Count))" -PercentComplete $percentComplete            
            $newRow = $newTab[$i] | Select-Object -Property ($newTab[$i].PSObject.Properties.Name | Where-Object { $_ -notin $excludeProps })  | ConvertTo-Json -Depth 10
            
            $existed = $oldJsonSet.ContainsKey($newRow)                      
            if (!$existed) {
                [PSCustomObject]$diffItem = $newTab[$i]
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "New or Updated"
                $diffResults.$($tabName) += $diffItem
            }
        }
        Write-Host "Found $($diffResults.$($tabName).count) added or updated permissions for $tabName"
        Write-Progress -Id 2 -Activity "Processing additions for $tabName" -Completed        
    }

    Write-Progress -Id 1 -Activity "Comparing $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "Saving data" -PercentComplete 99

    Remove-Variable -Name newTab -Force -Confirm:$False
    Remove-Variable -Name oldTab -Force -Confirm:$False

    Write-Host ""

    $targetPath = Join-Path -Path $global:octo.outputFolder -ChildPath "M365Permissions_delta.xlsx"
    foreach($tab in $diffResults.GetEnumerator().Name){
        if($diffResults.$($tab).count -eq 0){
            continue
        }
        $maxRetries = 60
        $attempts = 0
        while($attempts -lt $maxRetries){
            $attempts++
            try{
                $diffResults.$($tab) | Export-Excel -Path $targetPath -WorksheetName $tab -TableName $tab -TableStyle Medium10 -Append -AutoSize
                Write-Host "$($diffResults.$($tab).count) $tab delta's written to $targetPath"
                $attempts = $maxRetries
            }catch{
                if($attempts -eq $maxRetries){
                    Throw
                }else{
                    Write-Verbose "File locked, waiting..."
                    Start-Sleep -s (Get-Random -Minimum 1 -Maximum 3)
                }
            }
        }   
    }

    Remove-Variable -Name diffResults -Force -Confirm:$False
    [System.GC]::Collect() 
    
    Write-Progress -Id 1 -Activity "Comparing $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Completed
}