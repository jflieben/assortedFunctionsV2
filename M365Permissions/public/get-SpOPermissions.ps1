Function get-SpOPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -teamName: the name of the Team to scan
        -siteUrl: the URL of the Team (or any sharepoint location) to scan (e.g. if name is not unique)
        -expandGroups: if set, group memberships will be expanded to individual users
        -outputFormat: 
            XLSX
            CSV
            Default (output to Out-GridView)
            Any combination of above is possible
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
    #>        
    Param(
        [parameter(Mandatory=$true,
        ParameterSetName="ByName")]
        [String]
        $teamName,
    
        [parameter(Mandatory=$true,
        ParameterSetName="BySite")]
        [String]
        $siteUrl, 

        [Switch]$expandGroups,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX",
        [Switch]$includeCurrentUser
    )

    $global:octo.includeCurrentUser = $includeCurrentUser.IsPresent

    Write-Host "Starting SpO Scan of $teamName $siteUrl"

    $spoBaseAdmUrl = "https://$($global:octo.tenantName)-admin.sharepoint.com"
    Write-Verbose "Using Sharepoint base URL: $spoBaseAdmUrl"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    if($siteUrl){
        $sites = @(Get-PnPTenantSite -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) -Identity $siteUrl)
    }
    if(!$sites){
        $sites = @(Get-PnPTenantSite -IncludeOneDriveSites -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) | Where-Object {`
            $_.Template -NotIn $ignoredSiteTypes -and
            ($Null -ne $teamName -and $_.Title -eq $teamName -and $_.Template -notlike "*CHANNEL*") -or ($Null -ne $siteUrl -and $_.Url -eq $siteUrl)
        })
    }

    if($sites.Count -gt 1){
        Throw "Failed to find a single Team using $teamName. Found: $($sites.Url -join ","). Please use the Url to specify the correct Team"
    }elseif($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find a Team using $teamName $siteUrl. Please check the name and try again"
    }else{
        $site = $sites[0]
    }

    if($site.IsTeamsConnected){
        try{
            Write-Host "Retrieving channels for this site/team..."
            $channels = New-GraphQuery -Uri "https://graph.microsoft.com/beta/teams/$($site.GroupId.Guid)/channels" -Method GET -NoRetry
            Write-Host "Found $($channels.Count) channels"
        }catch{
            Write-Warning "Failed to retrieve channels for this site/team, assuming no additional sub sites to scan"
            $channels = @()
        }
        foreach($channel in $channels){
            if($channel.filesFolderWebUrl){
                $targetUrl = $Null; $targetUrl ="https://$($global:octo.tenantName).sharepoint.com/$($channel.filesFolderWebUrl.Split("/")[3])/$($channel.filesFolderWebUrl.Split("/")[4])"
            }
            if($targetUrl -and $sites.Url -notcontains $targetUrl){
                try{
                    Write-Host "Adding Channel $($channel.displayName) with URL $targetUrl to scan list as it has its own site"
                    $extraSite = $Null; $extraSite = Get-PnPTenantSite -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) -Identity $targetUrl
                    if($extraSite -and $extraSite.Template -NotIn $ignoredSiteTypes){
                        $sites += $extraSite
                    }
                }catch{
                    Write-Error "Failed to add Channel $($channel.displayName) with URL $targetUrl to scan list. It may have been deleted, because Get-PnPTenantSite failed with $_" -ErrorAction Continue
                }
            }          
        }
    }

    foreach($site in $sites){
        $global:SPOPermissions = @{}
        $siteCategory = "SharePoint"
        if($site.GroupId.Guid -and $site.GroupId.Guid -ne "00000000-0000-0000-0000-000000000000"){
            $siteCategory = "O365Group"
        }
        if($site.IsTeamsConnected -or $site.IsTeamsChannelConnected){
            $siteCategory = "Teams"
            Write-Host "Site is connected to a Team will be categorized as Teams site"
        }
        if($site.Url -like "*-my.sharepoint.com*"){
            $siteCategory = "OneDrive"
            Write-Host "Site is a OneDrive site"
        }

        New-StatisticsObject -Category $siteCategory -Subject $site.Url
           
        $wasOwner = $False
        try{
            if($site.Owners -notcontains $global:octo.currentUser.userPrincipalName){
                Write-Host "Adding you as site collection owner to ensure all permissions can be read from $($site.Url)..."
                Set-PnPTenantSite -Identity $site.Url -Owners $global:octo.currentUser.userPrincipalName -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) -WarningAction Stop -ErrorAction Stop
                Write-Host "Owner added and marked for removal upon scan completion"
            }else{
                $wasOwner = $True
                Write-Host "Site collection ownership verified for $($site.Url) :)"
            }            
            $spoWeb = Get-PnPWeb -Connection (Get-SpOConnection -Type User -Url $site.Url) -ErrorAction Stop
        }catch{        
            Write-Error "Failed to parse site $($site.Url) because $_" -ErrorAction Continue
            continue
        }
        
        Write-Host "Scanning root $($spoWeb.Url)..."
        $spoSiteAdmins = Get-PnPSiteCollectionAdmin -Connection (Get-SpOConnection -Type User -Url $site.Url)
        $global:SPOPermissions.$($spoWeb.Url) = @()

        foreach($spoSiteAdmin in $spoSiteAdmins){
            if($spoSiteAdmin.PrincipalType -ne "User" -and $expandGroups){
                $members = $Null; $members = Get-PnPGroupMembers -group $spoSiteAdmin -parentId $spoSiteAdmin.Id -siteConn (Get-SpOConnection -Type User -Url $site.Url) | Where-Object {$_}
                foreach($member in $members){
                    Update-StatisticsObject -Category $siteCategory -Subject $site.Url
                    New-SpOPermissionEntry -Path $spoWeb.Url -Permission (get-spopermissionEntry -entity $member -object $spoWeb -permission "Owner" -Through "GroupMembership" -parent $spoSiteAdmin.Title)
                }
            }else{
                Update-StatisticsObject -Category $siteCategory -Subject $site.Url
                New-SpOPermissionEntry -Path $spoWeb.Url -Permission (get-spopermissionEntry -entity $spoSiteAdmin -object $spoWeb -permission "Owner" -Through "DirectAssignment")
            }
        }        

        get-PnPObjectPermissions -Object $spoWeb -Category $siteCategory

        Stop-StatisticsObject -Category $siteCategory -Subject $site.Url

        if(!$wasOwner){
            Write-Host "Cleanup: Removing you as site collection owner of $($site.Url)..."
            Remove-PnPSiteCollectionAdmin -Owners $global:octo.currentUser.userPrincipalName -Connection (Get-SpOConnection -Type User -Url $site.Url)
            Write-Host "Cleanup: Owner removed"
        }       
        
        $permissionRows = foreach($row in $global:SPOPermissions.Keys){
            foreach($permission in $global:SPOPermissions.$row){
                [PSCustomObject]@{
                    "Path" = $row
                    "Object"    = $permission.Object
                    "Name" = $permission.Name
                    "Identity" = $permission.Identity
                    "Email" = $permission.Email
                    "Type" = $permission.Type
                    "Permission" = $permission.Permission
                    "Through" = $permission.Through
                    "Parent" = $permission.Parent
                    "LinkCreationDate" = $permission.LinkCreationDate
                    "LinkExpirationDate" = $permission.LinkExpirationDate                
                }
            }
        }
    
        add-toReport -formats $outputFormat -permissions $permissionRows -category $siteCategory -subject $site.Url      
        Remove-Variable -Name permissionRows -Force
        [System.GC]::Collect()           
    }
}