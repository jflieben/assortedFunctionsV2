function Export-SPFixResults {
    <#
    .SYNOPSIS
        Exports scan results to XLSX or CSV.
    .PARAMETER ScanId
        The scan ID to export.
    .PARAMETER Format
        Export format: 'xlsx' or 'csv'. Default: xlsx.
    .PARAMETER OutputPath
        File path for the export. If not specified, saves to current directory.
    .EXAMPLE
        Export-SPFixResults -ScanId 1
    .EXAMPLE
        Export-SPFixResults -ScanId 1 -Format csv -OutputPath "C:\Reports\longpaths.csv"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$ScanId,
        [ValidateSet('xlsx','csv')]
        [string]$Format = 'xlsx',
        [string]$OutputPath
    )

    $engine = Get-SPFixEngine

    if (-not $OutputPath) {
        $ext = if ($Format -eq 'csv') { '.csv' } else { '.xlsx' }
        $OutputPath = Join-Path (Get-Location) "SPPathFixer_Scan${ScanId}_$(Get-Date -Format 'yyyyMMdd_HHmmss')$ext"
    }

    $bytes = $engine.Export($ScanId, $Format)
    [System.IO.File]::WriteAllBytes($OutputPath, $bytes)
    Write-Host "Exported to: $OutputPath" -ForegroundColor Green
    return $OutputPath
}
