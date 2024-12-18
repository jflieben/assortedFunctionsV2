function Start-ScanJobs{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>
       
    Param(        
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title
    )

    $baseScriptBlock = {
        param (
            [string]$ModulePath,
            [string]$FunctionName,
            [hashtable]$Arguments,
            [hashtable]$octo
        )
        $global:octo = $octo
        Import-Module -Name $ModulePath -Force
        & $FunctionName @Arguments
    }

    Write-Verbose "Start multithreading $Title $($global:octo.ScanJobs.$($Title).Jobs.Count) jobs $($global:octo.maxThreads) at a time using $($global:octo.ScanJobs.$($Title).FunctionToRun)"

    Write-Progress -Id 1 -Activity $Title -Status "Starting initial threads" -PercentComplete 0
    
    [Int]$batchSize = 25
    [Int]$doneUntil = $batchSize
    while($true){
        [Int]$queuedJobs = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Queued"}).Count
        [Int]$runningJobs = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Running"}).Count
        [Int]$totalJobs = $global:octo.ScanJobs.$($Title).Jobs.Count
        [Int]$completedJobs = $totalJobs - $queuedJobs - $runningJobs
        try{$percentComplete = (($completedJobs / $totalJobs) * 100)}catch{$percentComplete = 0}
        Write-Progress -Id 1 -Activity $Title -Status "$completedJobs/$totalJobs Processing targets" -PercentComplete $percentComplete
        
        if($queuedJobs -eq 0 -and $runningJobs -eq 0){
            Write-Verbose "All jobs for $Title have finished"
            break
        }

        if($doneUntil -le $completedJobs){
            $doneUntil += $batchSize
            Reset-ReportQueue
        }

        #cycle over all jobs
        for($i = 0; $i -lt $totalJobs; $i++){
            #if job is running, check if it has completed
            if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Running"){
                $jobProgressBars = $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Progress
                if($jobProgressBars){
                    $uniqueIds = $jobProgressBars | Select-Object -ExpandProperty ActivityId -Unique
                    foreach($uniqueId in $uniqueIds){
                        $progressBar = @($jobProgressBars | Where-Object {$_.ActivityId -eq $uniqueId})[-1]
                        if($progressBar.RecordType -eq "Completed" -or $global:octo.ScanJobs.$($Title).Jobs[$i].Handle.IsCompleted){
                            Write-Progress -Id $($i+$uniqueId) -Completed
                        }else{
                            Write-Progress -Id $($i+$uniqueId) -Activity $progressBar.Activity -Status $progressBar.StatusDescription -PercentComplete $progressBar.PercentComplete
                        }
                    }
                }
                if($global:octo.ScanJobs.$($Title).Jobs[$i].Handle.IsCompleted -eq $True){
                    try{
                        if($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.HadErrors){
                            Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed with errors :(" -ForegroundColor DarkRed
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                        }else{
                            Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed without errors :)" -ForegroundColor Green
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                        }
                        Write-Host "---------OUTPUT START---------" -ForegroundColor DarkYellow
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.EndInvoke($global:octo.ScanJobs.$($Title).Jobs[$i].Handle)
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Warning
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Information
                        if($VerbosePreference -eq "Continue"){
                            $global:octo.ScanJobs.$($Title).Jobs.Thread.Streams.Debug
                            $global:octo.ScanJobs.$($Title).Jobs.Thread.Streams.Verbose
                        }
                        Write-Host "---------OUTPUT END-----------" -ForegroundColor DarkYellow

                    }catch{}                    

                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Dispose()
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $Null
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $Null
                }
            }
            #if job is queued, start it if we have room
            if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -eq "Queued"){
                if($runningJobs -lt $global:octo.maxThreads){
                    Write-Host "Starting $($global:octo.ScanJobs.$($Title).Jobs[$i].Target)"
                    $runningJobs++
                    $thread = [powershell]::Create().AddScript($baseScriptBlock)
                    $Null = $thread.AddParameter('ModulePath', $global:octo.modulePath)
                    $Null = $thread.AddParameter('FunctionName', $global:octo.ScanJobs.$Title.FunctionToRun)
                    $Null = $thread.AddParameter('Arguments', $global:octo.ScanJobs.$($Title).Jobs[$i].FunctionArguments)
                    $Null = $thread.AddParameter('octo', $global:octo)
                    $handle = $thread.BeginInvoke()
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Running"
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $handle
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $thread
                }
            }
        }

        Start-Sleep -Milliseconds 500
    }

    Reset-ReportQueue
}        