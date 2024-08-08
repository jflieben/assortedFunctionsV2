Function get-TeamPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [parameter(Mandatory=$true,
        ParameterSetName="ByName")]
        [String]
        $teamName,
    
        [parameter(Mandatory=$true,
        ParameterSetName="BySite")]
        [String]
        $teamSiteUrl, 

        [Switch]$expandGroups
    )

    if(!$global:LCCachedToken){
        get-AuthorizationCode
    }

    $global:tenantName = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' -NoPagination | Where-Object -Property isInitial -EQ $true).id.Split(".")[0]
    $currentUser = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    Write-Host "Performing scan using: $($currentUser.userPrincipalName)"

    $spoBaseAdmUrl = "https://$($tenantName)-admin.sharepoint.com"
    Write-Host "Using Sharepoint base URL: $spoBaseAdmUrl"

    $sites = Get-PnPTenantSite -Connection (Get-SpOConnection -Type Admin -Url $spoBaseAdmUrl) | Where {`
        $_.Template -NotIn ("SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1","EHS#1","POINTPUBLISHINGTOPIC#0") -and
        ($teamName -ne $Null -and $_.Title -eq $teamName) -or ($teamSiteUrl -ne $null -and $_.Url -eq $teamSiteUrl)
    }

    if($sites.Count -gt 1){
        Throw "Failed to find a single Team using $teamName. Found: $($sites.Url -join ","). Please use the Url to specify the correct Team"
    }elseif($sites.Count -eq 0 -or $Null -eq $sites){
        Throw "Failed to find a Team using $teamName $teamSiteUrl. Please check the name and try again"
    }else{
        $site = $sites[0]
    }

    $wasOwner = $False
    if((get-PnPSiteCollectionAdmin -Connection (Get-SpOConnection -Type User -Url $site.Url)).Email -notcontains $currentUser.userPrincipalName){
        Write-Host "Adding you as site collection owner to ensure all permissions can be read..."
        Add-PnPSiteCollectionAdmin -Owners $currentUser.userPrincipalName -Connection (Get-SpOConnection -Type User -Url $site.Url)
        Write-Host "Owner added and marked for removal upon scan completion"
    }else{
        $wasOwner = $True
        Write-Host "Site collection ownership verified :)"
    }

    if($site.GroupId.Guid -eq "00000000-0000-0000-0000-000000000000"){
        $groupId = $Null
        Write-Warning "Site is not connected to a group and is likely not a Team site."
    }else{
        $groupId = $site.GroupId.Guid
        Write-Host "Site is connected to a group with ID: $groupId"
    }

    $spoWeb = Get-PnPWeb -Connection (Get-SpOConnection -Type User -Url $site.Url) -ErrorAction Stop
    $spoWebRegion = Get-PnPProperty -ClientObject $spoWeb -Property RegionalSettings -Connection (Get-SpOConnection -Type User -Url $site.Url)
    Write-Host "Scanning root $($spoWeb.Url)..."
    $spoSiteAdmins = Get-PnPSiteCollectionAdmin -Connection (Get-SpOConnection -Type User -Url $site.Url)
    $global:permissions = @{
        $spoWeb.Url = @()
    }

    #language specific permission name translation
    switch($spoWebRegion.LocalId){
        1043 { $fullControl = "Volledig beheer"}
        Default { $fullControl = "Full Control"}
    }

    foreach($spoSiteAdmin in $spoSiteAdmins){
        if($spoSiteAdmin.PrincipalType -ne "User" -and $expandGroups){
            $members = $Null; $members = Get-PnPGroupMembers -name $spoSiteAdmin.Title -parentId $spoSiteAdmin.Id -siteConn (Get-SpOConnection -Type User -Url $site.Url) | Where {$_}
            foreach($member in $members){
                New-PermissionEntry -Path $spoWeb.Url -Permission (get-permissionEntry -entity $member -object $spoWeb -permission $fullControl -Through "GroupMembership" -parent $spoSiteAdmin.Title)
            }
        }else{
            New-PermissionEntry -Path $spoWeb.Url -Permission (get-permissionEntry -entity $spoSiteAdmin -object $spoWeb -permission $fullControl -Through "DirectAssignment")
        }
    }

    get-PnPObjectPermissions -Object $spoWeb

    $permissionRows = @()
    foreach($row in $global:permissions.Keys){
        foreach($permission in $global:permissions.$row){
            $permissionRows += [PSCustomObject]@{
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
            }
        }
    }
    $permissionRows | out-gridview

    if(!$wasOwner){
        Write-Host "Cleanup: Removing you as site collection owner..."
        Remove-PnPSiteCollectionAdmin -Owners $currentUser.userPrincipalName -Connection $spoSiteConn
        Write-Host "Cleanup: Owner removed"
    }
}