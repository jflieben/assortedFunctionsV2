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
    1.1.x Dynamically add entra groups and users while scanning other resources
    1.1.x Staging of permissions for tenants without all resource categories and auto-setup of permissions
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

    $global:octo.moduleVersion = (Get-Content -Path (Join-Path -Path $($PSScriptRoot) -ChildPath "M365Permissions.psd1") | Out-String | Invoke-Expression).ModuleVersion
    if((Split-Path $PSScriptRoot -Leaf) -eq "M365Permissions"){
        $global:octo.modulePath = $PSScriptRoot
    }else{
        $global:octo.modulePath = (Split-Path -Path $PSScriptRoot -Parent)
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

    if($global:octo.autoConnect -eq $true){
        connect-M365
    }else{
        Write-Host "Before you can run a scan, please run connect-M365" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "If you do not want to see this message in the future, run `"set-M365PermissionsConfig -autoConnect `$True`"" -ForegroundColor White
        Write-Host ""
    }
}