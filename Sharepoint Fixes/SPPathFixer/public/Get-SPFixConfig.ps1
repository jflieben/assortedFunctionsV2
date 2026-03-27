function Get-SPFixConfig {
    <#
    .SYNOPSIS
        Gets the current SPPathFixer configuration.
    .EXAMPLE
        Get-SPFixConfig
    #>
    [CmdletBinding()]
    param()

    $engine = Get-SPFixEngine
    return $engine.GetConfig()
}
