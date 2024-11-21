function Stop-StatisticsObject{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$category,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$subject
    )

    $global:unifiedStatistics.$category.$subject."Scan end time" = Get-Date
}        