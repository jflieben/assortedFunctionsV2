Function get-AllM365Permissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$includeOnedriveSites,
        [Switch]$expandGroups,
        [Switch]$ignoreCurrentUser,
        [parameter(Mandatory=$true)]
        [ValidateSet('XLSX','CSV')]
        [String[]]$outputFormat
    )

    $currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    Write-Host "Starting FULL M365 Tenant scan as $($currentUser.userPrincipalName)"
    Write-Host "Planned scan order:"
    $i = 1
    Write-Host "$i. Entra permissions"
    $i++
    if($includeOnedriveSites.IsPresent){
        Write-Host "$i. Onedrive permissions"
        $i++
    }
    Write-Host "$i. Teams and Sharepoint permissions"

    get-EntraPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent
    get-AllSpOPermissions -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -ignoreCurrentUser:$ignoreCurrentUser.IsPresent -includeOnedriveSites:$includeOnedriveSites.IsPresent
}