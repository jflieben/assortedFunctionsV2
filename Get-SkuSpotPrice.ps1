function Get-SkuSpotPrice{
    <#
    .DESCRIPTION
    Retrieves SPOT price for the given SKU in the given subscription
    Use at own risk, uses a non-public API that may change without notice

    NOTE: New-GraphQuery is not included in this module, it is part of the M365Permissions module and is used to make Graph API calls. You may substitute your own or just pass a token for https://management.core.windows.net

    .PARAMETER virtualMachineSku
    The SKU of the virtual machine, e.g. Standard_F4als_v6
    
    .PARAMETER costGuid
    The cost GUID for the SKU, can be found in https://github.com/jflieben/assortedFunctionsV2/blob/main/azure_spot_vm_cost_guids.json

    .NOTES
    author:             Jos Lieben (Lieben Consultancy)
    Copyright/License:  free to use, but keep header intact0
    #>    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$subscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$virtualMachineSku,
        [Parameter(Mandatory = $true)]
        [string]$costGuid
    )

    $body = @{
        "subscriptionId" = $subscriptionId
        "specResourceSets"= @(
            @{"id"=$virtualMachineSku
                "firstParty" = @(@{"id"=$virtualMachineSku;"resourceId"=$costGuid;"quantity"=730})
            }                                              
        )
        "specsToAllowZeroCost" = @($virtualMachineSku)
        "specType"="Microsoft_Azure_Compute"
    }
    $costs = New-GraphQuery -Uri "https://s2.billing.ext.azure.com/api/Billing/Subscription/GetSpecsCosts?SpotPricing=true" -Method POST -resource "https://management.core.windows.net" -Body ($body | convertto-json -depth 10)
    $pricingData = $costs.costs | ForEach-Object {
        $skuName = $_.id
        $unitPrice = [double]($_.firstParty.meters.perUnitAmount | select -First 1) #array, but haven't seen any examples with more than 1, check to be sure if you use other resource types!
        $vCores = [int](($skuName -replace '^Standard_F', '') -replace '(\D.*)$', '')
        [PSCustomObject]@{
            SkuName = $skuName
            PricePerCore = $unitPrice / $vCores
            vCores = $vCores
            UnitPrice = $unitPrice
            perMonth = $unitPrice * 730 # assuming 730 hours in a month
        }
    } | Sort-Object -Property PricePerCore

    return $pricingData
}
