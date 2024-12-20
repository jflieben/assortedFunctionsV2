function New-ReportFileLock {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    $lockFilePath = Join-Path -Path $global:octo.outputFolder -ChildPath "M365Permissions.lock"
    if(!(Test-Path -Path $lockFilePath)){
        Write-Verbose "Creating lock file..."  
        $Null = New-Item -Path $lockFilePath -ItemType File -Force | Out-Null
        Write-Verbose "Lock file created!"
    }
    Write-Verbose "Creating lock..."
    while($True){
        try{
            $lock = [System.IO.File]::Open($lockFilePath, 'OpenOrCreate', 'ReadWrite', 'None')
            break
        }catch{
            Write-Verbose "Could not lock file, waiting for other process..."
            Start-Sleep -Seconds 1
        }
    }
    Write-Verbose "Lock created!"
    return $lock
}