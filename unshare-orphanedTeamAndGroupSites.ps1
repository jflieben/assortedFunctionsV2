<#
    .SYNOPSIS
    Detects any Team sites that still exist (e.g. due to a retention policy) but do not have owners linked to them.
    It then removes the sharing capabilities of these sites to ensure that all sharing links pointing to files/folders in these orphaned sites are disabled.

    Note: it takes a few minutes to take effect, links will stop working 5-10 minutes after running unshare-orphanedTeamSites

    Parameters: 
    specify -public to unshare public sites (sites that are unrestricted in membership)
    specify -private to unshare private sites
    specify -readOnly to just report and not actually do anything

    .NOTES
    filename:   unshare-orphanedTeamSites.ps1
    author:     Jos Lieben / jos@lieben.nu
    copyright:  Lieben Consultancy, free to (re)use, keep headers intact
    disclaimer: https://www.lieben.nu/liebensraum/contact/#disclaimer-and-copyright
    site:       https://www.lieben.nu
    Created:    04/03/2022
    Updated:    See Gitlab
#>
#Requires -Modules @{ ModuleName="PnP.PowerShell"; ModuleVersion="1.9.0"}

Param(
    [String][Parameter(Mandatory=$true)]$tenantIdentifier,
    [Switch]$readOnly,
    [Switch]$public,
    [Switch]$private
)
Connect-PnPOnline -Url "https://$($tenantIdentifier)-admin.sharepoint.com/" -Interactive
Write-Output "Connected, retrieving groups and teams with a sharepoint site..."

$orphanedSites = 0
$unsharedSites = 0

Get-PnPMicrosoft365Group -IncludeSiteUrl -IncludeOwners | Where{$_.SiteUrl -and (($_.Visibility -eq "Public" -and $public) -or ($_.Visibility -eq "Private" -and $private))} | % {
    if([Int]$_.Owners.Count -eq 0){
        Write-Output "Processing orphaned site: $($_.SiteUrl) $($_.Owners.Count)"
        $orphanedSites++
        $site = Get-PnPTenantSite -Identity $_.SiteUrl
        if($site.SharingCapability -ne "Disabled"){
            try{
                if(!$readOnly){set-pnptenantsite -Identity $site.Url -SharingCapability Disabled}
                Write-Host "Unshared $($_.SiteUrl)" -ForegroundColor Green
                $unsharedSites++
            }catch{
                Write-Host "Failed to unshare: $($_.SiteUrl)" -ForegroundColor Red
            }
        }else{
            Write-Host "$($_.SiteUrl) already unshared" -ForegroundColor Green
        }
    }
}

Write-Output "We detected $orphanedSites orphaned sites and unshared $unsharedSites of them as they still allowed external access"