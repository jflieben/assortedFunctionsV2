function New-StatisticsObject{
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
    
    if(!$global:unifiedStatistics){
        $global:unifiedStatistics = @{}
    }
    if(!$global:unifiedStatistics.$category){
        $global:unifiedStatistics.$category = @{}
    }
    $global:unifiedStatistics.$category.$subject = [PSCustomObject]@{
        "Module version" = [String]$($global:octo.moduleVersion)
        "Category" = $category
        "Subject" = $subject
        "Total objects scanned" = 0
        "Scan start time" = Get-Date
        "Scan end time" = ""
        "Scan performed by" = $global:octo.currentUser.userPrincipalName
    }
}        