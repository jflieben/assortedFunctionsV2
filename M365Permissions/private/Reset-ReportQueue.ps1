function Reset-ReportQueue{
    Write-Verbose "Flushing report queue to file...."
    
    $dataBatch = @()
    if($global:octo.reportWriteQueue.Count -gt 0){
        #copy the report write queue to a clean array to be processed 
        $dataBatch =$global:octo.reportWriteQueue | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
        #reset the original queue
        $global:octo.reportWriteQueue = @()
    }

    if($dataBatch){
        Write-Verbose "Writing batch of $($dataBatch.Count) reports"
        $statistics =$Null; $statistics = ($dataBatch | Where{$_.statistics}).statistics
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