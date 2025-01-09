function New-ScanJob{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>
       
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FunctionToRun,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [HashTable]$FunctionArguments
    )

    if(!$global:octo.ScanJobs.$Title){
        $global:octo.ScanJobs.$Title = @{
            "Jobs" = @()
            "FunctionToRun" = $FunctionToRun
            "Title" = $Title
        }
    }

    $global:octo.ScanJobs.$($Title).Jobs += [PSCustomObject]@{
        "Target" = $Target
        "FunctionArguments" = $FunctionArguments
        "Status" = "Queued"
        "Handle" = $Null
        "Thread" = $Null
        "StartTime" = $Null
        "Attempts" = 0
    }
}