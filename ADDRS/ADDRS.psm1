<#
    .SYNOPSIS
    ADDRS (Azure Dynamic Desktop Right Sizing) - Automatically right-sizes Azure VMs
    based on CPU/memory telemetry from Azure Monitor, combined with pricing and
    performance benchmark data.

    .DESCRIPTION
    Provides three exported functions for Azure VM right-sizing:
      * Get-VMRightSize            - Calculate the optimal VM SKU for a single VM
      * Set-VMRightSize            - Resize a single VM to its optimal SKU
      * Set-ResourceGroupRightSize - Resize all VMs in a resource group

    Data sources:
      * Azure Monitor / Log Analytics - CPU and memory performance counters
      * Azure Retail Prices API       - Pay-as-you-go pricing per SKU
      * Azure Compute Benchmark Docs  - CoreMark / Geekbench performance scores

    .NOTES
    Module:    ADDRS
    Author:    Jos Lieben / jos@lieben.nu
    Copyright: https://www.lieben.nu/liebensraum/commercial-use/
    Site:      https://www.lieben.nu/liebensraum/2022/05/automatic-modular-rightsizing-of-azure-vms-with-special-focus-on-azure-virtual-desktop/
    Created:   2022-05-16
    Rewritten: 2026-03-25
    Source:    https://gitlab.com/Lieben/assortedFunctions/-/tree/master/ADDRS
#>

#Requires -Version 7.0
#Requires -Modules Az.Compute, Az.OperationalInsights, Az.Resources, Az.Accounts

using namespace System.Collections.Generic

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Module-Scoped State
# ---------------------------------------------------------------------------

$script:VMSizeCache = @{
    Data      = $null
    Region    = $null
    Timestamp = [datetime]::MinValue
}

$script:VMPriceCache = @{
    Data      = $null
    Region    = $null
    Timestamp = [datetime]::MinValue
}

$script:CacheTTLMinutes = 120

#endregion

# ---------------------------------------------------------------------------
#region Private Functions
# ---------------------------------------------------------------------------

function Assert-SafeKQLIdentifier {
    <#
    .SYNOPSIS
        Validates that a string is safe to embed in a KQL query (prevents injection).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [string]$ParameterName = 'Value'
    )

    if ($Value -notmatch '^[a-zA-Z0-9\-_.]{1,255}$') {
        throw "Parameter '$ParameterName' contains characters that are not safe for KQL queries. Allowed: alphanumeric, hyphens, underscores, dots. Got: '$Value'"
    }
}


function Get-AzureVMSizeData {
    <#
    .SYNOPSIS
        Retrieves and caches available VM sizes for a given Azure region.
        Uses Get-AzComputeResourceSku for rich capability data with automatic
        fallback to Get-AzVMSize.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Region,

        [switch]$ForceRefresh
    )

    $cacheAge = (Get-Date) - $script:VMSizeCache.Timestamp
    if (-not $ForceRefresh -and
        $script:VMSizeCache.Data -and
        $script:VMSizeCache.Region -eq $Region -and
        $cacheAge.TotalMinutes -lt $script:CacheTTLMinutes) {
        Write-Verbose "VM size cache hit ($([int]$cacheAge.TotalMinutes) min old)"
        return $script:VMSizeCache.Data
    }

    Write-Verbose "Retrieving available VM sizes for region '$Region'..."
    $sizes = [List[PSCustomObject]]::new()

    try {
        $skus = Get-AzComputeResourceSku -Location $Region -ErrorAction Stop |
            Where-Object {
                $_.ResourceType -eq 'virtualMachines' -and
                -not ($_.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' })
            }

        foreach ($sku in $skus) {
            $caps = @{}
            foreach ($cap in $sku.Capabilities) {
                $caps[$cap.Name] = $cap.Value
            }
            $sizes.Add([PSCustomObject]@{
                Name                  = $sku.Name
                NumberOfCores         = [int]($caps['vCPUs'] ?? 0)
                MemoryInMB            = [int](([double]($caps['MemoryGB'] ?? 0)) * 1024)
                MaxDataDiskCount      = [int]($caps['MaxDataDiskCount'] ?? 0)
                AcceleratedNetworking = ($caps['AcceleratedNetworkingEnabled'] ?? 'False') -eq 'True'
                PremiumIO             = ($caps['PremiumIO'] ?? 'False') -eq 'True'
            })
        }
        Write-Verbose "Retrieved $($sizes.Count) VM sizes via Get-AzComputeResourceSku"
    }
    catch {
        Write-Warning "Get-AzComputeResourceSku failed, falling back to Get-AzVMSize: $_"
        $rawSizes = Get-AzVMSize -Location $Region -ErrorAction Stop

        foreach ($size in $rawSizes) {
            $sizes.Add([PSCustomObject]@{
                Name                  = $size.Name
                NumberOfCores         = $size.NumberOfCores
                MemoryInMB            = $size.MemoryInMB
                MaxDataDiskCount      = $size.MaxDataDiskCount
                AcceleratedNetworking = $false
                PremiumIO             = $false
            })
        }
        Write-Verbose "Retrieved $($sizes.Count) VM sizes via Get-AzVMSize (limited capability data)"
    }

    $script:VMSizeCache = @{
        Data      = $sizes
        Region    = $Region
        Timestamp = Get-Date
    }
    return $sizes
}


