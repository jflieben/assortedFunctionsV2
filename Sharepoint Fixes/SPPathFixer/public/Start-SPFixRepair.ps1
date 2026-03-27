function Start-SPFixRepair {
    <#
    .SYNOPSIS
        Starts fixing long paths found in a scan.
    .DESCRIPTION
        Applies the selected fix strategy to items from a completed scan.
        Strategies:
        - shorten_name: Truncates file/folder names while preserving extension
        - move_up: Moves items up one or more levels in the hierarchy
        - flatten_path: Moves items to the library root, preserving unique names
    .PARAMETER ScanId
        The scan ID containing items to fix.
    .PARAMETER Strategy
        Fix strategy to apply.
    .PARAMETER ItemIds
        Specific item IDs to fix. If omitted, fixes all unfixed items in the scan.
    .PARAMETER WhatIf
        Preview mode — shows what would be changed without making any changes.
    .EXAMPLE
        Start-SPFixRepair -ScanId 1 -Strategy shorten_name
    .EXAMPLE
        Start-SPFixRepair -ScanId 1 -Strategy move_up -ItemIds 10,25,30
    .EXAMPLE
        Start-SPFixRepair -ScanId 1 -Strategy flatten_path -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [long]$ScanId,
        [Parameter(Mandatory)]
        [ValidateSet('shorten_name','move_up','flatten_path')]
        [string]$Strategy,
        [long[]]$ItemIds,
        [switch]$WhatIf
    )

    $engine = Get-SPFixEngine
    $request = [SPPathFixer.Engine.Models.FixRequest]::new()
    $request.Strategy = $Strategy
    $request.WhatIf = $WhatIf.IsPresent
    if ($ItemIds) { $request.ItemIds = [System.Collections.Generic.List[long]]::new($ItemIds) }

    $batchId = $engine.StartFix($ScanId, $request)
    if ($WhatIf.IsPresent) {
        Write-Host "Preview generated (Batch: $batchId). Check results in the GUI or via Get-SPFixScanStatus." -ForegroundColor Yellow
    } else {
        Write-Host "Fix started (Batch: $batchId). Use Get-SPFixScanStatus to monitor progress." -ForegroundColor Cyan
    }
    return $batchId
}
