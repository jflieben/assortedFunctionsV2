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

$global:performanceDebug = $False

if ($helperFunctions.public) { Export-ModuleMember -Alias * -Function @($helperFunctions.public.BaseName) }
if ($env:username -like "*joslieben*"){Export-ModuleMember -Alias * -Function @($helperFunctions.private.BaseName) }