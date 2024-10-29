#requires -Modules Microsoft.PowerShell.Utility
<#
    .DESCRIPTION
    Retrieves all site/web/file/folder/library/item level permissions of all types (direct, group, shared etc)

    .NOTES
    AUTHOR              : Jos Lieben (jos@lieben.nu)
    Copyright/License   : https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
    CREATED             : 06/08/2024
    UPDATED             : See GitHub

    .LINK
    https://github.com/jflieben/assortedFunctionsV2/TeamPermissions

    .EXAMPLE
    Install-PSResource -Name TeamPermissions

    .EXAMPLE
    Install-PSResource -Name TeamPermissions -Repository PSGallery

    .EXAMPLE
    Get-TeamPermissions -TeamSiteUrl "https://tenant.sharepoint.com/sites/site" -ExpandGroups -OutputFormat Default
    Get-TeamPermissions -teamName "INT-Finance Department" -ExpandGroups -OutputFormat XLSX,HTML
    Get-AllPermissions -ExpandGroups -OutputFormat XLSX -ignoreCurrentUser

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

$global:LCClientId = "3dd53891-462c-4f80-8dbd-df21b4a19786"
$global:performanceDebug = $False

if ($helperFunctions.public) { Export-ModuleMember -Alias * -Function @($helperFunctions.public.BaseName) }