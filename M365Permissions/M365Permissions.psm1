#requires -Modules Microsoft.PowerShell.Utility
<#
    .DESCRIPTION
    See .psd1

    .NOTES
    AUTHOR              : Jos Lieben (jos@lieben.nu)
    Copyright/License   : https://www.lieben.nu/liebensraum/commercial-use/
    CREATED             : 04/11/2024
    UPDATED             : See GitHub

    .LINK
    https://www.lieben.nu/liebensraum/m365permissions

    .ROADMAP
    1.0.8 Add support for Graph Permissions (apps/spns)
    1.0.9 Add support for App-Only authentication
    1.1.0 Add change detection/marking/sorting
    1.1.1 Staging of permissions for tenants without all resource categories
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

if ($helperFunctions.public) { Export-ModuleMember -Alias * -Function @($helperFunctions.public.BaseName) }
if ($env:username -like "*joslieben*"){Export-ModuleMember -Alias * -Function @($helperFunctions.private.BaseName) }

#variables that need to be cleared for each thread
$global:SPOPermissions = @{}
$global:EntraPermissions = @{}
$global:ExOPermissions = @{}
$global:unifiedStatistics = @{}

#first load config, subsequent loads will detect global var and skip this section (multi-threading)
if(!$global:octo){
    $global:octo = [Hashtable]::Synchronized(@{})
    $global:octo.LCClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4"
    $global:octo.PnPGroupCache = @{}
    $global:octo.LCRefreshToken = $Null
    $global:octo.LCCachedTokens = @{}
    $global:octo.includeCurrentUser = $False
    $global:octo.moduleVersion = (Get-Content -Path (Join-Path -Path $($PSScriptRoot) -ChildPath "M365Permissions.psd1") | Out-String | Invoke-Expression).ModuleVersion
    $global:octo.modulePath = $PSScriptRoot
    $global:octo.ScanJobs = @{}

    cls

    #sets default config of user-configurable settings, can be overridden by user calls to set-M365PermissionsConfig
    set-M365PermissionsConfig 
        
    $global:runspacePool = [runspacefactory]::CreateRunspacePool(1, $global:octo.maxThreads, ([system.management.automation.runspaces.initialsessionstate]::CreateDefault()), $Host)
    $global:runspacePool.ApartmentState = "STA"
    $global:runspacepool.Open() 
    
    
    write-host "----------------------------------"
    Write-Host "Welcome to M365Permissions v$($global:octo.moduleVersion)!" -ForegroundColor DarkCyan
    Write-Host "Visit https://www.lieben.nu/liebensraum/m365permissions/ for documentation" -ForegroundColor DarkCyan
    write-host "----------------------------------"
    Write-Host ""
    Write-Host "Prompting for delegated (safe/non persistent) AAD auth..."
    Write-Host ""
    $global:octo.currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    $global:octo.OnMicrosoft = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' | Where-Object -Property isInitial -EQ $true).id 
    $global:octo.tenantName = $($global:octo.OnMicrosoft).Split(".")[0]
    Write-Host "Thank you $($global:octo.currentUser.userPrincipalName), you are now authenticated and can run all functions in this module. Here are some examples:"
    Write-Host ""
    Write-Host ">> Get-AllM365Permissions -expandGroups -includeCurrentUser" -ForegroundColor Magenta
    
    Write-Host ">> Get-AllExOPermissions -includeFolderLevelPermissions" -ForegroundColor Magenta
    
    Write-Host ">> Get-ExOPermissions -recipientIdentity `$mailbox.Identity -includeFolderLevelPermissions" -ForegroundColor Magenta
    
    Write-Host ">> Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`" -ExpandGroups -OutputFormat Default" -ForegroundColor Magenta
    
    Write-Host ">> Get-SpOPermissions -teamName `"INT-Finance Department`" -OutputFormat XLSX,CSV" -ForegroundColor Magenta
    
    Write-Host ">> get-AllSPOPermissions -ExpandGroups -IncludeOneDriveSites -ExcludeOtherSites" -ForegroundColor Magenta
    
    Write-Host ">> get-AllEntraPermissions -excludeGroupsAndUsers" -ForegroundColor Magenta    

    Write-Host ">> get-AllPBIPermissions" -ForegroundColor Magenta   
}