function Get-AzureVMPricingData {
    <#
    .SYNOPSIS
        Retrieves VM pricing from the Azure Retail Prices API and optionally
        merges compute benchmark scores from Microsoft documentation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Region,

        [string]$CurrencyCode = 'USD',

        [switch]$ForceRefresh
    )

    $cacheAge = (Get-Date) - $script:VMPriceCache.Timestamp
    if (-not $ForceRefresh -and
        $script:VMPriceCache.Data -and
        $script:VMPriceCache.Region -eq $Region -and
        $cacheAge.TotalMinutes -lt $script:CacheTTLMinutes) {
        Write-Verbose "Pricing cache hit ($([int]$cacheAge.TotalMinutes) min old)"
        return $script:VMPriceCache.Data
    }

    $vmSizes = Get-AzureVMSizeData -Region $Region

    # Azure Retail Prices API (stable endpoint, no preview api-version needed)
    Write-Verbose "Retrieving VM pricing data for region '$Region' in $CurrencyCode..."
    $prices = [List[PSCustomObject]]::new()
    $filter = "serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and armRegionName eq '$Region'"
    $uri = "https://prices.azure.com/api/retail/prices?currencyCode=$CurrencyCode&`$filter=$filter"

    do {
        $response = Invoke-RestMethod -Uri $uri -Method GET -ContentType 'application/json' -ErrorAction Stop
        foreach ($item in $response.Items) {
            $prices.Add($item)
        }
        $uri = $response.NextPageLink
    } while ($uri)

    Write-Verbose "Retrieved $($prices.Count) pricing entries"

    # Compute benchmark scores (best-effort, non-fatal)
    $benchmarkScores = @{}
    $benchmarkUrls = @(
        'https://raw.githubusercontent.com/MicrosoftDocs/azure-compute-docs/main/articles/virtual-machines/windows/compute-benchmark-scores.md'
        'https://raw.githubusercontent.com/MicrosoftDocs/azure-compute-docs/main/articles/virtual-machines/linux/compute-benchmark-scores.md'
    )

    foreach ($url in $benchmarkUrls) {
        try {
            $rawData = (Invoke-RestMethod -Uri $url -Method GET -UseBasicParsing -ErrorAction Stop) -split "`n"
            $scoreColIndex = -1
            $inTable = $false

            foreach ($line in $rawData) {
                if ($line -match '^\|\s*VM Size\s*\|') {
                    $headers = $line.Split('|') | ForEach-Object { $_.Trim() }
                    for ($i = 0; $i -lt $headers.Count; $i++) {
                        if ($headers[$i] -match 'Avg\s*Score|Score|CoreMark|Geekbench') {
                            $scoreColIndex = $i
                            break
                        }
                    }
                    if ($scoreColIndex -lt 0) { $scoreColIndex = 5 }
                    $inTable = $true
                    continue
                }

                if ($inTable -and $line -match '^\|[\s\-:]+\|') { continue }

                if ($inTable) {
                    if ($line -notmatch '^\|') { $inTable = $false; continue }

                    $cols = $line.Split('|')
                    if ($cols.Count -gt $scoreColIndex) {
                        $vmType = $cols[1].Trim()
                        $rawScore = $cols[$scoreColIndex].Trim() -replace '[^\d]', ''
                        if ($rawScore -and $vmType) {
                            $numScore = [int]$rawScore
                            if (-not $benchmarkScores.ContainsKey($vmType) -or $benchmarkScores[$vmType] -lt $numScore) {
                                $benchmarkScores[$vmType] = $numScore
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Verbose "Could not retrieve benchmark data from $($url): $_"
        }
    }

    Write-Verbose "Retrieved benchmark scores for $($benchmarkScores.Count) VM types"

    # Merge pricing + sizes + benchmarks
    $filteredPrices = $prices | Where-Object {
        -not $_.skuName.EndsWith('Spot') -and
        -not $_.skuName.EndsWith('Low Priority')
    }

    $result = [List[PSCustomObject]]::new()
    $uniqueSkus = $filteredPrices | Select-Object -ExpandProperty armSkuName -Unique

    foreach ($sku in $uniqueSkus) {
        $skuPrices = $filteredPrices | Where-Object { $_.armSkuName -eq $sku }
        $sizeInfo  = $vmSizes | Where-Object { $_.Name -eq $sku } | Select-Object -First 1

        $result.Add([PSCustomObject]@{
            Name          = $sku
            NumberOfCores = if ($sizeInfo) { $sizeInfo.NumberOfCores } else { 0 }
            MemoryInMB    = if ($sizeInfo) { $sizeInfo.MemoryInMB }   else { 0 }
            LinuxPrice    = ($skuPrices | Where-Object { -not $_.productName.EndsWith('Windows') } |
                            Select-Object -First 1).retailPrice
            WindowsPrice  = ($skuPrices | Where-Object { $_.productName.EndsWith('Windows') } |
                            Select-Object -First 1).retailPrice
            Performance   = $benchmarkScores[$sku]
        })
    }

    $script:VMPriceCache = @{
        Data      = $result
        Region    = $Region
        Timestamp = Get-Date
    }

    Write-Verbose "Built pricing dataset for $($result.Count) unique VM SKUs"
    return $result
}


function Get-PerformanceStatistics {
    <#
    .SYNOPSIS
        Computes descriptive statistics and percentiles for an array of numeric values.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [double[]]$Data
    )

    $sorted = [double[]]($Data | Sort-Object)
    $count  = $sorted.Count

    $stats = $sorted | Microsoft.PowerShell.Utility\Measure-Object -Minimum -Maximum -Sum -Average

    # Median
    if ($count % 2 -eq 0) {
        $midLow  = $sorted[($count / 2) - 1]
        $midHigh = $sorted[$count / 2]
        $median  = ($midLow + $midHigh) / 2
    }
    else {
        $median = $sorted[[math]::Floor($count / 2)]
    }

    # Variance and standard deviation
    $variance = 0.0
    foreach ($val in $sorted) {
        $variance += [math]::Pow($val - $stats.Average, 2)
    }
    $variance /= $count
    $stdDev = [math]::Sqrt($variance)

    # Percentiles (nearest-rank method)
    $pctl = @{}
    foreach ($p in @(1, 5, 10, 25, 75, 90, 95, 99)) {
        $idx = [math]::Max(0, [math]::Ceiling($p / 100 * $count) - 1)
        $pctl[$p] = $sorted[$idx]
    }

    return [PSCustomObject]@{
        Count             = $count
        Minimum           = $stats.Minimum
        Maximum           = $stats.Maximum
        Sum               = $stats.Sum
        Average           = $stats.Average
        Median            = $median
        Variance          = $variance
        StandardDeviation = $stdDev
        Percentile1       = $pctl[1]
        Percentile5       = $pctl[5]
        Percentile10      = $pctl[10]
        Percentile25      = $pctl[25]
        Percentile75      = $pctl[75]
        Percentile90      = $pctl[90]
        Percentile95      = $pctl[95]
        Percentile99      = $pctl[99]
    }
}


function Invoke-VMResize {
    <#
    .SYNOPSIS
        Resizes a VM to the specified SKU (stopping it first if necessary).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [string]$NewSize,

        [switch]$Force,
        [switch]$Boot
    )

    if ($VM.HardwareProfile.VmSize -eq $NewSize) {
        Write-Verbose "$($VM.Name) is already at size $NewSize"
        return 'AlreadyCorrectSize'
    }

    if ($VM.PowerState -eq 'VM running') {
        if ($Force) {
            if ($PSCmdlet.ShouldProcess($VM.Name, "Stop VM (currently running) to resize to $NewSize")) {
                Write-Verbose "Stopping $($VM.Name) (running, -Force specified)..."
                $VM | Stop-AzVM -Confirm:$false -Force | Out-Null
                Write-Verbose "$($VM.Name) stopped"
            }
        }
        else {
            throw "$($VM.Name) is still running. Use -Force to allow automatic shutdown before resizing."
        }
    }
    else {
        Write-Verbose "$($VM.Name) is already stopped/deallocated"
    }

    $VM.HardwareProfile.VmSize = $NewSize

    if ($PSCmdlet.ShouldProcess($VM.Name, "Resize VM from current to $NewSize")) {
        Write-Verbose "Sending resize command for $($VM.Name)..."
        $result = ($VM | Update-AzVM -ErrorAction Stop)
        Write-Verbose "Resize result: $($result.StatusCode)"
    }
    else {
        Write-Verbose "Skipping resize (WhatIf mode)"
        $result = [PSCustomObject]@{ StatusCode = 'WhatIf' }
    }

    if ($Boot) {
        if ($PSCmdlet.ShouldProcess($VM.Name, "Start VM after resize")) {
            Write-Verbose "Starting $($VM.Name) (-Boot specified)..."
            $VM | Start-AzVM -Confirm:$false -NoWait | Out-Null
        }
    }

    return $result.StatusCode
}


function Build-MaintenanceWindowFilter {
    <#
    .SYNOPSIS
        Builds a KQL filter clause to exclude data collected during a maintenance window.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 23)]
        [int]$StartHour,

        [Parameter(Mandatory)]
        [ValidateRange(1, 24)]
        [int]$DurationHours,

        [Parameter(Mandatory)]
        [ValidateRange(0, 6)]
        [int]$DayOfWeek
    )

    $endHour = ($StartHour + $DurationHours) % 24
    $sameDay = ($StartHour + $DurationHours) -le 24
    $nextDay = ($DayOfWeek + 1) % 7

    if ($sameDay) {
        return " and ((dayofweek(TimeGenerated) == ${DayOfWeek}d and (hourofday(TimeGenerated) < $StartHour or hourofday(TimeGenerated) > $endHour)) or dayofweek(TimeGenerated) != ${DayOfWeek}d)"
    }
    else {
        return " and ((dayofweek(TimeGenerated) == ${DayOfWeek}d and hourofday(TimeGenerated) < $StartHour) or dayofweek(TimeGenerated) != ${DayOfWeek}d) and ((dayofweek(TimeGenerated) == ${nextDay}d and hourofday(TimeGenerated) > $endHour) or dayofweek(TimeGenerated) != ${nextDay}d)"
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Public Functions
# ---------------------------------------------------------------------------

function Get-VMRightSize {
    <#
    .SYNOPSIS
        Calculates the optimal VM size for a given Azure VM based on performance telemetry.

    .DESCRIPTION
        Queries Azure Monitor / Log Analytics for CPU and memory performance counters,
        then selects the cheapest VM SKU from the allowed list that meets the calculated
        resource requirements. Factors in pricing, performance benchmarks, and configurable
        thresholds with a buffer to prevent resize oscillation.

        The function does NOT perform any resize operation - use Set-VMRightSize for that.

    .PARAMETER Name
        Name of the target VM in Azure.

    .PARAMETER WorkspaceId
        GUID of the Log Analytics workspace that collects performance data.
        Use (Get-AzOperationalInsightsWorkspace).CustomerId to find this.

    .PARAMETER Domain
        FQDN domain suffix if your VMs are domain-joined (e.g. 'contoso.local').
        Appended to the VM name when querying Log Analytics.

    .PARAMETER MaintenanceWindowStartHour
        Start hour (0-23, UTC) of the maintenance window to exclude from analysis.

    .PARAMETER MaintenanceWindowDurationHours
        Length of the maintenance window in hours.

    .PARAMETER MaintenanceWindowDay
        Day of week (0=Sunday, 6=Saturday, UTC) when the maintenance window starts.

    .PARAMETER Region
        Azure region for pricing and size availability. Default: westeurope.

    .PARAMETER CurrencyCode
        Currency for pricing data. Default: USD.

    .PARAMETER LookbackHours
        Number of hours of performance data to analyze. Default: 168 (7 days).

    .PARAMETER AllowedSizes
        Array of VM size names to consider. Default: D-series and E-series v5/v6.

    .PARAMETER MinMemoryGB
        Minimum memory in GB to assign. Default: 2.

    .PARAMETER MaxMemoryGB
        Maximum memory in GB to assign. Default: 512.

    .PARAMETER MinvCPUs
        Minimum vCPU count. Default: 2 (required for accelerated networking).

    .PARAMETER MaxvCPUs
        Maximum vCPU count. Default: 64.

    .PARAMETER DefaultSize
        Fallback size when insufficient performance data exists.

    .PARAMETER DoNotCheckForRecentResize
        Skip the activity-log check that prevents re-resizing within the lookback period.

    .PARAMETER CPUThreshold
        CPU utilization threshold (0.0-1.0) for triggering a resize. Default: 0.75.

    .PARAMETER MemoryThreshold
        Memory utilization threshold (0.0-1.0) for triggering a resize. Default: 0.75.

    .PARAMETER BufferPercent
        Hysteresis buffer to prevent oscillation between sizes. Default: 0.10 (10%).

    .OUTPUTS
        PSCustomObject with properties: VMName, CurrentSize, RecommendedSize, Status,
        CostImpactPercent, CPUUsageP95, MemoryUsageP95, Reason.

    .EXAMPLE
        Get-VMRightSize -Name 'avd-vm-01' -WorkspaceId 'e32b3dbe-2850-4f88-9acb-2b919cce4126'

    .EXAMPLE
        Get-VMRightSize -Name 'avd-vm-01' -WorkspaceId $wsId -Domain 'corp.local' -LookbackHours 336 -Verbose
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [Alias('TargetVMName')]
        [string]$Name,

        [Parameter(Mandatory)]
        [Guid]$WorkspaceId,

        [string]$Domain,

        [ValidateRange(0, 23)]
        [int]$MaintenanceWindowStartHour = -1,

        [ValidateRange(1, 24)]
        [int]$MaintenanceWindowDurationHours,

        [ValidateRange(0, 6)]
        [int]$MaintenanceWindowDay,

        [string]$Region = 'westeurope',

        [string]$CurrencyCode = 'USD',

        [ValidateRange(1, 8760)]
        [int]$LookbackHours = 168,

        [string[]]$AllowedSizes = @(
            'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D8ds_v5', 'Standard_D16ds_v5',
            'Standard_D2ds_v6', 'Standard_D4ds_v6', 'Standard_D8ds_v6', 'Standard_D16ds_v6',
            'Standard_E2ds_v5', 'Standard_E4ds_v5', 'Standard_E8ds_v5', 'Standard_E16ds_v5',
            'Standard_E2ds_v6', 'Standard_E4ds_v6', 'Standard_E8ds_v6', 'Standard_E16ds_v6'
        ),

        [ValidateRange(1, 4096)]
        [int]$MinMemoryGB = 2,

        [ValidateRange(1, 4096)]
        [int]$MaxMemoryGB = 512,

        [ValidateRange(1, 128)]
        [int]$MinvCPUs = 2,

        [ValidateRange(1, 128)]
        [int]$MaxvCPUs = 64,

        [string]$DefaultSize = '',

        [switch]$DoNotCheckForRecentResize,

        [ValidateRange(0.1, 0.99)]
        [double]$CPUThreshold = 0.75,

        [ValidateRange(0.1, 0.99)]
        [double]$MemoryThreshold = 0.75,

        [ValidateRange(0.01, 0.5)]
        [double]$BufferPercent = 0.10
    )

    Assert-SafeKQLIdentifier -Value $Name -ParameterName 'Name'
    if ($Domain) {
        Assert-SafeKQLIdentifier -Value $Domain -ParameterName 'Domain'
    }

    # Helper to build result objects
    $newResult = {
        param($Status, $Reason, $RecommendedSize, $CostImpact, $CpuP95, $MemP95)
        [PSCustomObject]@{
            VMName            = $Name
            CurrentSize       = $currentSize
            RecommendedSize   = $RecommendedSize
            Status            = $Status
            CostImpactPercent = $CostImpact
            CPUUsageP95       = $CpuP95
            MemoryUsageP95    = $MemP95
            Reason            = $Reason
        }
    }
    $currentSize = $null

    # Compute thresholds with buffer
    $cpuUpperLimit = $CPUThreshold + $BufferPercent
    $cpuLowerLimit = $CPUThreshold - $BufferPercent
    $memUpperLimit = $MemoryThreshold + $BufferPercent
    $memLowerLimit = $MemoryThreshold - $BufferPercent

    # Load VM sizes and pricing
    $vmSizes  = Get-AzureVMSizeData  -Region $Region
    $vmPrices = Get-AzureVMPricingData -Region $Region -CurrencyCode $CurrencyCode

    # Build the enriched allowed VM types table
    $selectedTypes = [List[PSCustomObject]]::new()
    foreach ($allowed in $AllowedSizes) {
        if ($vmSizes.Name -notcontains $allowed) { continue }
        $pricing = $vmPrices | Where-Object { $_.Name -eq $allowed } | Select-Object -First 1
        if (-not $pricing) { continue }

        $selectedTypes.Add([PSCustomObject]@{
            Name          = $allowed
            NumberOfCores = $pricing.NumberOfCores
            MemoryInMB    = $pricing.MemoryInMB
            LinuxPrice    = $pricing.LinuxPrice
            WindowsPrice  = $pricing.WindowsPrice
            Performance   = $pricing.Performance
        })
    }

    $selectedTypes = $selectedTypes |
        Sort-Object @{Expression = { $_.WindowsPrice }; Ascending = $true },
                    @{Expression = { $_.Performance };   Ascending = $false },
                    @{Expression = { $_.Name.Split('_')[-1] }; Ascending = $false }

    Write-Verbose "Allowed VM types (available + priced): $($selectedTypes.Name -join ', ')"

    if ($selectedTypes.Count -eq 0) {
        return & $newResult 'Error' 'No allowed VM types are available with pricing data in this region.' $null $null $null $null
    }

    # Get target VM metadata
    try {
        $targetVM = Get-AzVM -Name $Name -ErrorAction Stop
        if (-not $targetVM) {
            return & $newResult 'Error' "$Name does not exist or you do not have permissions." $null $null $null $null
        }
        $currentSize = $targetVM.HardwareProfile.VmSize
        $currentHW = $vmSizes | Where-Object { $_.Name -eq $currentSize } | Select-Object -First 1
        if (-not $currentHW) {
            return & $newResult 'Error' "Current size '$currentSize' not found in Azure available VM list. Manual resize required." $currentSize $null $null $null
        }
        $currentPricing = $vmPrices | Where-Object { $_.Name -eq $currentSize } | Select-Object -First 1

        Write-Verbose "$Name currently: $($currentHW.NumberOfCores) vCPUs, $($currentHW.MemoryInMB) MB ($currentSize)"
    }
    catch {
        return & $newResult 'Error' "Failed to get VM metadata: $_" $null $null $null $null
    }

    # Check for LCRightSizeConfig tag override
    if ($targetVM.Tags -and $targetVM.Tags.ContainsKey('LCRightSizeConfig')) {
        $tagValue = $targetVM.Tags['LCRightSizeConfig']
        Write-Verbose "$Name has LCRightSizeConfig tag: $tagValue"

        if ($tagValue -eq 'disabled') {
            return & $newResult 'Disabled' 'Right-sizing disabled via Azure Tag (LCRightSizeConfig=disabled).' $currentSize $null $null $null
        }
        return & $newResult 'OverriddenByTag' "Size overridden to '$tagValue' via Azure Tag." $tagValue $null $null $null
    }

    # Check for recent resize
    if (-not $DoNotCheckForRecentResize) {
        Write-Verbose "$Name checking activity log for resizes in the last $LookbackHours hours..."
        try {
            $activityLog = Get-AzLog -ResourceId $targetVM.Id -StartTime (Get-Date).AddHours(-$LookbackHours) -WarningAction SilentlyContinue -ErrorAction Stop
            $recentlyResized = $false
            foreach ($entry in $activityLog) {
                if ($entry.Properties -and $entry.Properties.Content -and $entry.Properties.Content.responseBody) {
                    try {
                        $body = $entry.Properties.Content.responseBody | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($body.properties.hardwareProfile.vmSize) {
                            $recentlyResized = $true
                            break
                        }
                    }
                    catch { }
                }
            }
            if ($recentlyResized) {
                Write-Verbose "$Name was resized within the last $LookbackHours hours - skipping."
                return & $newResult 'RecentlyResized' "VM was resized within the last $LookbackHours hours. Use -DoNotCheckForRecentResize to override." $currentSize $null $null $null
            }
        }
        catch {
            Write-Verbose "Could not check activity log: $_"
        }
    }

    # Build KQL query components
    $computerName = if ($Domain) { "$Name.$Domain" } else { $Name }
    $queryAddition = ''
    if ($PSBoundParameters.ContainsKey('MaintenanceWindowStartHour') -and $MaintenanceWindowStartHour -ge 0 -and
        $PSBoundParameters.ContainsKey('MaintenanceWindowDurationHours') -and
        $PSBoundParameters.ContainsKey('MaintenanceWindowDay')) {

        $queryAddition = Build-MaintenanceWindowFilter -StartHour $MaintenanceWindowStartHour `
            -DurationHours $MaintenanceWindowDurationHours -DayOfWeek $MaintenanceWindowDay
        Write-Verbose "Excluding maintenance window: day=$MaintenanceWindowDay, start=$MaintenanceWindowStartHour, duration=$MaintenanceWindowDurationHours h"
    }

    # Query memory performance
    $memUsedPct = $null
    try {
        $memoryQuery = "Perf | where TimeGenerated between (ago(${LookbackHours}h) .. ago(0h)) and CounterName =~ 'Available MBytes' and Computer =~ '${computerName}'${queryAddition} | project TimeGenerated, CounterValue | order by CounterValue"
        Write-Verbose "Memory query (LA counter): $memoryQuery"
        $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $memoryQuery -ErrorAction Stop
        $memResults = [System.Linq.Enumerable]::ToArray($queryResult.Results)

        if ($memResults.Count -eq 0) {
            Write-Verbose "No 'Available MBytes' data, trying 'Available Bytes' (AMA)..."
            $memoryQuery = "Perf | where TimeGenerated between (ago(${LookbackHours}h) .. ago(0h)) and CounterName =~ 'Available Bytes' and Computer =~ '${computerName}'${queryAddition} | project TimeGenerated, CounterValue | order by CounterValue"
            $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $memoryQuery -ErrorAction Stop
            $memResults = [System.Linq.Enumerable]::ToArray($queryResult.Results)
            $memValues = [double[]]($memResults | ForEach-Object { [double]$_.CounterValue / 1MB })
        }
        else {
            $memValues = [double[]]($memResults | ForEach-Object { [double]$_.CounterValue })
        }

        Write-Verbose "Retrieved $($memResults.Count) memory data points"

        if ($memValues.Count -le ($LookbackHours * 4)) {
            if ($DefaultSize) {
                Write-Verbose "Insufficient memory data points - using DefaultSize '$DefaultSize'"
                return & $newResult 'InsufficientData' "Too few memory data points ($($memValues.Count)). Default size applied." $DefaultSize $null $null $null
            }
            return & $newResult 'InsufficientData' "Too few memory data points ($($memValues.Count)) to reliably calculate optimal size." $null $null $null $null
        }

        $memStats = Get-PerformanceStatistics -Data $memValues
        $memUsedPct = ($currentHW.MemoryInMB - $memStats.Percentile5) / $currentHW.MemoryInMB

        if ($memUsedPct -gt 1 -or $memUsedPct -lt 0 -or $memStats.Maximum -gt $currentHW.MemoryInMB) {
            return & $newResult 'Error' "Unexpected memory values detected. The VM may have been resized within the lookback period." $currentSize $null $null ([math]::Round($memUsedPct * 100, 2))
        }

        Write-Verbose "$Name memory: $($currentHW.MemoryInMB) MB total, 95th pctl used = $([math]::Round($memUsedPct * 100, 2))%"
    }
    catch {
        return & $newResult 'Error' "Failed to get memory performance data: $_" $null $null $null $null
    }

    # Query CPU performance
    $cpuUsedPct = $null
    try {
        $cpuQuery = "Perf | where TimeGenerated between (ago(${LookbackHours}h) .. ago(0h)) and CounterName =~ '% Processor Time' and Computer =~ '${computerName}'${queryAddition} | project TimeGenerated, CounterValue | order by CounterValue"
        Write-Verbose "CPU query: $cpuQuery"
        $queryResult = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $cpuQuery -ErrorAction Stop
        $cpuResults = [System.Linq.Enumerable]::ToArray($queryResult.Results)

        Write-Verbose "Retrieved $($cpuResults.Count) CPU data points"

        if ($cpuResults.Count -eq 0) {
            return & $newResult 'Error' "No CPU data returned. Verify the '% Processor Time' counter is enabled and the VM was running." $null $null $null $null
        }

        $cpuValues = [double[]]($cpuResults | ForEach-Object { [double]$_.CounterValue })

        if ($cpuValues.Count -le ($LookbackHours * 4)) {
            if ($DefaultSize) {
                Write-Verbose "Insufficient CPU data points - using DefaultSize '$DefaultSize'"
                return & $newResult 'InsufficientData' "Too few CPU data points ($($cpuValues.Count)). Default size applied." $DefaultSize $null $null $null
            }
            return & $newResult 'InsufficientData' "Too few CPU data points ($($cpuValues.Count)) to reliably calculate optimal size." $null $null $null $null
        }

        $cpuStats = Get-PerformanceStatistics -Data $cpuValues
        $cpuUsedPct = $cpuStats.Percentile95 / 100

        if ($cpuUsedPct -lt 0) {
            return & $newResult 'Error' "Negative CPU value detected. The VM may have been resized within the lookback period." $currentSize $null ([math]::Round($cpuUsedPct * 100, 2)) $null
        }

        Write-Verbose "$Name CPU: $($currentHW.NumberOfCores) cores, 95th pctl = $([math]::Round($cpuStats.Percentile95, 2))%"
    }
    catch {
        return & $newResult 'Error' "Failed to get CPU performance data: $_" $null $null $null $null
    }

    # Calculate target requirements
    $targetCPU = $currentHW.NumberOfCores
    $targetMemMB = $currentHW.MemoryInMB

    if ($cpuUsedPct -gt $cpuUpperLimit) {
        $targetCPU = [math]::Min($MaxvCPUs, [math]::Max($MinvCPUs, [math]::Ceiling($currentHW.NumberOfCores * ($cpuUsedPct / $cpuLowerLimit))))
    }
    elseif ($cpuUsedPct -lt $cpuLowerLimit) {
        $targetCPU = [math]::Max($MinvCPUs, [math]::Min($MaxvCPUs, [math]::Ceiling($currentHW.NumberOfCores * ($cpuUsedPct / $cpuUpperLimit))))
    }

    if ($memUsedPct -gt $memUpperLimit) {
        $targetMemMB = [math]::Min($MaxMemoryGB * 1024, [math]::Max($MinMemoryGB * 1024, [math]::Ceiling($currentHW.MemoryInMB * ($memUsedPct / $memLowerLimit))))
    }
    elseif ($memUsedPct -lt $memLowerLimit) {
        $targetMemMB = [math]::Max($MinMemoryGB * 1024, [math]::Min($MaxMemoryGB * 1024, [math]::Ceiling($currentHW.MemoryInMB * ($memUsedPct / $memUpperLimit))))
    }

    Write-Verbose "$Name target requirements: >= $targetCPU vCPUs, >= $targetMemMB MB memory"

    # Select optimal VM type
    $desiredType = $null
    foreach ($candidate in $selectedTypes) {
        if ($candidate.NumberOfCores -ge $targetCPU -and
            $candidate.NumberOfCores -le $MaxvCPUs -and
            $candidate.MemoryInMB -ge $targetMemMB -and
            $candidate.MemoryInMB -le ($MaxMemoryGB * 1024)) {
            $desiredType = $candidate
            break
        }
        Write-Verbose "  Skipping $($candidate.Name): $($candidate.NumberOfCores) vCPUs / $($candidate.MemoryInMB) MB does not meet $targetCPU vCPUs / $targetMemMB MB"
    }

    if (-not $desiredType) {
        return & $newResult 'Error' "No allowed VM type meets the requirements: >= $targetCPU vCPUs, >= $targetMemMB MB." $null $null `
            ([math]::Round($cpuUsedPct * 100, 2)) ([math]::Round($memUsedPct * 100, 2))
    }

    # Calculate cost impact
    $costImpact = $null
    if ($currentPricing -and $currentPricing.WindowsPrice -gt 0 -and $desiredType.WindowsPrice) {
        $costImpact = [math]::Round((($currentPricing.WindowsPrice - $desiredType.WindowsPrice) / $currentPricing.WindowsPrice) * -100, 2)
    }

    # Return recommendation
    if ($desiredType.Name -eq $currentSize) {
        Write-Verbose "$Name is already at optimal size ($currentSize)"
        return & $newResult 'AlreadyOptimal' 'VM is already at the optimal size.' $currentSize $costImpact `
            ([math]::Round($cpuUsedPct * 100, 2)) ([math]::Round($memUsedPct * 100, 2))
    }

    $direction = if ($costImpact -and $costImpact -lt 0) { 'downsize' } else { 'upsize' }
    $reason = "Recommendation: $direction from $currentSize to $($desiredType.Name) ($($desiredType.NumberOfCores) vCPUs, $($desiredType.MemoryInMB) MB)"
    if ($costImpact) {
        $reason += ". Cost impact: $($costImpact)%"
    }
    Write-Verbose $reason

    return & $newResult 'Recommendation' $reason $desiredType.Name $costImpact `
        ([math]::Round($cpuUsedPct * 100, 2)) ([math]::Round($memUsedPct * 100, 2))
}


function Set-VMRightSize {
    <#
    .SYNOPSIS
        Calculates and applies the optimal VM size for a single Azure VM.

    .DESCRIPTION
        Calls Get-VMRightSize to determine the recommendation, then resizes the VM.
        Supports -WhatIf and -Confirm for safe execution.

    .PARAMETER Name
        Name of the target VM.

    .PARAMETER WorkspaceId
        Log Analytics workspace GUID.

    .PARAMETER Force
        Allow automatic VM shutdown if the VM is running.

    .PARAMETER Boot
        Start the VM after resizing.

    .PARAMETER Report
        Return a structured report object instead of a simple status.

    .EXAMPLE
        Set-VMRightSize -Name 'avd-vm-01' -WorkspaceId $wsId -Force -Boot -Verbose

    .EXAMPLE
        Set-VMRightSize -Name 'avd-vm-01' -WorkspaceId $wsId -WhatIf -Verbose
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [Alias('TargetVMName')]
        [string]$Name,

        [Parameter(Mandatory)]
        [Guid]$WorkspaceId,

        [string]$Domain,

        [ValidateRange(0, 23)]
        [int]$MaintenanceWindowStartHour = -1,

        [ValidateRange(1, 24)]
        [int]$MaintenanceWindowDurationHours,

        [ValidateRange(0, 6)]
        [int]$MaintenanceWindowDay,

        [string]$Region = 'westeurope',

        [string]$CurrencyCode = 'USD',

        [ValidateRange(1, 8760)]
        [int]$LookbackHours = 168,

        [switch]$Force,
        [switch]$Boot,
        [switch]$Report,

        [string[]]$AllowedSizes = @(
            'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D8ds_v5', 'Standard_D16ds_v5',
            'Standard_D2ds_v6', 'Standard_D4ds_v6', 'Standard_D8ds_v6', 'Standard_D16ds_v6',
            'Standard_E2ds_v5', 'Standard_E4ds_v5', 'Standard_E8ds_v5', 'Standard_E16ds_v5',
            'Standard_E2ds_v6', 'Standard_E4ds_v6', 'Standard_E8ds_v6', 'Standard_E16ds_v6'
        ),

        [ValidateRange(1, 4096)]
        [int]$MinMemoryGB = 2,

        [ValidateRange(1, 4096)]
        [int]$MaxMemoryGB = 512,

        [ValidateRange(1, 128)]
        [int]$MinvCPUs = 2,

        [ValidateRange(1, 128)]
        [int]$MaxvCPUs = 64,

        [string]$DefaultSize = '',

        [switch]$DoNotCheckForRecentResize,

        [ValidateRange(0.1, 0.99)]
        [double]$CPUThreshold = 0.75,

        [ValidateRange(0.1, 0.99)]
        [double]$MemoryThreshold = 0.75,

        [ValidateRange(0.01, 0.5)]
        [double]$BufferPercent = 0.10
    )

    # Build splat for Get-VMRightSize (pass through all shared parameters)
    $getRightSizeParams = @{
        Name          = $Name
        WorkspaceId   = $WorkspaceId
        Region        = $Region
        CurrencyCode  = $CurrencyCode
        LookbackHours = $LookbackHours
        AllowedSizes  = $AllowedSizes
        MinMemoryGB   = $MinMemoryGB
        MaxMemoryGB   = $MaxMemoryGB
        MinvCPUs      = $MinvCPUs
        MaxvCPUs      = $MaxvCPUs
        DefaultSize   = $DefaultSize
        CPUThreshold  = $CPUThreshold
        MemoryThreshold = $MemoryThreshold
        BufferPercent = $BufferPercent
    }
    if ($Domain)                     { $getRightSizeParams['Domain'] = $Domain }
    if ($DoNotCheckForRecentResize)  { $getRightSizeParams['DoNotCheckForRecentResize'] = $true }
    if ($PSBoundParameters.ContainsKey('MaintenanceWindowStartHour') -and $MaintenanceWindowStartHour -ge 0) {
        $getRightSizeParams['MaintenanceWindowStartHour']    = $MaintenanceWindowStartHour
        $getRightSizeParams['MaintenanceWindowDurationHours'] = $MaintenanceWindowDurationHours
        $getRightSizeParams['MaintenanceWindowDay']           = $MaintenanceWindowDay
    }

    Write-Verbose "$Name - calculating optimal size..."
    $recommendation = Get-VMRightSize @getRightSizeParams

    # Build report row
    $reportRow = [PSCustomObject]@{
        VMName            = $Name
        CurrentSize       = $recommendation.CurrentSize
        TargetSize        = $recommendation.RecommendedSize
        Resized           = $false
        CostImpactPercent = $recommendation.CostImpactPercent
        CPUUsageP95       = $recommendation.CPUUsageP95
        MemoryUsageP95    = $recommendation.MemoryUsageP95
        Status            = $recommendation.Status
        Reason            = $recommendation.Reason
    }

    switch ($recommendation.Status) {
        'Recommendation' {
            try {
                Write-Verbose "$Name - resizing from $($recommendation.CurrentSize) to $($recommendation.RecommendedSize)..."
                $vm = Get-AzVM -Name $Name -Status -ErrorAction Stop
                $result = Invoke-VMResize -VM $vm -NewSize $recommendation.RecommendedSize -Force:$Force -Boot:$Boot
                if ($result -eq 'OK' -or $result -eq 'WhatIf') {
                    $reportRow.Resized = ($result -eq 'OK')
                }
            }
            catch {
                Write-Error "$Name - resize failed: $_"
                $reportRow.Reason = "Resize failed: $_"
            }
        }
        'OverriddenByTag' {
            try {
                $vm = Get-AzVM -Name $Name -Status -ErrorAction Stop
                if ($vm.HardwareProfile.VmSize -ne $recommendation.RecommendedSize) {
                    Write-Verbose "$Name - applying tag-specified size $($recommendation.RecommendedSize)..."
                    $result = Invoke-VMResize -VM $vm -NewSize $recommendation.RecommendedSize -Force:$Force -Boot:$Boot
                    $reportRow.Resized = ($result -eq 'OK')
                }
            }
            catch {
                Write-Error "$Name - tag-based resize failed: $_"
                $reportRow.Reason = "Tag-based resize failed: $_"
            }
        }
        'AlreadyOptimal' {
            Write-Verbose "$Name already at optimal size"
        }
        default {
            Write-Verbose "$Name - no resize: $($recommendation.Status) - $($recommendation.Reason)"
        }
    }

    if ($Report) {
        return $reportRow
    }
    elseif ($recommendation.Status -eq 'Recommendation') {
        return $reportRow.Resized
    }
    else {
        return $false
    }
}


