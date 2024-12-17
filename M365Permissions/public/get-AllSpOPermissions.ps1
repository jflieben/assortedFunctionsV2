Function get-AllSPOPermissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$includeOnedriveSites,
        [Switch]$excludeOtherSites,
        [Switch]$expandGroups
    )

    if(!$includeOnedriveSites -and $excludeOtherSites){
        Write-Warning "You cannot use -excludeOtherSites without -includeOnedriveSites, assuming -includeOnedriveSites"
        [Switch]$includeOnedriveSites = $True
    }

    $spoBaseAdmUrl = "https://$($global:octo.tenantName)-admin.sharepoint.com"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    $sites = @(Get-PnPTenantSite -IncludeOneDriveSites:$includeOnedriveSites.IsPresent -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) | Where-Object {`
        $_.Template -NotIn $ignoredSiteTypes
    })

    if($excludeOtherSites.IsPresent){
        Write-Host "Only scanning Onedrive for Business sites"
        $sites = $sites | Where-Object {$_ -and $_.Url -notlike "https://$($global:octo.tenantName).sharepoint.com/*"}
    }

    if($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find any sites/teams. Please check your permissions and try again"
    }

    foreach($site in $sites){
        New-ScanJob -Title "Scanning Sharepoint Online" -Target $site.Url -FunctionToRun "get-SpOPermissions" -FunctionArguments @{
            "siteUrl" = $site.Url
            "expandGroups" = $expandGroups.IsPresent
            "isParallel" = $True
        }
    }

    Start-ScanJobs -Title "Scanning Sharepoint Online"
}