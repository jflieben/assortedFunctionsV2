Function get-PnPObjectPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$Object,
        $siteUrl,
        $Category
    )

    $ignoreablePermissions = @(0,1,9) #None (0), Limited Access (1), Web-Only Limited Access (9)

    $obj = [PSCustomObject]@{
        "Title" = $null
        "Type" = $null
        "Url" = $Null
    }    

    if($Object.ListGuid){
        $itemData = New-GraphQuery -resource "https://www.sharepoint.com" -Uri "$($siteUrl)/_api/web/lists/getbyid('$($Object.ListGuid)')/items($($Object.ID))?`$expand=File,Folder,RoleAssignments/Member,RoleAssignments/RoleDefinitionBindings&`$select=FileSystemObjectType,Folder,File,Id,Title,RoleAssignments&`$format=json" -Method GET
        If($itemData.FileSystemObjectType -eq 1){
            $obj.Title = $itemData.Folder.Name
            $obj.Url = "$($siteUrl.Split(".com")[0]).com$($itemData.Folder.ServerRelativeUrl)"
            $obj.Type = "Folder"  
        }Else{
            If($Null -ne $itemData.File.Name){
                $obj.Title = $itemData.File.Name
                $obj.Url = "$($siteUrl.Split(".com")[0]).com$($itemData.File.ServerRelativeUrl)"
                $obj.Type = "File"
            }else{
                $obj.Title = $itemData.Title
                $obj.Url = "$($siteUrl)/$($Object.displayFormUrl)?ID=$($Object.ID)"
                $obj.Type = "List Item"         
            }
        }
        $ACLs = $itemData.RoleAssignments
    }else{
        Switch($Object.TypedObject.ToString()){
            "Microsoft.SharePoint.Client.Web"  { 
                $siteUrl = $Object.Url
                $obj.Title = $Object.Title
                $obj.Url = $Object.Url
                $obj.Type = "Site"
                Update-StatisticsObject -Category $Category -Subject $siteUrl
                $Null = Get-PnPProperty -ClientObject $Object -Property HasUniqueRoleAssignments, RoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                if($Object.HasUniqueRoleAssignments -eq $False){
                    Write-Verbose "Skipping $($obj.Title) as it fully inherits permissions from parent"
                    continue
                }else{
                    $ACLs = New-GraphQuery -resource "https://www.sharepoint.com" -Uri "$($Object.Url)/_api/web/roleAssignments?`$expand=Member,RoleDefinitionBindings&`$top=5000&`$format=json" -Method GET -expectedTotalResults $Object.RoleAssignments.Count
                }
            }
            Default{ 
                $rootFolder = Get-PnPProperty -ClientObject $Object -Property RootFolder -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                $obj.Title = $Object.Title
                $obj.Url = "$($siteUrl.Split(".com")[0]).com$($rootFolder.ServerRelativeUrl)"
                $obj.Type = "List or Library"  
                Update-StatisticsObject -Category $Category -Subject $siteUrl
                $Null = Get-PnPProperty -ClientObject $Object -Property HasUniqueRoleAssignments, RoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                if($Object.HasUniqueRoleAssignments -eq $False){
                    Write-Verbose "Skipping $($obj.Title) as it fully inherits permissions from parent"
                    continue
                }else{            
                    $ACLs = New-GraphQuery -resource "https://www.sharepoint.com" -Uri "$($siteUrl)/_api/web/lists/getbyid('$($Object.Id)')/roleassignments?`$expand=Member,RoleDefinitionBindings&`$top=5000&`$format=json" -Method GET -expectedTotalResults $Object.RoleAssignments.Count
                }
            }
        }   
        #sharepoint libraries / subsites etc do not list root level owner permissions, but we should still add them since those always trickle down
        if($Object.TypedObject.ToString() -ne "Microsoft.SharePoint.Client.ListItem"){
            foreach($folder in $($global:SPOPermissions.Keys)){
                if($obj.Url.Contains($folder)){
                    foreach($permission in $global:SPOPermissions.$folder){
                        if($Permission.Object -eq "root"){
                            Write-Verbose "Added: $($permission.Permission) for $($permission.Name) because of forced inheritance through the site root"
                            New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity @{Email = $Permission.Email; LoginName = $Permission.Identity;Title = $Permission.Name;PrincipalType=$Permission.Type} -object $obj -permission $Permission.Permission -Through "ForcedInheritance" -parent $folder)
                        }
                    }
                }
            }
        }        
    } 

    #processes all ACL's on the object
    Foreach($member in $ACLs){
        foreach($permission in $member.RoleDefinitionBindings){
            Write-Verbose "Detected: $($member.Member.Title) $($permission.Name) ($($permission.RoleTypeKind))"
            if($ignoreablePermissions -contains $permission.RoleTypeKind -or $member.Member.IsHiddenInUI){
                Write-Verbose "Ignoring $($permission.Name) permission type for $($member.Member.Title) because it is only relevant at a deeper level or hidden"
                continue
            }
            if($member.Member.PrincipalType -eq 1){
                New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $member.Member -object $obj -permission $permission.Name -Through "DirectAssignment")
            }else{
                if($member.Member.LoginName -like "SharingLinks*"){
                    $sharingLinkInfo = $Null; $sharingLinkInfo = get-SpOSharingLinkInfo -sharingLinkGuid $member.Member.LoginName.Split(".")[3]
                    if($sharingLinkInfo){
                        switch([Int]$sharingLinkInfo.LinkKind){
                            {$_ -in (2,3)}  { #Org wide
                                New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity @{Email = "N/A";Title = "All Internal Users";PrincipalType="ORG-WIDE"} -object $obj -permission $permission.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                            }                            
                            {$_ -in (4,5)}  { #Anonymous
                                New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity @{Email = "N/A";Title = "Anyone / Anonymous";PrincipalType="ANYONE"} -object $obj -permission $permission.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                            }                            
                            {$_ -in (1,6)}  { #direct, flexible
                                foreach($invitee in $sharingLinkInfo.invitees){
                                    New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity (get-spoInvitee -invitee $invitee -siteUrl $siteUrl) -object $obj -permission $permission.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                                }
                            }
                        }
                    }else{
                        New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $member.Member -object $obj -permission $permission.Name -Through "SharingLink")
                    }                    
                }else{
                    if($expandGroups){
                        Get-PnPGroupMembers -Group $member.Member -parentId $member.Member.Id -siteConn (Get-SpOConnection -Type User -Url $siteUrl) | ForEach-Object {
                            if($_.PrincipalType -ne "User"){$through = "DirectAssignment"}else{$through = "GroupMembership"}
                            New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $_ -object $obj -permission $permission.Name -Through $through -parent $member.Member.Title)
                        }
                    }else{
                        New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $member.Member -object $obj -permission $permission.Name -Through "DirectAssignment")
                    }
                }
            }
        }
    }

    #retrieve permissions for any (if present) child objects and recursively call this function for each
    If(!$Object.ListGuid -and $Object.TypedObject.ToString() -eq "Microsoft.SharePoint.Client.Web"){
        Write-Progress -Id 2 -PercentComplete 0 -Activity $($siteUrl.Split("/")[4]) -Status "Getting child objects..."
        $Null = Get-PnPProperty -ClientObject $Object -Property Webs -Connection (Get-SpOConnection -Type User -Url $siteUrl)
        $childObjects = $Null; $childObjects = $Object.Webs
        foreach($childObject in $childObjects){
            #check if permissions are unique
            $Null = Get-PnPProperty -ClientObject $childObject -Property HasUniqueRoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
            if($childObject.HasUniqueRoleAssignments -eq $False){
                Write-Verbose "Skipping $($childObject.Title) child web as it fully inherits permissions from parent"
                continue
            }                
            Write-Verbose "Enumerating permissions for sub web $($childObject.Title)..."
            get-PnPObjectPermissions -Object $childObject -Category $Category
        }
        $childObjects = $Null; $childObjects = Get-PnPProperty -ClientObject $Object -Property Lists -Connection (Get-SpOConnection -Type User -Url $siteUrl)
        $ExcludedListTitles = @("Access Requests","App Packages","appdata","appfiles","Apps in Testing","Cache Profiles","Composed Looks","Content and Structure Reports","Content type publishing error log","Converted Forms",
        "Device Channels","Form Templates","fpdatasources","Get started with Apps for Office and SharePoint","List Template Gallery", "Long Running Operation Status","Maintenance Log Library", "Images", "site collection images"
        ,"Master Docs","Master Page Gallery","MicroFeed","NintexFormXml","Quick Deploy Items","Relationships List","Reusable Content","Reporting Metadata", "Reporting Templates", "Search Config List","Site Assets","Preservation Hold Library",
        "Site Pages", "Solution Gallery","Style Library","Suggested Content Browser Locations","Theme Gallery", "TaxonomyHiddenList","User Information List","Web Part Gallery","wfpub","wfsvc","Workflow History","Workflow Tasks", "Pages")
        $ExcludedListFeatureIDs = @("00000000-0000-0000-0000-000000000000","a0e5a010-1329-49d4-9e09-f280cdbed37d","d11bc7d4-96c6-40e3-837d-3eb861805bfa","00bfea71-c796-4402-9f2f-0eb9a6e71b18","de12eebe-9114-4a4a-b7da-7585dc36a907")

        $sharedLinksList = $Null; $sharedLinksList = $childObjects | Where-Object{$_.TemplateFeatureId -eq "d11bc7d4-96c6-40e3-837d-3eb861805bfa" -and $_}
        if($sharedLinksList){
            try{
                $global:sharedLinks = $Null;$global:sharedLinks = (New-RetryCommand -Command 'Get-PnPListItem' -Arguments @{List = $sharedLinksList.Id; PageSize = 500;Fields = ("ID","AvailableLinks"); Connection = (Get-SpOConnection -Type User -Url $siteUrl)}) | ForEach-Object {
                    $_.FieldValues["AvailableLinks"] | ConvertFrom-Json
                }
                Write-Host "Cached $($sharedLinks.Count) shared links in $($Object.Title)..."
            }catch{
                Write-Error "Failed to retrieve shared links in $($Object.Title) because $_" -ErrorAction Continue
            }
        }else{
            Write-Host "No shared links in $($Object.Title) discovered"
        }

        $counter = 0
        ForEach($List in $childObjects){
            Update-StatisticsObject -Category $Category -Subject $siteUrl -Amount $List.ItemCount
            If($List.Hidden -eq $False -and $ExcludedListTitles -notcontains $List.Title -and $List.ItemCount -gt 0 -and $List.TemplateFeatureId -notin $ExcludedListFeatureIDs){
                $counter++
                Write-Progress -Id 2 -PercentComplete ($Counter / ($childObjects.Count) * 100) -Activity $($siteUrl.Split("/")[4]) -Status "'$($List.Title)': $($List.ItemCount) items (List $counter of $($childObjects.Count))"
                #grab top level info of the list first
                get-PnPObjectPermissions -Object $List -siteUrl $siteUrl -Category $Category

                Get-PnPProperty -ClientObject $List -Property Title, HasUniqueRoleAssignments, DefaultDisplayFormUrl -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                if($List.HasUniqueRoleAssignments -eq $False){
                    Write-Verbose "Skipping $($List.Title) List as it fully inherits permissions from parent"
                    continue
                }     

                Write-Verbose "List contains $($List.ItemCount) items"
                $allListItems = $Null; $allListItems = New-GraphQuery -resource "https://www.sharepoint.com" -Uri "$($Object.Url)/_api/web/lists/getbyid('$($List.Id.Guid)')/items?`$select=ID,HasUniqueRoleAssignments&`$top=5000&`$format=json" -Method GET -expectedTotalResults $List.ItemCount
                $allUniqueListItemIDs = $Null; $allUniqueListItemIDs = @($allListItems | Where-Object { $_.HasUniqueRoleAssignments -eq $True }) | select -ExpandProperty Id
                if(($global:octo.defaultTimeoutMinutes*20) -lt $allUniqueListItemIDs.Count){
                    Write-Error "List $($List.Title) has too many ($($allUniqueListItemIDs.Count)) items with unique permissions, we probably can't process them inside the current default timeout of $($global:octo.defaultTimeoutMinutes). Please set it to at least $($allUniqueListItemIDs.Count/20) using set-M365PermissionsConfig -defaultTimeoutMinutes XXX" -ErrorAction Continue
                }

                for($a=0;$a -lt $allUniqueListItemIDs.Count;$a++){
                    Write-Progress -Id 3 -PercentComplete ((($a+1) / $allUniqueListItemIDs.Count) * 100) -Activity $($siteUrl.Split("/")[4]) -Status "$a / $($allUniqueListItemIDs.Count) processing unique permissions"
                    $uniqueObject = [PSCustomObject]@{
                        "ID" = $allUniqueListItemIDs[$a]
                        "ListGuid" = $List.Id.Guid
                        "displayFormUrl" = $List.DefaultDisplayFormUrl
                    }
                    get-PnPObjectPermissions -Object $uniqueObject -siteUrl $siteUrl -Category $Category
                }
                Write-Progress -Id 3 -Completed -Activity $($siteUrl.Split("/")[4])
            }else{
                Write-Verbose "Skipping $($List.Title) as it is hidden, empty or excluded"
            }
        }
        Write-Progress -Id 2 -Completed -Activity $($siteUrl.Split("/")[4])            
    }      
}