Function get-AllM365Permissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$expandGroups
    )

    Write-Host "Starting FULL M365 Tenant scan as $($global:octo.currentUser.userPrincipalName)"
    Write-Host "Planned scan order:"
    Write-Host "1. PowerBI permissions"
    Write-Host "2. Entra permissions"
    Write-Host "3. Exchange permissions"
    Write-Host "4. Onedrive permissions"
    Write-Host "5. Teams and Sharepoint permissions"

    get-AllPBIPermissions -expandGroups:$expandGroups.IsPresent
    get-AllEntraPermissions -expandGroups:$expandGroups.IsPresent
    get-AllExOPermissions -expandGroups:$expandGroups.IsPresent -includeFolderLevelPermissions
    get-AllSpOPermissions -expandGroups:$expandGroups.IsPresent -includeOnedriveSites
}