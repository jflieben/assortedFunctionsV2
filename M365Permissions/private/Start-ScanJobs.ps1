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
    
    [Int]$batchSize = 50
    [Int]$doneUntil = $batchSize
    [Array]$failedJobs = @()
    while($true){
        [Int]$queuedJobs = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Queued"}).Count
        [Int]$runningJobs = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Running"}).Count
        [Int]$failedJobsCount = ($global:octo.ScanJobs.$($Title).Jobs | Where-Object {$_.Status -eq "Failed"}).Count
        [Int]$totalJobs = $global:octo.ScanJobs.$($Title).Jobs.Count
        [Int]$completedJobs = $totalJobs - $queuedJobs - $runningJobs
        try{$percentComplete = (($completedJobs / $totalJobs) * 100)}catch{$percentComplete = 0}
        Write-Progress -Id 1 -Activity $Title -Status "$completedJobs/$totalJobs done of which $failedJobsCount have failed, $runningJobs active and $queuedJobs queued" -PercentComplete $percentComplete
        
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
                #handle timed out jobs
                if((Get-Date) -gt $global:octo.ScanJobs.$($Title).Jobs[$i].StartTime.AddMinutes($global:octo.defaultTimeoutMinutes)){
                    $failedJobs += $global:octo.ScanJobs.$($Title).Jobs[$i].Target
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                    Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has been running for more than $($global:octo.defaultTimeoutMinutes) minutes, killing it :(" -ForegroundColor DarkRed                                   
                }
                #handle completed jobs
                if($global:octo.ScanJobs.$($Title).Jobs[$i].Handle.IsCompleted -eq $True){
                    try{
                        if($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.HadErrors){
                            #check if the errors were terminating or not
                            $terminatingErrors= @(); $terminatingErrors = @($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error.Exception | Where-Object {$_ -and $_ -is [System.Management.Automation.RuntimeException]})
                            if($terminatingErrors.Count -gt 0){
                                Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed with critical errors :(" -ForegroundColor DarkRed
                                $global:octo.ScanJobs.$($Title).Jobs[$i].Attempts++
                                if($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts -lt $global:octo.maxJobRetries){
                                    Write-Host "Retrying $($global:octo.ScanJobs.$($Title).Jobs[$i].Target) after $($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts) failure(s)" -ForegroundColor Green
                                    Write-Host "---------OUTPUT START---------" -ForegroundColor DarkYellow
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error | fl *
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Warning | fl *
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Information | fl *
                                    if($VerbosePreference -eq "Continue"){
                                        $global:octo.ScanJobs.$($Title).Jobs.Thread.Streams.Debug | fl *
                                        $global:octo.ScanJobs.$($Title).Jobs.Thread.Streams.Verbose | fl *
                                    }
                                    Write-Host "---------OUTPUT END-----------" -ForegroundColor DarkYellow                                
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Queued"
                                }else{
                                    $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Failed"
                                    Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) failed $($global:octo.ScanJobs.$($Title).Jobs[$i].Attempts) times, abandoning Job..." -ForegroundColor DarkRed                                
                                    $failedJobs += $global:octo.ScanJobs.$($Title).Jobs[$i].Target
                                }
                            }else{
                                Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed, but had $($global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Error.Count) non-retryable errors :|" -ForegroundColor Yellow
                                $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                            }
                        }else{
                            Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has completed without any errors :)" -ForegroundColor Green
                            $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Succeeded"
                        }                                                    
                    }catch{
                        Write-Host "$($global:octo.ScanJobs.$($Title).Jobs[$i].Target) has crashed and will be retried" -ForegroundColor DarkRed
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Status = "Queued"
                    }
                }

                #show progress bars from the child job
                $jobProgressBars = $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Streams.Progress
                if($jobProgressBars){
                    $uniqueIds = $jobProgressBars | Select-Object -ExpandProperty ActivityId -Unique
                    foreach($uniqueId in $uniqueIds){
                        $progressBar = @($jobProgressBars | Where-Object {$_.ActivityId -eq $uniqueId})[-1]
                        if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -ne "Running" -or $progressBar.RecordType -eq "Completed"){
                            Write-Progress -Id $($i+$uniqueId) -Completed
                        }else{
                            Write-Progress -Id $($i+$uniqueId) -Activity $progressBar.Activity -Status $progressBar.StatusDescription -PercentComplete $progressBar.PercentComplete
                        }
                    }
                }                   

                #dispose of threads that have completed
                if($global:octo.ScanJobs.$($Title).Jobs[$i].Status -in ("Succeeded", "Failed")){
                    Write-Host "---------OUTPUT START---------" -ForegroundColor DarkYellow
                    try{
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
                    $global:octo.ScanJobs.$($Title).Jobs[$i].StartTime = Get-Date
                    if($global:octo.ScanJobs.$($Title).Jobs[$i].Handle){
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $Null 
                    }
                    if($global:octo.ScanJobs.$($Title).Jobs[$i].Thread){
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread.Dispose()
                        $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $Null
                    }      
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Handle = $handle
                    $global:octo.ScanJobs.$($Title).Jobs[$i].Thread = $thread
                }
            }
        }

        Start-Sleep -Milliseconds 500
    }

    if($failedJobs){
        Write-Host "The following targets failed: $($failedJobs -join ', ') even after retries. Try running these individually, if issues persist log an Issue in Github with verbose logs" -ForegroundColor DarkRed
        if($global:VerbosePreference -ne "Continue"){
            Write-Host "To run in Verbose mode, use set-M365PermissionsConfig -Verbose `$True before starting a scan."
        }else{
            Write-Host "Verbose log path: $($global:octo.outputTempFolder)\M365PermissionsVerbose.log"
        }
    }
    Reset-ReportQueue
}        