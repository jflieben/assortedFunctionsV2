Function get-AllSPOPermissions{   
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

    $global:tenantName = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' -NoPagination | Where-Object -Property isInitial -EQ $true).id.Split(".")[0]
    $currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    $spoBaseAdmUrl = "https://$($tenantName)-admin.sharepoint.com"
    Write-Host "Scanning all sites as $($currentUser.userPrincipalName)"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    $sites = @(Get-PnPTenantSite -IncludeOneDriveSites:$includeOnedriveSites.IsPresent -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) | Where-Object {`
        $_.Template -NotIn $ignoredSiteTypes
    })

    if($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find any sites/teams. Please check your permissions and try again"
    }

    $counter = 1
    foreach($site in $sites){
        Write-Progress -Id 1 -PercentComplete ($Counter / ($sites.Count) * 100) -Activity "Exporting Permissions from Site '$($site.Title)'" -Status "Processing site $counter / $($sites.Count)"
                    
        get-SpOPermissions -siteUrl $site.Url -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent -ignoreCurrentUser:$ignoreCurrentUser.IsPresent
        $counter++
    }
}