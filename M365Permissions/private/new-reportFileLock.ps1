function New-ReportFileLock {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    $lockFilePath = Join-Path -Path $global:octo.outputFolder -ChildPath "M365Permissions.lock"
    while((Test-Path -Path $lockFilePath)){
        Write-Verbose "Waiting for file lock to clear..."
        Start-Sleep -Seconds 1
    }
    Write-Verbose "Creating file lock..."    
    New-Item -Path $lockFilePath -ItemType File
    Write-Verbose "Lock created!"
}