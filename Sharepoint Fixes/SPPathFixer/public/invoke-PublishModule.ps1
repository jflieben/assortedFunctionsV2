<#
    Author               = "Jos Lieben (jos@lieben.nu)"
    CompanyName          = "Lieben Consultancy"
    Copyright            = "https://jsolve.nl/commercial-use.html"
#>    
function invoke-PublishModule {
    $apiKey = ""
    Publish-Module -Path "C:\Git\assortedFunctionsV2\Sharepoint Fixes\SPPathFixer" -NuGetApiKey $apiKey -Verbose
}