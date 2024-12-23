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
    1.1.2 Add support for App-Only authentication (cert based)
    1.1.2 Add license check for running user where applicable (e.g. powerbi)
    1.1.3 Staging of permissions for tenants without all resource categories
    1.1.x check defender xdr options 
    1.1.x Assess if Azure RM should be added or if a good open source tool already exists
    1.1.x Assess SQL or PBI as data destinations                                                                                                                                                                                                                                            
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
$global:unifiedStatistics = @{}

#first load config, subsequent loads will detect global var and skip this section (multi-threading)
if(!$global:octo){
    $global:octo = [Hashtable]::Synchronized(@{})
    $global:octo.ScanJobs = @{}
    $global:octo.PnPGroupCache = @{}
    $global:octo.LCRefreshToken = $Null
    $global:octo.LCCachedTokens = @{}
    $global:octo.reportWriteQueue = @()

    $global:octo.moduleVersion = (Get-Content -Path (Join-Path -Path $($PSScriptRoot) -ChildPath "M365Permissions.psd1") | Out-String | Invoke-Expression).ModuleVersion
    if((Split-Path $PSScriptRoot -Leaf) -eq "M365Permissions"){
        $global:octo.modulePath = $PSScriptRoot
    }else{
        $global:octo.modulePath = (Split-Path -Path $PSScriptRoot -Parent)
    }

    #check if we are running in a headless environment, if so, do not use delegated auth and use env variables for auth
    #EXPERIMENTAL, DOES NOT WORK FOR SPO UNTIL CBA IS IMPLEMENTED
    if($Env:LCAUTHMODE -and $Env:LCAUTHMODE -ne "Delegated"){
        $global:octo.authMode = $Env:LCAUTHMODE
        $global:octo.LCClientId = $Env:LCCLIENTID
        $global:octo.LCClientSecret = $Env:LCCLIENTSECRET
        $global:octo.LCTenantId = $Env:LCTENANTID
    }else{
        $global:octo.authMode = "Delegated"
        $global:octo.LCClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4"
    }

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
    if($global:octo.authMode -eq "Delegated"){
        Write-Host "Prompting for delegated (safe/non persistent) AAD auth..."
    }else{
        Write-Host "Using $($global:octo.authMode) authentication..."
    }
    Write-Host ""
    $global:octo.currentUser = Get-CurrentUser
    $global:octo.OnMicrosoft = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' | Where-Object -Property isInitial -EQ $true).id 
    $global:octo.tenantName = $($global:octo.OnMicrosoft).Split(".")[0]
    Write-Host "Thank you $($global:octo.currentUser.userPrincipalName), you are now authenticated and can run all functions in this module. Here are some examples:"
    Write-Host ""
    Write-Host ">> Get-AllM365Permissions -expandGroups" -ForegroundColor Magenta
    
    Write-Host ">> Get-AllExOPermissions -includeFolderLevelPermissions" -ForegroundColor Magenta
    
    Write-Host ">> Get-ExOPermissions -recipientIdentity `$mailbox.Identity -includeFolderLevelPermissions" -ForegroundColor Magenta
    
    Write-Host ">> Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`" -ExpandGroups" -ForegroundColor Magenta
    
    Write-Host ">> Get-SpOPermissions -teamName `"INT-Finance Department`"" -ForegroundColor Magenta
    
    Write-Host ">> get-AllSPOPermissions -ExpandGroups -IncludeOneDriveSites -ExcludeOtherSites" -ForegroundColor Magenta
    
    Write-Host ">> get-AllEntraPermissions -excludeGroupsAndUsers" -ForegroundColor Magenta    

    Write-Host ">> get-AllPBIPermissions" -ForegroundColor Magenta 
    
    Write-Host ">> Get-ChangedPermissions" -ForegroundColor Magenta 
}