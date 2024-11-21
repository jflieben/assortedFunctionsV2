function Update-StatisticsObject{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Category,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,
        [Int]$Amount = 1
    )
    
    if(!$global:unifiedStatistics.$category.$subject){
        New-StatisticsObject -category $category -subject $subject
    }

    $global:unifiedStatistics.$category.$subject."Total objects scanned" += $amount
}        