#Requires -Modules ImportExcel,SharePointPnPPowerShellOnline
#Requires -Version 5
Function get-tenantStorageReport{
    <#
      .SYNOPSIS
      Create a report of total tenant storage and usage, and an overview of all sites and their quota+usage
      .DESCRIPTION
      Create a report of total tenant storage and usage, and an overview of all sites and their quota+usage
      .EXAMPLE
      get-tenantStorageReport -warningPercentRemaining 10 -tenant ogd
      .PARAMETER warningPercentRemaining
      An integer between 0 and 100, when site has less than this percentage of free space, it'll be marked in the report
      .PARAMETER tenant
      The name of your tenant, e.g. if your tenant URL is https://ogd.sharepoint.com, your tenant is ogd
      .NOTES
      filename: get-tenantStorageReport.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
      created: 28/11/2018
    #>

    Param(
        [Int]$warningPercentRemaining = 10,
        [Parameter(Mandatory=$true)][String]$tenant
    )

    $overviewReport = @()
    $tenantReports = @{}

    $tempExcelFilePath = Join-Path $Env:temp -ChildPath "detailReport.xlsx"

    #connect to tenant
    try{
        Connect-PnPOnline -UseWebLogin -Url "https://$($tenant)-admin.sharepoint.com"
        Write-Output "Connected to tenant $tenant"
    }catch{
        $overviewReport += [PSCustomObject]@{"Customer"=$tenant;"SpaceUsed"="FAILED TO CONNECT";"SpaceAvailable"="FAILED TO CONNECT";"MaximumSpace"="FAILED TO CONNECT"}
        Write-Error "Failed to connect to $tenant using PnP Online!" -ErrorAction Continue
        Throw $_
    }

    $quota = Get-PnPTenant | Select StorageQuota -ExpandProperty StorageQuota
    $sites = Get-PnPTenantSite | select StorageUsage,StorageMaximumLevel,Title,Url
    $usedSpace = 0
    Write-Output "Tenant quota: $quota"
    $tenantReports.$tenant = @()
    $hasSitesOverQuota = "NO"
    foreach($site in $sites){
        try{$percentUsed = [Math]::Round(($site.StorageUsage/$site.StorageMaximumLevel*100))}catch{$percentUsed = 100}
        if(100-$percentUsed -le $warningPercentRemaining){
            $hasSitesOverQuota = "YES"
            Write-Output "$($tenant): $($site.Title) is almost at maximum capacity! Increase allocated storage. Used space: $($site.StorageUsage) maximum space: $($site.StorageMaximumLevel)"
            $tenantReports.$tenant += [PSCustomObject]@{"Site Title"=$site.Title;"At risk"="YES";"Site usage"=$site.StorageUsage;"Percent"="$percentUsed%";"Site quota"=$site.StorageMaximumLevel;"Site URL"=$site.Url}
        }else{
            $tenantReports.$tenant += [PSCustomObject]@{"Site Title"=$site.Title;"At risk"="NO";"Site usage"=$site.StorageUsage;"Percent"="$percentUsed%";"Site quota"=$site.StorageMaximumLevel;"Site URL"=$site.Url}
        }
        $usedSpace+=$site.StorageUsage
    }

    try{$percentUsed = [Math]::Round(($usedSpace/$quota*100))}catch{$percentUsed = 100}

    $overviewReport += [PSCustomObject]@{"Customer"=$tenant;"SpaceUsed"=$usedSpace;"SpaceAvailable"=$quota-$usedSpace;"SpaceUsedPercent"="$percentUsed%";"MaximumSpace"=$quota;"HasSitesOverQuota"=$hasSitesOverQuota}
    Write-Output "Storage used: $usedSpace"
    Write-Output "Storage available: $($quota-$usedSpace)"

    $overviewReport | Export-Excel -workSheetName "Overview" -path $tempExcelFilePath -ClearSheet -TableName "Overview" -AutoSize

    $tenantReports.Keys | ForEach-Object {
        $TrimmedName = $_.Trim() -replace '\s',''
        write-output "exporting $($_)"
        if($tenantReports.$_){
            $tenantReports.$_ | Export-Excel -workSheetName $TrimmedName -path $tempExcelFilePath -ClearSheet -TableName $TrimmedName -AutoSize
        }
    }

    Write-Output "Your report was written to: $tempExcelFilePath"
}