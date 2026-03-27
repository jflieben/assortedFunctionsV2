function Get-SPFixResults {
    <#
    .SYNOPSIS
        Gets scan results for a specific scan.
    .PARAMETER ScanId
        The scan ID to retrieve results for.
    .PARAMETER Page
        Page number (default: 1).
    .PARAMETER PageSize
        Results per page (default: 50).
    .EXAMPLE
        Get-SPFixResults -ScanId 1
    .EXAMPLE
        Get-SPFixResults -ScanId 1 -Page 2 -PageSize 100
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$ScanId,
        [int]$Page = 1,
        [int]$PageSize = 50
    )

    $engine = Get-SPFixEngine
    return $engine.GetResults($ScanId, $Page, $PageSize, $null, $null, $null, $null, $null, $null, $null)
}
