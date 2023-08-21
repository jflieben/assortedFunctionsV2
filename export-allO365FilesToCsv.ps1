<#
    .SYNOPSIS
    Exports all files and folders in any sharepoint, onedrive for business or teams site in Office 365
    .DESCRIPTION
    Exports all files and folders in any sharepoint, onedrive for business or teams site in Office 365 to a comma seperated CSV file for further analysis as per your requirements. Can also export only for specific given sites

    .EXAMPLE
    .\export-allO365FilesToCSV.ps1 -tenantName lieben -csvPath "c:\temp\result.csv"

    .PARAMETER csvPath
    Required full path to where you want the script to write a CSV file to. Also used to read data from if it already exists

    .PARAMETER tenantName
    Name of your Office 365 tenant (https://TENANTA.sharepoint.com) = TENANTA
    Example: tenanta

    .PARAMETER useMFA
    Switch parameter, if the admin account you plan to use is MFA enabled, supply -useMFA to this script

    .PARAMETER specificSiteUrls
    Comma seperated list of sites to process. If not specified ALL sites are processed (including Onedrive for Business and Microsoft Teams)

    .NOTES
    filename: export-allO365FilesToCSV.ps1
    author: Jos Lieben
    site: www.lieben.nu
    created: 19/09/2019
#>

Param(
    [Parameter(Mandatory=$true)][String]$tenantName,
    [Parameter(Mandatory=$true)]$csvPath,
    [String]$specificSiteUrls=$Null,
    [Switch]$useMFA
)

$adminUrl = "https://$tenantName-admin.sharepoint.com"

$baseUrl = "https://$tenantName.sharepoint.com"

if($specificSiteUrls.Length -gt 0){
    [Array]$specificSiteUrls = $specificSiteUrls.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)
}else{
    [Array]$specificSiteUrls = @()
}

function Load-Module{
    Param(
        $Name
    )
    Write-Output "Checking for $Name Module"
    $module = Get-Module -Name $Name -ListAvailable
    if ($module -eq $null) {
        write-Output "$Name Powershell module not installed...trying to Install, this will fail in an unelevated session"
        #Check if elevated
        If (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")){   
            Write-Output "Please restart this script in elevated mode!"
            Read-Host "Press any key to continue"
            Exit
        }
        try{
            Install-Module $Name -SkipPublisherCheck -Force -Confirm:$False
            Write-Output "$Name module installed!"
        }catch{
            write-Error "Install by running 'Install-Module $Name' from an elevated PowerShell prompt"
            Throw
        }
    }else{
        write-output "Module already installed"
    }
    try{
        Write-Output "loading module"
        Import-Module $Name -DisableNameChecking -Force -NoClobber
        Write-Output "module loaded"
    }catch{
        Write-Output "failed to load module"
    }
}

try{
    Load-Module SharePointPnPPowerShellOnline
    if(!$useMFA -and !$script:Credential){
        $script:Credential = Get-Credential
    }
    if($useMFA){
        Connect-PnPOnline $adminUrl -UseWebLogin
    }else{
        Connect-PnPOnline $adminUrl -Credentials $Credential
    }
}catch{
    Throw "Could not connect to SpO online, check your credentials"
}

if($specificSiteUrls.Count -gt 0){
    Write-Output "Running for specific Sharepoint, Onedrive or Team sites: "
    Write-Output $specificSiteUrls
}else{
    Write-Output "Running for all Sharepoint, Onedrive and Team sites"
}

$allSites = @()
$sites = @()
#intial discovery phase
Get-PnPListItem -List DO_NOT_DELETE_SPLIST_TENANTADMIN_AGGREGATED_SITECOLLECTIONS -Fields ID,Title,TemplateTitle,SiteUrl,IsGroupConnected | % {
    if($_.FieldValues.SiteUrl.StartsWith("https")){
        $allSites+=[PSCustomObject]@{"SiteUrl"=$_.FieldValues.SiteUrl;"Title"=$_.FieldValues.Title;}
        if(($specificSiteUrls.Count -gt 0 -and $specificSiteUrls -Contains $_.FieldValues.SiteUrl) -or $specificSiteUrls.Count -eq 0){
            $sites+=[PSCustomObject]@{"SiteUrl"=$_.FieldValues.SiteUrl;"Title"=$_.FieldValues.Title;}    
        }
    }
}

#secondary discovery phase
foreach($extraSite in (Get-PnPTenantSite -IncludeOneDriveSites | select StorageUsage,Title,Url)){
    if($extraSite.Url.StartsWith("https")){
        if($allSites.SiteUrl -notcontains $extraSite.Url){
            $allSites+=[PSCustomObject]@{"SiteUrl"=$extraSite.Url;"Title"=$extraSite.Title;}
        }
        if(($specificSiteUrls.Count -gt 0 -and $specificSiteUrls -Contains $extraSite.Url) -or $specificSiteUrls.Count -eq 0){
            if($sites.SiteUrl -notcontains $extraSite.Url){
                $sites+=[PSCustomObject]@{"SiteUrl"=$extraSite.Url;"Title"=$extraSite.Title;} 
            }
        }
    }
}

