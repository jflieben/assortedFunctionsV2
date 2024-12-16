function Remove-ReportFileLock {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    $lockFilePath = Join-Path -Path $global:octo.outputFolder -ChildPath "M365Permissions.lock"
    Write-Verbose "Waiting for XLSX Module..."
    Start-Sleep -s 10
    Write-Verbose "Removing file lock..."
    Remove-Item -Path $lockFilePath -Force
    Write-Verbose "Lock removed!"
}