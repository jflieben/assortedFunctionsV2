<#
.SYNOPSIS
    Gets a Microsoft Graph API token silently using MSAL with WAM broker support.

.DESCRIPTION
    Uses MSAL.PS module with Windows broker (WAM) integration to obtain an access token 
    for Microsoft Graph API using delegated authentication. Leverages the Primary Refresh 
    Token (PRT) on Entra ID joined devices for silent authentication.
    
    Automatically installs MSAL.PS module in user scope if not present.

.PARAMETER ClientId
    The Application (client) ID of the registered app in Entra ID.

.PARAMETER Scopes
    The scopes to request. Default is "https://graph.microsoft.com/.default"

.PARAMETER TenantId
    Optional. The tenant ID. If not specified, uses "organizations" for multi-tenant.

.PARAMETER Interactive
    If specified, forces interactive authentication (useful for first-time consent).

.EXAMPLE
    $token = .\Get-GraphTokenSilent.ps1 -ClientId "your-client-id-here"
    $token.AccessToken

.EXAMPLE
    # First time - use interactive to establish consent
    $token = .\Get-GraphTokenSilent.ps1 -ClientId "your-client-id-here" -Interactive

.NOTES
    ENTRA ID APP REGISTRATION REQUIREMENTS:
    ----------------------------------------
    1. Register an application in Entra ID (Azure Portal > App registrations)
    2. Under "Authentication":
       - Add platform: "Mobile and desktop applications"
       - Check the redirect URI: "https://login.microsoftonline.com/common/oauth2/nativeclient"
       - Also add: "ms-appx-web://microsoft.aad.brokerplugin/{ClientId}"
       - Enable "Allow public client flows" = Yes
    3. Under "API permissions":
       - Add the required Microsoft Graph delegated permissions
       - Grant admin consent for the tenant (recommended for silent auth)
    4. Note the Application (client) ID for use with this script
    
    DEVICE REQUIREMENTS:
    --------------------
    - Windows 10/11
    - Device must be Entra ID joined (or Hybrid Azure AD joined)
    - User must be signed in with their Entra ID account
    - PowerShell 5.1 or later
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string[]]$Scopes = @("https://graph.microsoft.com/.default"),

    [Parameter(Mandatory = $false)]
    [string]$TenantId = "organizations",
    
    [Parameter(Mandatory = $false)]
    [switch]$Interactive
)

# Ensure MSAL.PS module is available
function Ensure-MSALModule {
    if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
        Write-Host "MSAL.PS module not found. Installing in user scope..." -ForegroundColor Yellow
        try {
            # Install NuGet provider if needed
            if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
            }
            
            # Install MSAL.PS
            Install-Module -Name MSAL.PS -Scope CurrentUser -Force -AllowClobber
            Write-Host "MSAL.PS module installed successfully." -ForegroundColor Green
        }
        catch {
            throw "Failed to install MSAL.PS module: $_"
        }
    }
    
    Import-Module MSAL.PS -Force
}

try {
    # Ensure MSAL is available
    Ensure-MSALModule
    
    Write-Verbose "Attempting to acquire token for client: $ClientId"
    Write-Verbose "Scopes: $($Scopes -join ', ')"
    Write-Verbose "Tenant: $TenantId"
    
    # Common MSAL parameters
    $msalParams = @{
        ClientId    = $ClientId
        TenantId    = $TenantId
        Scopes      = $Scopes
        # Use WAM broker for silent auth with PRT
        # DeviceCode fallback if broker fails
    }
    
    $token = $null
    
    if ($Interactive) {
        # Force interactive - useful for first-time consent
        Write-Verbose "Interactive mode requested..."
        $token = Get-MsalToken @msalParams -Interactive
    }
    else {
        # Try silent first
        try {
            Write-Verbose "Attempting silent token acquisition..."
            $token = Get-MsalToken @msalParams -Silent -ForceRefresh
        }
        catch {
            Write-Verbose "Silent auth failed: $_"
            
            # Try with integrated windows auth (uses PRT/Kerberos)
            try {
                Write-Verbose "Attempting Integrated Windows Authentication..."
                $token = Get-MsalToken @msalParams -IntegratedWindowsAuth
            }
            catch {
                Write-Verbose "IWA failed: $_"
                
                # Fall back to device code flow (works in console without UI)
                Write-Warning "Silent authentication failed. Falling back to device code flow..."
                $token = Get-MsalToken @msalParams -DeviceCode
            }
        }
    }
    
    if ($token) {
        $result = [PSCustomObject]@{
            AccessToken  = $token.AccessToken
            ExpiresOn    = $token.ExpiresOn
            Account      = $token.Account.Username
            TenantId     = $token.TenantId
            Scopes       = $token.Scopes
            TokenType    = "Bearer"
        }
        
        Write-Verbose "Token obtained successfully for account: $($result.Account)"
        return $result
    }
    else {
        throw "Failed to obtain token - no token returned"
    }
}
catch {
    Write-Error "Failed to obtain token: $_"
    throw
}
