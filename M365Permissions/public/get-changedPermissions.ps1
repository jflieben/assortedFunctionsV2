Function Get-ChangedPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -oldPermissionsFilePath: the path to the old permissions file. Leave one empty to auto-detect both
        -newPermissionsFilePath: the path to the new permissions file. Leave one empty to auto-detect both
    #>        
    Param(
        [String]$oldPermissionsFilePath,
        [String]$newPermissionsFilePath
    )

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
    }

    Write-Progress -Id 1 -Activity "Comparing data between $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "Loading data..." -PercentComplete 0

    $oldTabs = Import-Excel -Path $oldPermissionsFile.FullName -WorksheetName "*"
    $newTabs = Import-Excel -Path $newPermissionsFile.FullName -WorksheetName "*"

    Write-Host ""

    $diffResults = @{}
    $oldTabNames = ($oldTabs.GetEnumerator().Name | Where-Object {$_ -ne "Statistics"})

    $count = 0
    foreach ($oldTabName in $oldTabNames) {
        $count++
        try{$percentComplete = (($count  / ($oldTabNames.Count*2)) * 100)}catch{$percentComplete = 0}
        Write-Progress -Id 1 -Activity "Comparing data between $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "Processing $oldTabName" -PercentComplete $percentComplete
        if(!$diffResults.$($oldTabName)){
            $diffResults.$($oldTabName) = @()
        }

        $oldTab = $oldTabs.$($oldTabName)

        #current workload not found in new file
        $newTab = $Null; $newTab = $newTabs.$($oldTabName)
        if ($null -eq $newTab) {
            if($oldTab.Count -gt 0){
                $diffResults.$($oldTabName) += [PSCustomObject]@{
                    "ERROR" = "Worksheet $($oldTabName) not found in NEW file, did you include this in the latest scan?"
                }
            }
            continue
        }

        #current workload found, check for removals
        for($i=0;$i -lt $oldTab.Count;$i++){
            try{$percentComplete = ((($i+1)  / ($oldTab.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing removals for $oldTabName" -Status "$($i+1) / $($oldTab.Count))" -PercentComplete $percentComplete
                        
            $oldRow = $oldTab[$i] | ConvertTo-Json -Depth 10
            $exists = $False; $exists = $newTab.Where({
                ($_ | ConvertTo-Json -Depth 10) -eq $oldRow
            }, 'First')        
            
            if (!$exists) {
                [PSCustomObject]$diffItem = $oldRow | ConvertFrom-Json
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "Removed"
                $diffResults.$($oldTabName) += $diffItem
            }
        }
        Write-Host "Found $($diffResults.$($oldTabName).count) removed permissions for $oldTabName"
        Write-Progress -Id 2 -Activity "Processing removals for $oldTabName" -Completed      
    }

    $newTabNames = ($newTabs.GetEnumerator().Name | Where-Object {$_ -ne "Statistics"})
    foreach ($newTabName in $newTabNames) {
        $count++
        try{$percentComplete = (($count  / ($newTabNames.Count*2)) * 100)}catch{$percentComplete = 0}
        Write-Progress -Id 1 -Activity "Comparing data between $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "Processing $newTabName" -PercentComplete $percentComplete
        
        if(!$diffResults.$($newTabName)){
            $diffResults.$($newTabName) = @()
        }
        $newTab = $newTabs.$($newTabName)

        #current workload not found in old file
        $oldTab = $Null; $oldTab = $oldTabs.$($newTabName)
        if ($null -eq $oldTab) {
            if($newTab.Count -gt 0){
                $diffResults.$($newTabName) += [PSCustomObject]@{
                    "ERROR" = "Worksheet $($newTabName) not found in OLD file, did you include this in the previous scan?"
                }
            }
            continue
        }
        #current workload found, check for additions
        for($i=0;$i -lt $newTab.Count;$i++){
            try{$percentComplete = ((($i+1)  / ($newTab.Count+1)) * 100)}catch{$percentComplete = 0}
            Write-Progress -Id 2 -Activity "Processing additions for $newTabName" -Status "$($i+1) / $($newTab.Count))" -PercentComplete $percentComplete            
            $newRow = $newTab[$i] | ConvertTo-Json -Depth 10
            $existed = $False; $existed = $oldTab.Where({
                ($_ | ConvertTo-Json -Depth 10) -eq $newRow
            }, 'First')                         
            if (!$existed) {
                [PSCustomObject]$diffItem = $newRow | ConvertFrom-Json
                $diffItem | Add-Member -MemberType NoteProperty -Name Action -Value "New or Updated"
                $diffResults.$($newTabName) += $diffItem
            }
        }
        Write-Host "Found $($diffResults.$($newTabName).count) added or updated permissions for $newTabName"
        Write-Progress -Id 2 -Activity "Processing additions for $newTabName" -Completed
    }

    Write-Progress -Id 1 -Activity "Comparing data between $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Status "Saving data" -PercentComplete 99

    Remove-Variable -Name newTabs -Force
    Remove-Variable -Name oldTabs -Force

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

    Remove-Variable -Name diffResults -Force
    [System.GC]::Collect() 
    
    Write-Progress -Id 1 -Activity "Comparing data between $($oldPermissionsFile.LastWriteTime) and $($newPermissionsFile.LastWriteTime)" -Completed
}