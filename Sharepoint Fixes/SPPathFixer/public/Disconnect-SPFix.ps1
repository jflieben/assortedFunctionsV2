function Disconnect-SPFix {
    <#
    .SYNOPSIS
        Disconnects from SharePoint Online and clears cached tokens.
    .EXAMPLE
        Disconnect-SPFix
    #>
    [CmdletBinding()]
    param()

    $engine = Get-SPFixEngine
    $engine.Disconnect()
    Write-Host "Disconnected." -ForegroundColor Yellow
}
