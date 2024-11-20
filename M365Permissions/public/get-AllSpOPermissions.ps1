Function get-AllSPOPermissions{   
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>         
    Param(
        [Switch]$includeOnedriveSites,
        [Switch]$excludeOtherSites,
        [Switch]$expandGroups,
        [Switch]$includeCurrentUser,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    if(!$includeOnedriveSites -and $excludeOtherSites){
        Write-Warning "You cannot use -excludeOtherSites without -includeOnedriveSites, assuming -includeOnedriveSites"
        [Switch]$includeOnedriveSites = $True
    }

    $global:tenantName = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' -NoPagination | Where-Object -Property isInitial -EQ $true).id.Split(".")[0]
    $spoBaseAdmUrl = "https://$($tenantName)-admin.sharepoint.com"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    $sites = @(Get-PnPTenantSite -IncludeOneDriveSites:$includeOnedriveSites.IsPresent -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) | Where-Object {`
        $_.Template -NotIn $ignoredSiteTypes
    })

    if($excludeOtherSites.IsPresent){
        Write-Host "Only scanning Onedrive for Business sites"
        $sites = $sites | Where-Object {$_ -and $_.Url -notlike "https://$tenantName.sharepoint.com/*"}
    }

    if($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find any sites/teams. Please check your permissions and try again"
    }

    $counter = 1
    foreach($site in $sites){
        Write-Progress -Id 1 -PercentComplete (($Counter / $sites.Count) * 100) -Activity "Exporting Permissions from Site '$($site.Title)'" -Status "Processing site $counter / $($sites.Count)"
                    
        get-SpOPermissions -siteUrl $site.Url -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -includeCurrentUser:$includeCurrentUser.IsPresent
        $counter++
    }
}