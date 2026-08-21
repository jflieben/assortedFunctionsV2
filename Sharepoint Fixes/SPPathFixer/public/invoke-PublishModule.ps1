<#
    Author               = "Jos Lieben (jos@lieben.nu)"
    CompanyName          = "JSolve B.V."
    Copyright            = "https://jsolve.nl/commercial-use.html"
#>    
function invoke-PublishModule {
    $apiKey = ""
    Publish-Module -Path "C:\Git\assortedFunctionsV2\Sharepoint Fixes\SPPathFixer" -NuGetApiKey $apiKey -Verbose
}