function Reset-ReportQueue{
    Write-Verbose "Start Flushing report queue to report file...."
    
    $dataBatch = @()
    $queuedFiles = Get-ChildItem -Path $global:octo.outputTempFolder -Filter "*.xml"
    if($queuedFiles.Count -gt 0){
        Write-Verbose "Reading batch of $($queuedFiles.Count) reports from queue..."
        foreach($queuedFile in $queuedFiles){
            $dataBatch += Import-Clixml -Path $queuedFile.FullName
            Remove-Item -Path $queuedFile.FullName -Force
        }  
    }

    if($dataBatch){
        Write-Verbose "Writing batch of $($dataBatch.Count) reports to report file..."
        $statistics =$Null; $statistics = ($dataBatch | Where-Object{$_.statistics}).statistics
        if($statistics){
            Export-WithRetry -category "Statistics" -data $statistics
        }
        $categories = $Null; $categories = $dataBatch.category | select-object -Unique
        foreach($category in $categories){
            $permissions = $Null; $permissions = ($dataBatch | Where-Object {$_.category -eq $category -and $_.permissions}).permissions
            if($permissions){
                Export-WithRetry -category $category -data $permissions
            }
        }   
        [System.GC]::Collect()   
    }
}