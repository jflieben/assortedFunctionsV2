#Author:    Jos Lieben
#Company:   Lieben Consultancy
#Copyright: Lieben Consultancy, free to use
#Contact:   https://www.lieben.nu

$tenantName = "lieben"
$testSite = $Null
$testSite = "https://lieben.sharepoint.com/sites/TEST" #comment this line out to run for all sites
$requiredOwners = @("jos@lieben.nu")
$excludedSites = @(
    "https://lieben.sharepoint.com/sites/TEST"
)

#connect to the API as Managed Identity
Write-Output "Connecting to API..."
$spoConnection = Connect-PnPOnline -Url "https://$($tenantName)-admin.sharepoint.com" -ReturnConnection -ManagedIdentity 
Write-Output "Connected to API"

#Get All Site collections excluding the Seach Center, Redirect site, Mysite Host, App Catalog, Content Type Hub, eDiscovery and Bot Sites
Write-Output "Getting all site collections..."
$tenantSites = Get-PnPTenantSite -Connection $spoConnection | Where-Object -Property Template -NotIn ("SRCHCEN#0", "REDIRECTSITE#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1")
Write-Output "Got $($tenantSites.Count) site collections"

#loop over all sites
ForEach($tenantSite in $tenantSites){
    Write-Output "Processing $($tenantSite.URL)"
    if($testSite){
        if($tenantSite.Url -ne $testSite){
            Write-Output "Skipping because `$testsite is configured and this is not the testsite."
            Continue
        }
    }
    
    if($excludedSites -contains $tenantSite.Url){
        Write-Output "Skipping because this site is in the excluded list."
        Continue
    }

    $siteConn = Connect-PnPOnline -Url $tenantSite.Url -ReturnConnection -ManagedIdentity
    $curOwners = $Null; $curOwners = Get-PnPSiteCollectionAdmin -Connection $siteConn
    Foreach($requiredOwner in $requiredOwners){
        if($curOwners.Email -notcontains $requiredOwner){
            try{
                Write-Output "Adding $requiredOwner to $($tenantSite.Url)"
                Add-PnPSiteCollectionAdmin -Owners $requiredOwner -Connection $siteConn
                Write-Output "Added $requiredOwner to $($tenantSite.Url) :)"
            }catch{
                Write-Output "Failed to add $requiredOwner to $($tenantSite.Url) :("
                Write-Error $_ -ErrorAction Continue
            }
        }else{
            Write-Output "$requiredOwner already an owner of $($tenantSite.Url)"
        }
    }
}