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
    [Parameter(Mandatory=$true)][String]$displayName="we-naima-aa",
    [Parameter(Mandatory=$true)][String]$role="GroupMember.ReadWrite.All"
)
Connect-AzureAD 
$Msi = (Get-AzureADServicePrincipal -Filter "displayName eq '$displayName'")
Start-Sleep -Seconds 10
$baseSPN = Get-AzureADServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$AppRole = $baseSPN.AppRoles | Where-Object {$_.Value -eq $role -and $_.AllowedMemberTypes -contains "Application"}
New-AzureAdServiceAppRoleAssignment -ObjectId $Msi.ObjectId -PrincipalId $Msi.ObjectId -ResourceId $baseSPN.ObjectId -Id $AppRole.Id