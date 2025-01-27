Function Get-deduplicatedReport{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -permissionsFilePath: the path to the new permissions file. Leave one empty to auto-detect both
    #>        
    Param(
        [Parameter(Mandatory=$false)][String]$permissionsFilePath
    )

    if(!$permissionsFilePath){
        $reportFiles = Get-ChildItem -Path $global:octo.outputFolder -Filter "*.xlsx" | Where-Object { $_.Name -notlike "*delta*" }
        if($reportFiles.Count -lt 1){
            Write-Error "Less than 1 XLSX reports found in $($global:octo.outputFolder). Please run a scan first or make sure you set the output format to XLSX. Deduplication is not possible when scanning to CSV format." -ErrorAction Stop
        }
        $lastReportFile = $reportFiles | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        $permissionsFile = $lastReportFile
        Write-Host "Auto detected permissions file to deduplicate: $($permissionsFile.FullName)"
    }else{
        $permissionsFile = Get-Item -Path $permissionsFilePath
    }

    Write-Progress -Id 1 -Activity "Deduplicating $($permissionsFile.Name)" -Status "Loading sheet metadata......" -PercentComplete 0

    $tabNames = Get-ExcelSheetInfo -Path $permissionsFile.FullName | Select-Object -ExpandProperty Name

    Write-Host ""

    $count = 0
    foreach ($tabName in $tabNames) {
        $count++
        try{$percentComplete = (($count  / ($tabNames.Count)) * 100)}catch{$percentComplete = 0}
        Write-Progress -Id 1 -Activity "Deduplicating $($permissionsFile.Name)" -Status "Loading $tabName into memory..." -PercentComplete $percentComplete

        $tab = Import-Excel -Path $permissionsFile.FullName -WorksheetName $tabName -DataOnly
        Write-Host "Loaded $($tab.Count) rows from $tabName"
        if($tab.Count -eq 0){
            Write-Host "No data found in $tabName, skipping"
            continue
        }

        Write-Progress -Id 1 -Activity "Deduplicating $($permissionsFile.Name)" -Status "Processing $tabName $($tab.Count) rows" -PercentComplete $percentComplete

        $uniqueObjects = [System.Collections.Generic.HashSet[string]]::new()

        $tabDeduped = $tab | Where-Object {
            $hash = ($_ | ConvertTo-Json -Depth 1)
            $uniqueObjects.Add($hash)
        }

        $duplicateCount = $tab.Count - $tabDeduped.Count
        if($duplicateCount -eq 0){
            Write-Host "No duplicate rows found in $tabName"
            [System.GC]::Collect() 
            continue
        }else{
            Write-Progress -Id 1 -Activity "Deduplicating $($permissionsFile.Name)" -Status "Exporting $tabName $($tabDeduped.Count) rows" -PercentComplete $percentComplete
            Write-Host "$($tab.Count) reduced to $($tabDeduped.Count) rows in $tabName, writing to file..." 
            $tabDeduped | Export-Excel -Path $permissionsFile.FullName -WorksheetName $tabName -TableName $tabName -TableStyle Medium10 -AutoSize -ClearSheet
            [System.GC]::Collect() 
        }
        
    }
    
    Write-Progress -Id 1 -Activity "Deduplicating $($permissionsFile.Name)" -Completed
}