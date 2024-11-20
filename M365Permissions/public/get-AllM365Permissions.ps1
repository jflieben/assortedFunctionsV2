Function get-AllM365Permissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$expandGroups,
        [Switch]$includeCurrentUser,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    Write-Host "Starting FULL M365 Tenant scan as $($global:currentUser.userPrincipalName)"
    Write-Host "Planned scan order:"
    Write-Host "1. Entra permissions"
    Write-Host "2. Exchange permissions"
    Write-Host "3. Onedrive permissions"
    Write-Host "4. Teams and Sharepoint permissions"

    get-EntraPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -includeCurrentUser:$includeCurrentUser.IsPresent
    get-AllExOPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -includeCurrentUser:$includeCurrentUser.IsPresent -includeFolderLevelPermissions
    get-AllSpOPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -includeCurrentUser:$includeCurrentUser.IsPresent -includeOnedriveSites
}