<#
    Author               = "Jos Lieben (jos@lieben.nu)"
    CompanyName          = "Lieben Consultancy"
    Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
#>    
function invoke-PublishModule {
    $apiKey = ""
    Publish-Module -Path "C:\git\assortedFunctionsV2\TeamPermissions" -NuGetApiKey $apiKey -Verbose
}