function Set-ResourceGroupRightSize {
    <#
    .SYNOPSIS
        Right-sizes all VMs in a given Azure resource group.

    .DESCRIPTION
        Iterates over all VMs in the specified resource group and calls
        Set-VMRightSize for each one. Supports -WhatIf, -Confirm, -Force,
        and CSV report generation.

    .PARAMETER ResourceGroupName
        Name of the Azure resource group containing the target VMs.

    .PARAMETER Report
        Generate a CSV report and open it when complete.

    .PARAMETER ReportPath
        Custom path for the CSV report. Default: temp directory.

    .EXAMPLE
        Set-ResourceGroupRightSize -ResourceGroupName 'rg-avd-we-01' -WorkspaceId $wsId -Force

    .EXAMPLE
        Set-ResourceGroupRightSize -ResourceGroupName 'rg-avd-we-01' -WorkspaceId $wsId -WhatIf -Verbose

    .EXAMPLE
        Set-ResourceGroupRightSize -ResourceGroupName 'rg-avd-we-01' -WorkspaceId $wsId -Report -ReportPath 'C:\Reports\rightsize.csv'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [Alias('TargetRSG')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [Guid]$WorkspaceId,

        [string]$Domain,

        [ValidateRange(0, 23)]
        [int]$MaintenanceWindowStartHour = -1,

        [ValidateRange(1, 24)]
        [int]$MaintenanceWindowDurationHours,

        [ValidateRange(0, 6)]
        [int]$MaintenanceWindowDay,

        [string]$Region = 'westeurope',

        [string]$CurrencyCode = 'USD',

        [ValidateRange(1, 8760)]
        [int]$LookbackHours = 168,

        [switch]$Force,
        [switch]$Boot,
        [switch]$Report,

        [string]$ReportPath,

        [string[]]$AllowedSizes = @(
            'Standard_D2ds_v5', 'Standard_D4ds_v5', 'Standard_D8ds_v5', 'Standard_D16ds_v5',
            'Standard_D2ds_v6', 'Standard_D4ds_v6', 'Standard_D8ds_v6', 'Standard_D16ds_v6',
            'Standard_E2ds_v5', 'Standard_E4ds_v5', 'Standard_E8ds_v5', 'Standard_E16ds_v5',
            'Standard_E2ds_v6', 'Standard_E4ds_v6', 'Standard_E8ds_v6', 'Standard_E16ds_v6'
        ),

        [ValidateRange(1, 4096)]
        [int]$MinMemoryGB = 2,

        [ValidateRange(1, 4096)]
        [int]$MaxMemoryGB = 512,

        [ValidateRange(1, 128)]
        [int]$MinvCPUs = 2,

        [ValidateRange(1, 128)]
        [int]$MaxvCPUs = 64,

        [string]$DefaultSize = '',

        [switch]$DoNotCheckForRecentResize,

        [ValidateRange(0.1, 0.99)]
        [double]$CPUThreshold = 0.75,

        [ValidateRange(0.1, 0.99)]
        [double]$MemoryThreshold = 0.75,

        [ValidateRange(0.01, 0.5)]
        [double]$BufferPercent = 0.10
    )

    Write-Verbose "Enumerating VMs in resource group '$ResourceGroupName'..."
    $targetVMs = Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    Write-Verbose "Found $($targetVMs.Count) VMs"

    $reportRows = [List[PSCustomObject]]::new()

    foreach ($vm in $targetVMs) {
        Write-Verbose "Processing $($vm.Name)..."

        $setParams = @{
            Name          = $vm.Name
            WorkspaceId   = $WorkspaceId
            Region        = $Region
            CurrencyCode  = $CurrencyCode
            LookbackHours = $LookbackHours
            AllowedSizes  = $AllowedSizes
            MinMemoryGB   = $MinMemoryGB
            MaxMemoryGB   = $MaxMemoryGB
            MinvCPUs      = $MinvCPUs
            MaxvCPUs      = $MaxvCPUs
            DefaultSize   = $DefaultSize
            CPUThreshold  = $CPUThreshold
            MemoryThreshold = $MemoryThreshold
            BufferPercent = $BufferPercent
            Report        = $true
        }
        if ($Domain)                    { $setParams['Domain'] = $Domain }
        if ($Force)                     { $setParams['Force']  = $true }
        if ($Boot)                      { $setParams['Boot']   = $true }
        if ($DoNotCheckForRecentResize) { $setParams['DoNotCheckForRecentResize'] = $true }
        if ($WhatIfPreference)          { $setParams['WhatIf'] = $true }
        if ($PSBoundParameters.ContainsKey('MaintenanceWindowStartHour') -and $MaintenanceWindowStartHour -ge 0) {
            $setParams['MaintenanceWindowStartHour']    = $MaintenanceWindowStartHour
            $setParams['MaintenanceWindowDurationHours'] = $MaintenanceWindowDurationHours
            $setParams['MaintenanceWindowDay']           = $MaintenanceWindowDay
        }

        $row = Set-VMRightSize @setParams
        $reportRows.Add($row)

        if (-not $Report) {
            Write-Output $row
        }
    }

    if ($Report) {
        if (-not $ReportPath) {
            $ReportPath = Join-Path ([System.IO.Path]::GetTempPath()) "addrs-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        }
        Write-Verbose "Writing report ($($reportRows.Count) rows) to $ReportPath"
        $reportRows | Export-Csv -Path $ReportPath -Encoding UTF8 -NoTypeInformation -Force
        Write-Verbose "Report written to $ReportPath"
        Write-Output "Report saved to: $ReportPath"

        if (-not $WhatIfPreference) {
            Start-Process $ReportPath
        }
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Backward-Compatible Aliases
# ---------------------------------------------------------------------------

New-Alias -Name 'get-vmRightSize'    -Value 'Get-VMRightSize'            -Force -Scope Global
New-Alias -Name 'set-vmRightSize'    -Value 'Set-VMRightSize'            -Force -Scope Global
New-Alias -Name 'set-rsgRightSize'   -Value 'Set-ResourceGroupRightSize' -Force -Scope Global

#endregion
