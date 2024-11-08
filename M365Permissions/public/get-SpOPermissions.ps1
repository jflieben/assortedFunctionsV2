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
        -ignoreCurrentUser: do not add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
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
        [parameter(Mandatory=$true)]
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat,
        [Switch]$ignoreCurrentUser
    )

    $global:ignoreCurrentUser = $ignoreCurrentUser.IsPresent
    if(!$global:tenantName){
        $global:tenantName = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' -NoPagination | Where-Object -Property isInitial -EQ $true).id.Split(".")[0]
    }
    if(!$global:currentUser){
        $global:currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    }
    Write-Host "Scanning $teamName $siteUrl as $($currentUser.userPrincipalName)"

    $spoBaseAdmUrl = "https://$($tenantName)-admin.sharepoint.com"
    Write-Verbose "Using Sharepoint base URL: $spoBaseAdmUrl"

    $ignoredSiteTypes = @("REDIRECTSITE#0","SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0")
    if($siteUrl){
        $sites = Get-PnPTenantSite -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) -Identity $siteUrl
    }
    if(!$sites){
        $sites = @(Get-PnPTenantSite -IncludeOneDriveSites -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) | Where-Object {`
            $_.Template -NotIn $ignoredSiteTypes -and
            ($Null -ne $teamName -and $_.Title -eq $teamName) -or ($Null -ne $siteUrl -and $_.Url -eq $siteUrl)
        })
    }

    if($sites.Count -gt 1){
        Throw "Failed to find a single Team using $teamName. Found: $($sites.Url -join ","). Please use the Url to specify the correct Team"
    }elseif($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find a Team using $teamName $siteUrl. Please check the name and try again"
    }else{
        $site = $sites[0]
    }

    if($site.GroupId.Guid -eq "00000000-0000-0000-0000-000000000000"){
        $groupId = $Null
        Write-Host "Site is not connected to a group and is likely not a Team site."
    }else{
        $groupId = $site.GroupId.Guid
        Write-Host "Site is connected to a group with ID: $groupId"
    }

    if($groupId){
        try{
            Write-Host "Retrieving channels for this site/team..."
            $channels = New-GraphQuery -Uri "https://graph.microsoft.com/beta/teams/$groupId/channels" -Method GET -NoRetry
            Write-Host "Found $($channels.Count) channels"
        }catch{
            Write-Warning "Failed to retrieve channels for this site/team, assuming no additional sub sites to scan"
            $channels = @()
        }
        foreach($channel in $channels){
            if($channel.filesFolderWebUrl){
                $targetUrl = $Null; $targetUrl ="https://$($tenantName).sharepoint.com/sites/$($channel.filesFolderWebUrl.Split("/")[4])"
            }
            if($targetUrl -and $sites.Url -notcontains $targetUrl){
                try{
                    Write-Host "Adding Channel $($channel.displayName) with URL $targetUrl to scan list"
                    $extraSite = $Null; $extraSite = Get-PnPTenantSite -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) -Identity $targetUrl
                    if($extraSite -and $extraSite.Template -NotIn $ignoredSiteTypes){
                        $sites += $extraSite
                    }
                }catch{
                    Write-Error "Failed to add Channel $($channel.displayName) with URL $targetUrl to scan list because Get-PnPTenantSite failed with $_" -ErrorAction Continue
                }
            }          
        }
    }

    $global:SPOPermissions = @{}
    $statObjects = @()

    foreach($site in $sites){ 
        $global:statObj = [PSCustomObject]@{
            "Module version" = $MyInvocation.MyCommand.Module.Version
            "Category" = "SharePoint"
            "Subject" = $site.Url
            "Total objects scanned" = 0
            "Scan start time" = Get-Date
            "Scan end time" = ""
            "Scan performed by" = $currentUser.userPrincipalName
        }              
        $wasOwner = $False
        try{
            if($site.Owners -notcontains $currentUser.userPrincipalName){
                Write-Host "Adding you as site collection owner to ensure all permissions can be read from $($site.Url)..."
                Set-PnPTenantSite -Identity $site.Url -Owners $currentUser.userPrincipalName -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) -WarningAction Stop -ErrorAction Stop
                Write-Host "Owner added and marked for removal upon scan completion"
            }else{
                $wasOwner = $True
                Write-Host "Site collection ownership verified for $($site.Url) :)"
            }            
            $spoWeb = Get-PnPWeb -Connection (Get-SpOConnection -Type User -Url $site.Url) -ErrorAction Stop
        }catch{        
            Write-Error "Failed to parse site $($site.Url) because $_" -ErrorAction Continue
            $global:statObj."Scan end time" = "ERROR! $_"
            $statObjects += $global:statObj
            continue
        }
        
        Write-Host "Scanning root $($spoWeb.Url)..."
        $spoSiteAdmins = Get-PnPSiteCollectionAdmin -Connection (Get-SpOConnection -Type User -Url $site.Url)
        $global:SPOPermissions.$($spoWeb.Url) = @()

        foreach($spoSiteAdmin in $spoSiteAdmins){
            if($spoSiteAdmin.PrincipalType -ne "User" -and $expandGroups){
                $members = $Null; $members = Get-PnPGroupMembers -group $spoSiteAdmin -parentId $spoSiteAdmin.Id -siteConn (Get-SpOConnection -Type User -Url $site.Url) | Where-Object {$_}
                foreach($member in $members){
                    New-SpOPermissionEntry -Path $spoWeb.Url -Permission (get-spopermissionEntry -entity $member -object $spoWeb -permission "Owner" -Through "GroupMembership" -parent $spoSiteAdmin.Title)
                }
            }else{
                New-SpOPermissionEntry -Path $spoWeb.Url -Permission (get-spopermissionEntry -entity $spoSiteAdmin -object $spoWeb -permission "Owner" -Through "DirectAssignment")
            }
        }        

        get-PnPObjectPermissions -Object $spoWeb

        $global:statObj."Scan end time" = Get-Date
        $statObjects += $global:statObj
        if(!$wasOwner){
            Write-Host "Cleanup: Removing you as site collection owner of $($site.Url)..."
            Remove-PnPSiteCollectionAdmin -Owners $currentUser.userPrincipalName -Connection (Get-SpOConnection -Type User -Url $site.Url)
            Write-Host "Cleanup: Owner removed"
        }          
    }
    
    Write-Host "All permissions retrieved, writing reports..."

    $permissionRows = foreach($row in $global:SPOPermissions.Keys){
        foreach($permission in $global:SPOPermissions.$row){
            [PSCustomObject]@{
                "ID" = $permission.RowId
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

    if((get-location).Path){
        $basePath = Join-Path -Path (get-location).Path -ChildPath "M365Permissions.@@@"
    }else{
        $basePath = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "M365Permissions.@@@"
    }

    foreach($format in $outputFormat){
        switch($format){
            "XLSX" { 
                $targetPath = $basePath.Replace("@@@","xlsx")
                $permissionRows | Export-Excel -Path $targetPath -WorksheetName "TeamPermissions" -TableName "TeamPermissions" -TableStyle Medium10 -Append -AutoSize
                $statObjects | Export-Excel -Path $targetPath -WorksheetName "Statistics" -TableName "Statistics" -TableStyle Medium10 -Append -AutoSize
                Write-Host "XLSX report saved to $targetPath"
            }
            "CSV" { 
                $targetPath = $basePath.Replace("@@@","-SpO.csv")
                $permissionRows | Export-Csv -Path $targetPath -NoTypeInformation  -Append
                Write-Host "CSV report saved to $targetPath"
            }

            "Default" { $permissionRows | out-gridview }
        }
    }
}