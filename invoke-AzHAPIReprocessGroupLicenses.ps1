function Invoke-AzHAPIReprocessGroupLicenses{
    <#
        .SYNOPSIS
        reprocesses group license assignment

        .NOTES
        Author: Jos Lieben

        .PARAMETER AzureRMToken
        Use Get-azureRMToken to get a token for this parameter

        .PARAMETER groupGUID
        GUID of the group to reprocess licenses of
    
        Requires:
        - Global Administrator Credentials (non-CSP!)
        - AzureRM Module
        - supply result of get-azureRMToken function
    #>
    param(
        [Parameter(Mandatory = $true)]$AzureRMToken,
        [Parameter(Mandatory = $true)]$groupGUID
    )
    $header = @{
        'Authorization' = 'Bearer ' + $AzureRMToken
        'X-Requested-With'= 'XMLHttpRequest'
        'x-ms-client-request-id'= [guid]::NewGuid()
        'x-ms-correlation-id' = [guid]::NewGuid()
    }   

    $url = "https://main.iam.ad.ext.azure.com/api/AccountSkus/Group/$groupGUID/Reprocess"
    Invoke-RestMethod –Uri $url –Headers $header –Method POST -Body $Null -UseBasicParsing -ErrorAction Stop -ContentType "application/json"
}