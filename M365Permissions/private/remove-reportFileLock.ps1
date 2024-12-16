function Remove-ReportFileLock {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    Param(
        [parameter(Mandatory=$true)]$lock
    )

    Write-Verbose "Removing lock in 10 seconds...."
    Start-Sleep -s 10
    $lock.Close()
    $lock.Dispose()
    Write-Verbose "Lock removed!"
}