function Stop-SPFixGUI {
    <#
    .SYNOPSIS
        Stops the web-based GUI server.
    .EXAMPLE
        Stop-SPFixGUI
    #>
    [CmdletBinding()]
    param()

    $engine = Get-SPFixEngine
    $null = $engine.StopServerAsync().GetAwaiter().GetResult()
    Write-Host "GUI stopped." -ForegroundColor Yellow
}
