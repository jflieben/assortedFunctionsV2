function Get-SPFixScanStatus {
    <#
    .SYNOPSIS
        Gets the current scan or fix progress.
    .EXAMPLE
        Get-SPFixScanStatus
    #>
    [CmdletBinding()]
    param()

    $engine = Get-SPFixEngine
    $progress = $engine.GetScanProgress()
    return $progress
}
