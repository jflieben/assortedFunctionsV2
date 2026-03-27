function Start-SPFixGUI {
    <#
    .SYNOPSIS
        Starts the web-based GUI for SPPathFixer.
    .PARAMETER Port
        TCP port to listen on. Uses configured GuiPort if not specified.
    .EXAMPLE
        Start-SPFixGUI
    .EXAMPLE
        Start-SPFixGUI -Port 9090
    #>
    [CmdletBinding()]
    param(
        [int]$Port
    )

    $engine = Get-SPFixEngine
    if (-not $Port) {
        $Port = ($engine.GetConfig()).GuiPort
    }

    $engine.StartServer($Port, $script:GuiRoot, $true)
    Write-Host "SPPathFixer GUI started at http://localhost:$Port" -ForegroundColor Cyan
}
