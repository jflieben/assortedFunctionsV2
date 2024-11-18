Function get-AllM365Permissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$expandGroups,
        [Switch]$ignoreCurrentUser,
        [parameter(Mandatory=$true)]
        [ValidateSet('XLSX','CSV')]
        [String[]]$outputFormat
    )

    $currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    Write-Host "Starting FULL M365 Tenant scan as $($currentUser.userPrincipalName)"
    Write-Host "Planned scan order:"
    Write-Host "1. Entra permissions"
    Write-Host "2. Exchange permissions"
    Write-Host "3. Onedrive permissions"
    Write-Host "4. Teams and Sharepoint permissions"

    get-EntraPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -ignoreCurrentUser:$ignoreCurrentUser.IsPresent
    get-ExOPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -ignoreCurrentUser:$ignoreCurrentUser.IsPresent -includeFolderLevelPermissions
    get-AllSpOPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -ignoreCurrentUser:$ignoreCurrentUser.IsPresent -includeOnedriveSites
}