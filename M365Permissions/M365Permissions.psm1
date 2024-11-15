#requires -Modules Microsoft.PowerShell.Utility
<#
    .DESCRIPTION
    See .psd1

    .NOTES
    AUTHOR              : Jos Lieben (jos@lieben.nu)
    Copyright/License   : https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
    CREATED             : 04/11/2024
    UPDATED             : See GitHub

    .LINK
    https://www.lieben.nu/liebensraum/m365permissions

    .ROADMAP
    1.0.4 Add mailbox folder level permissions
    1.0.x Add support for PowerBI
    1.0.x Add support for App-Only authentication
#>

$helperFunctions = @{
    private = @( Get-ChildItem -Path "$($PSScriptRoot)\private" -Filter '*.ps*1' -ErrorAction SilentlyContinue )
    public  = @( Get-ChildItem -Path "$($PSScriptRoot)\public" -Filter '*.ps*1' -ErrorAction SilentlyContinue )
}
ForEach ($helperFunction in (($helperFunctions.private + $helperFunctions.public) | Where-Object { $null -ne $_ })) {
    try {
        Switch -Regex ($helperFunction.Extension) {
            '\.ps(m|d)1' { $null = Import-Module -Name "$($helperFunction.FullName)" -Scope Global -Force }
            '\.ps1' { (. "$($helperFunction.FullName)") }
            default { Write-Warning -Message "[$($helperFunction.Name)] Unable to import module function" }
        }
    }
    catch {
        Write-Error -Message "[$($helperFunction.Name)] Unable to import function: $($error[1].Exception.Message)"
    }
}

$global:LCClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4"
$global:pnpUrlAuthCaches = @{}
$global:SPOPermissions = @{}
$global:PnPGroupCache = @{}
$global:EntraPermissions = @{}
$global:LCRefreshToken = $Null
$global:LCCachedTokens = @{}
$global:performanceDebug = $False
$global:OnMicrosoft = $Null
$global:moduleVersion = (Get-Content -Path (Join-Path -Path $($PSScriptRoot) -ChildPath "M365Permissions.psd1") | Out-String | Invoke-Expression).ModuleVersion

if ($helperFunctions.public) { Export-ModuleMember -Alias * -Function @($helperFunctions.public.BaseName) }
if ($env:username -like "*joslieben*"){Export-ModuleMember -Alias * -Function @($helperFunctions.private.BaseName) }

cls
write-host "----------------------------------"
Write-Host "Welcome to M365Permissions v$($global:moduleVersion)!" -ForegroundColor DarkCyan
Write-Host "Visit https://www.lieben.nu/liebensraum/m365permissions/ for documentation" -ForegroundColor DarkCyan
write-host "----------------------------------"
Write-Host ""
Write-Host "Prompting for delegated (safe/non persistent) AAD auth..."
Write-Host ""
$global:currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
Write-Host "Thank you $($currentUser.userPrincipalName), you are now authenticated and can run all functions in this module. Here are some examples:"
Write-Host ""
Write-Host ">> Get-AllM365Permissions -OutputFormat XLSX -expandGroups -ignoreCurrentUser" -ForegroundColor Magenta

Write-Host ">> Get-ExOPermissions -OutputFormat XLSX" -ForegroundColor Magenta

Write-Host ">> Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`" -ExpandGroups -OutputFormat Default" -ForegroundColor Magenta

Write-Host ">> Get-SpOPermissions -teamName `"INT-Finance Department`" -OutputFormat XLSX,CSV" -ForegroundColor Magenta

Write-Host ">> get-AllSPOPermissions -ExpandGroups -OutputFormat XLSX -ignoreCurrentUser -IncludeOneDriveSites" -ForegroundColor Magenta

Write-Host ">> Get-EntraPermissions -OutputFormat XLSX -expandGroups" -ForegroundColor Magenta
