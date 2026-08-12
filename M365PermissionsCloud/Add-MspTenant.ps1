#Requires -Version 7.0
<#
.SYNOPSIS
    Superseded. Cross tenant onboarding is now a mode of authorize.ps1.

.DESCRIPTION
    This script used to carry its own copy of the permission list, which meant it drifted away from
    the other two onboarding paths and never gained the surfaces beyond Entra. Everything it did now
    runs through the shared permission definition instead, so this file just forwards.

    Run this instead, in Azure Cloud Shell, signed in to the customer tenant:

        & ([scriptblock]::Create((irm https://m365permissions.com/authorize.ps1))) -MspOnboarding

    Every surface is authorized by default. Pass -Surfaces to narrow that down, for example:

        & ([scriptblock]::Create((irm https://m365permissions.com/authorize.ps1))) -MspOnboarding -Surfaces Exchange,PowerBI

.NOTES
    Docs: https://m365permissions.com/docs/msp-cross-tenant
#>
[CmdletBinding()]
Param(
    [ValidateSet("All", "Exchange", "PowerBI", "PowerPlatform", "AzureDevOps", "Azure")]
    [String[]]$Surfaces = @("All"),
    [String]$CertificatePath
)

Write-Host "Add-MspTenant.ps1 has been folded into authorize.ps1 and is now just a forwarder." -ForegroundColor DarkYellow
Write-Host "Running: authorize.ps1 -MspOnboarding -Surfaces $($Surfaces -join ',')" -ForegroundColor DarkGray
Write-Host ""

$parameters = @{ MspOnboarding = $true; Surfaces = $Surfaces }
if ($CertificatePath) { $parameters.CertificatePath = $CertificatePath }

& ([scriptblock]::Create((Invoke-RestMethod -Uri "https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/authorize.ps1"))) @parameters