#add subsites of any of the discovered sites
for($siteCount = 0;$siteCount -lt $allSites.Count;$siteCount++){
    write-output "Discovering subsites of: $($allSites[$siteCount].SiteUrl)"
    try{
        if($useMFA){
            Connect-PnPOnline $allSites[$siteCount].SiteUrl -UseWebLogin
        }else{
            Connect-PnPOnline $allSites[$siteCount].SiteUrl -Credentials $script:Credential
        }
        Get-PnPSubWebs -Recurse | % {
        
            if(($specificSiteUrls.Count -gt 0 -and $specificSiteUrls -Contains $_.Url) -or $specificSiteUrls.Count -eq 0){
                if($sites.SiteUrl -notcontains $_.Url){
                    $sites+=[PSCustomObject]@{"SiteUrl"=$_.Url;"Title"=$_.Title;} 
                }
            }        
        }
    }catch{$Null}
}

$sites = @($sites | where {-not $_.SiteUrl.EndsWith("/")})

if($sites.Count -le 0){
    if($specificSiteUrls.Length -gt 1){
        Throw "No sites matching the specified urls found!"
    }else{
        Throw "No sites found in your environment!"
    }
}

$reportRows = New-Object System.Collections.ArrayList
for($siteCount = 0;$siteCount -lt $sites.Count;$siteCount++){
    Write-Progress -Activity "$($siteCount+1)/$($sites.Count) site $($sites[$siteCount].SiteUrl)" -Status "Retrieving lists in site..." -PercentComplete 0
    Write-Output "Processing $($sites[$siteCount].Title) with url $($sites[$siteCount].SiteUrl)"
    if($useMFA){
        Connect-PnPOnline $sites[$siteCount].SiteUrl -UseWebLogin
    }else{
        Connect-PnPOnline $sites[$siteCount].SiteUrl -Credentials $script:Credential
    }
    $lists = @(Get-PnPList -Includes BaseType,BaseTemplate,ItemCount | where {($_.BaseTemplate -eq 101 -or $_.BaseTemplate -eq 700) -and $_.ItemCount -gt 0})
    for($listCount = 0;$listCount -lt $lists.Count;$listCount++) {
        Write-Output "Detected document library $($lists[$listCount].Title) with Id $($lists[$listCount].Id.Guid) and Url $baseUrl$($lists[$listCount].RootFolder.ServerRelativeUrl), processing $($lists[$listCount].ItemCount) items..."
        Write-Progress -Activity "$($siteCount+1)/$($sites.Count) site $($sites[$siteCount].SiteUrl)" -Status "Retrieving items for list $($lists[$listCount].Title)" -PercentComplete 0
        $items = $Null
        $items = Get-PnPListItem -List $lists[$listCount] -PageSize 2000
        $itemCount = 0
        foreach($item in $items){
            $itemCount++
            try{$percentage = ($itemCount/$($lists[$listCount].ItemCount)*100)}catch{$percentage=1}
            Write-Progress -Activity "$($siteCount+1)/$($sites.Count) site $($sites[$siteCount].SiteUrl)" -Status "Processing list $($lists[$listCount].Title) item $itemCount of $($lists[$listCount].ItemCount)" -PercentComplete $percentage
            
            #Determine the file type
            if($item.FileSystemObjectType -ne "Folder"){
                try{
                    $fileType = $Null
                    $fileType = $item.FieldValues.FileRef.Substring($item.FieldValues.FileRef.LastIndexOf("."))
                }catch{
                    $fileType = "Unknown"
                }
            }else{
                $fileType = "N/A"
            }                   

            $ObjectProperties = [Ordered]@{
                "Site URL" = $sites[$siteCount].SiteUrl
                "Item full URL" = "$baseUrl$($item.FieldValues.FileRef)"
                "Item Unique ID" = $item.FieldValues.UniqueId
                "Item Name" = $item.FieldValues.FileLeafRef
                "Item extension" = $fileType
                "Item Type" = $item.FileSystemObjectType
                "Last modified" = $item.FieldValues.Modified
                "Modified by" = $item.FieldValues.Modified_x0020_By
                "Created" = $item.FieldValues.Created
                "Created by" = $item.FieldValues.Created_x0020_By
                "Size" = $item.FieldValues.File_x0020_Size
            }
            [void]$reportRows.Add((New-Object -TypeName PSObject -Property $ObjectProperties))
        }
    }
}

Write-Progress -Activity "$($siteCount+1)/$($sites.Count)" -Status "Exporting to CSV" -PercentComplete 99
$reportRows | export-csv -Path $csvPath -Force -NoTypeInformation -Encoding UTF8 -Delimiter ","
Write-Progress -Activity "$($siteCount+1)/$($sites.Count)" -Status "Script complete" -PercentComplete 100 -Completed
Write-Output "data retrieved and exported to $($csvPath)"