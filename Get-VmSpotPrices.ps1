function Get-VMSpotPrices{
    <#
    .LINK
        https://www.lieben.nu
    .NOTES
        Author: Jos Lieben
        Company: Lieben Consultancy
        Copyright: Free to use, but not to redistribute or resell
    .SYNOPSIS
        Retrieves the spot prices for a specific VM family in a given Azure region in USD and also returns the sku name
    .DESCRIPTION
        This function queries the Azure Resource Graph to get the spot prices for a specific VM family in a given Azure region.
        It uses the New-GraphQuery function of the M365Permissions module, you can substitute this with your own method
    .PARAMETER location
        The Azure region for which to retrieve spot prices, e.g. westeurope
    .PARAMETER vmFamily
        The (partial) VM family to filter spot prices, e.g. Standard_F2, Standard_F4
    .PARAMETER useHybridBenefit
        If specified, shows bare metal pricing, if omitted, shows pricing including Windows license
    #>
    Param(
        [Parameter(Mandatory=$true)][string]$location,
        [Parameter(Mandatory=$true)][string]$vmFamily,
        [Switch]$useHybridBenefit
    )

    $os = if($useHybridBenefit){"windows"}else{"linux"}

    $body = @{
        "query" = "spotresources | where type =~ 'microsoft.compute/skuspotpricehistory/ostype/location' and location =~ '$($location)' and kind =~ '$($os)' and sku contains '$($vmFamily)'"
    } | ConvertTo-Json -Compress
    
    $prices = New-GraphQuery -Uri "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" -Method Post -Body $body -resource "https://management.azure.com/" -MaxAttempts 2
    if($prices -and $prices.data){
        $prices.data | ForEach-Object {
            $latestPrice = $Null; $latestPrice = $_.properties.spotPrices | Sort-Object -Property effectiveDate -Descending | Select-Object -First 1
            @{
                sku = $_.sku.name
                price = $latestPrice.priceUSD
            }
        }
    }
}

