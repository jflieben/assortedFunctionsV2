<#
    .SYNOPSIS
    Adds a configurable role to a given Managed Identity (not currently possible through the Azure Portal)

    .NOTES
    filename: add-roleToManagedIdentity
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
    Updated: 27/08/2021
#>
Param(
    [Parameter(Mandatory=$true)][String]$displayName="LC-Runbooks",
    [Parameter(Mandatory=$true)][String]$role="Exchange.ManageAsApp"
)

Connect-MgGraph -Scopes AppRoleAssignment.ReadWrite.All,Application.Read.All
$MI = Get-MgServicePrincipal -Filter "DisplayName eq '$displayName'"
$baseSPN = (Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'") #use 00000002-0000-0ff1-ce00-000000000000 for Exchange Online
foreach($appRole in $baseSPN.AppRoles){
    if($appRole.Value -eq $role){
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MI.Id -PrincipalId $MI.Id -AppRoleId $appRole.Id -ResourceId $baseSPN.Id
    }
}