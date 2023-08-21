<#
    .SYNOPSIS
    Detects any Onedrive for Business sites that still exist (e.g. due to a retention policy) but do not have a user linked to them (users that have been deleted/offboarded).
    It then removes the sharing capabilities of these sites to ensure that all sharing links pointing to files/folders in these orphaned sites are disabled.

    Note: it takes a few minutes to take effect, links will stop working 5-10 minutes after running unshare-orphanedOnedriveForBusinessSites

    .NOTES
    filename:   unshare-orphanedOnedriveForBusinessSites.ps1
    author:     Jos Lieben / jos@lieben.nu
    copyright:  Lieben Consultancy, free to (re)use, keep headers intact
    disclaimer: https://www.lieben.nu/liebensraum/contact/#disclaimer-and-copyright
    site:       https://www.lieben.nu
    Created:    28/02/2022
    Updated:    See Gitlab
#>
#Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="1.9.0"}

Param(
    [String][Parameter(Mandatory=$true)]$tenantIdentifier,
    [Switch]$readOnly
)
Connect-PnPOnline -Url "https://$($tenantIdentifier)-admin.sharepoint.com/" -Interactive
Write-Output "Connected, retrieving O4B site list..."
$odSites = Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '-my.sharepoint.com/personal/'"
Write-Output "$($odSites.Count) Onedrive for Business Sites detected, caching users in AAD"
$aadUserCache = Get-PnPAzureAdUser -EndIndex $null
Write-Output "$($aadUserCache.Count) users detected, checking which sites do not have an existing user..."

if($aadUserCache.Count -le 0 -or $odSites.Count -le 0){
    Throw "Zero users or onedrive sites found, cannot continue"
}

$orphanedSites = 0
$unsharedSites = 0
foreach($odSite in $odSites){
    if($aadUserCache.UserPrincipalName -notcontains $odSite.Owner){
        $orphanedSites++
        if($odSite.SharingCapability -ne "Disabled"){
            $unsharedSites++
            Write-Output "$($odSite.Url) has been orphaned, disabling sharing on this site"
            if(!$readOnly){set-pnptenantsite -Identity $odSite.Url -SharingCapability Disabled}
        }

    }
}
Write-Output "We detected $orphanedSites orphaned Onedrive for business sites and unshared $unsharedSites of them as they still allowed external access"
