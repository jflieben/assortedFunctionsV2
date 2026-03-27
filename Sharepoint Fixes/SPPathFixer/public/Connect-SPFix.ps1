function Connect-SPFix {
    <#
    .SYNOPSIS
        Connects to SharePoint Online for path scanning and fixing.
    .DESCRIPTION
        Supports two authentication modes:
        - Delegated: Browser-based PKCE flow (default). No client secret needed.
        - Certificate: App-only auth using a PFX file or certificate thumbprint.
    .PARAMETER Mode
        Authentication mode: 'delegated' or 'certificate'.
    .PARAMETER ClientId
        Azure AD app registration client ID. Uses built-in app for delegated mode if not specified.
    .PARAMETER TenantId
        Azure AD tenant ID. Required for certificate mode.
    .PARAMETER PfxPath
        Path to PFX certificate file. For certificate mode.
    .PARAMETER PfxPassword
        Password for the PFX file.
    .PARAMETER Thumbprint
        Certificate thumbprint to find in the local certificate store. Alternative to PfxPath.
    .EXAMPLE
        Connect-SPFix
    .EXAMPLE
        Connect-SPFix -Mode certificate -ClientId "abc-123" -TenantId "xyz-789" -PfxPath ".\cert.pfx" -PfxPassword "secret"
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('delegated','certificate')]
        [string]$Mode = 'delegated',
        [string]$ClientId,
        [string]$TenantId,
        [string]$PfxPath,
        [string]$PfxPassword,
        [string]$Thumbprint
    )

    $engine = Get-SPFixEngine
    $task = $engine.ConnectAsync($Mode, $ClientId, $TenantId, $PfxPath, $PfxPassword, $Thumbprint)
    $task.GetAwaiter().GetResult()
    $status = $engine.GetStatus()

    if ($Mode -eq 'delegated') {
        Write-Host "Connected to $($status.TenantDomain) as $($status.UserPrincipalName)" -ForegroundColor Green
    } else {
        Write-Host "Connected to $($status.TenantDomain) via certificate (app-only)" -ForegroundColor Green
    }
}
