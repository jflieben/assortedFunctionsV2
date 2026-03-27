function Set-SPFixConfig {
    <#
    .SYNOPSIS
        Updates SPPathFixer configuration.
    .PARAMETER GuiPort
        TCP port for the web GUI.
    .PARAMETER MaxPathLength
        Default maximum path length (characters). Default: 400.
    .PARAMETER MaxPathLengthSpecial
        Max path length for special file types. Default: 260.
    .PARAMETER SpecialExtensions
        Comma-separated extensions that use MaxPathLengthSpecial (e.g. ".xlsx,.xlsm").
    .PARAMETER ExtensionFilter
        Only scan files with these extensions (comma-separated). Empty = all files.
    .PARAMETER MaxThreads
        Maximum concurrent Graph API requests. Default: 4.
    .PARAMETER OutputFormat
        Default export format: XLSX or CSV.
    .EXAMPLE
        Set-SPFixConfig -MaxPathLength 350
    .EXAMPLE
        Set-SPFixConfig -SpecialExtensions ".xlsx,.xlsm,.xltx" -MaxPathLengthSpecial 218
    #>
    [CmdletBinding()]
    param(
        [int]$GuiPort,
        [int]$MaxPathLength,
        [int]$MaxPathLengthSpecial,
        [string]$SpecialExtensions,
        [string]$ExtensionFilter,
        [int]$MaxThreads,
        [ValidateSet('XLSX','CSV')]
        [string]$OutputFormat
    )

    $engine = Get-SPFixEngine
    $config = $engine.GetConfig()

    if ($PSBoundParameters.ContainsKey('GuiPort')) { $config.GuiPort = $GuiPort }
    if ($PSBoundParameters.ContainsKey('MaxPathLength')) { $config.MaxPathLength = $MaxPathLength }
    if ($PSBoundParameters.ContainsKey('MaxPathLengthSpecial')) { $config.MaxPathLengthSpecial = $MaxPathLengthSpecial }
    if ($PSBoundParameters.ContainsKey('SpecialExtensions')) { $config.SpecialExtensions = $SpecialExtensions }
    if ($PSBoundParameters.ContainsKey('ExtensionFilter')) { $config.ExtensionFilter = $ExtensionFilter }
    if ($PSBoundParameters.ContainsKey('MaxThreads')) { $config.MaxThreads = $MaxThreads }
    if ($PSBoundParameters.ContainsKey('OutputFormat')) { $config.OutputFormat = $OutputFormat }

    $engine.UpdateConfig($config)
    Write-Host "Configuration updated." -ForegroundColor Green
}
