Function get-PnPObjectPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)][Microsoft.SharePoint.Client.SecurableObject]$Object,
        $siteUrl,
        $Category
    )

    $ignoreablePermissions = @("Guest","RestrictedGuest","None")

    $obj = [PSCustomObject]@{
        "Title" = $null
        "Type" = $null
        "Url" = $Null
    }    

    Switch($Object.TypedObject.ToString()){
        "Microsoft.SharePoint.Client.Web"  { 
            $siteUrl = $Object.Url#"https://$($Object.Url.Split("/")[2..4] -join "/")"
            $obj.Title = $Object.Title
            $obj.Url = $Object.Url
            $obj.Type = "Site"
            Update-StatisticsObject -Category $Category -Subject $siteUrl
        }
        "Microsoft.SharePoint.Client.ListItem"{ 
            If($Object.FileSystemObjectType -eq "Folder"){
                $Null = Get-PnPProperty -ClientObject $Object -Property Folder -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                $obj.Title = $Object.Folder.Name
                $obj.Url = "$($siteUrl.Split(".com")[0]).com$($Object.Folder.ServerRelativeUrl)"
                $obj.Type = "Folder"  
            }Else{
                Get-PnPProperty -ClientObject $Object -Property File, ParentList -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                If($Null -ne $Object.File.Name){
                    $obj.Title = $Object.File.Name
                    $obj.Url = "$($siteUrl.Split(".com")[0]).com$($Object.File.ServerRelativeUrl)"
                    $obj.Type = "File"
                }else{
                    $DefaultDisplayFormUrl = Get-PnPProperty -ClientObject $Object.ParentList -Property DefaultDisplayFormUrl -Connection (Get-SpOConnection -Type User -Url $siteUrl)                   
                    $obj.Title = $Object["Title"]
                    $obj.Url = "$($siteUrl.Split(".com")[0]).com$($DefaultDisplayFormUrl)?ID=$($Object.ID)"
                    $obj.Type = "List Item"         
                }
            }
        }
        Default{ 
            $rootFolder = Get-PnPProperty -ClientObject $Object -Property RootFolder -Connection (Get-SpOConnection -Type User -Url $siteUrl)
            $obj.Title = $Object.Title
            $obj.Url = "$($siteUrl.Split(".com")[0]).com$($rootFolder.ServerRelativeUrl)"
            $obj.Type = "List or Library"  
            Update-StatisticsObject -Category $Category -Subject $siteUrl
        }
    }    

    #retrieve all permissions for the supplied object
    Get-PnPProperty -ClientObject $Object -Property HasUniqueRoleAssignments, RoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)    
    if($Object.HasUniqueRoleAssignments -eq $False){
        Write-Verbose "Skipping $($obj.Title) as it fully inherits permissions from parent"
        continue
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
    
    Foreach($roleAssignment in $Object.RoleAssignments){
        Get-PnPProperty -ClientObject $roleAssignment -Property RoleDefinitionBindings, Member -Connection (Get-SpOConnection -Type User -Url $siteUrl)
        
        foreach($permissionLevel in $roleAssignment.RoleDefinitionBindings){
            Write-Verbose "Detected: $($roleAssignment.Member.Title) $($permissionLevel.Name) ($($permissionLevel.RoleTypeKind))"
            if($ignoreablePermissions -contains $permissionLevel.RoleTypeKind -or $roleAssignment.Member.IsHiddenInUI){
                Write-Verbose "Ignoring $($permissionLevel.Name) permission type for $($roleAssignment.Member.Title) because it is only relevant at a deeper level or hidden"
                continue
            }
            if($roleAssignment.Member.PrincipalType -eq "User"){
                New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $roleAssignment.Member -object $obj -permission $permissionLevel.Name -Through "DirectAssignment")
            }elseif($roleAssignment.Member.PrincipalType -in ("SecurityGroup","SharePointGroup")){
                if($roleAssignment.Member.LoginName -like "SharingLinks*"){
                    $sharingLinkInfo = $Null; $sharingLinkInfo = get-SpOSharingLinkInfo -sharingLinkGuid $roleAssignment.Member.LoginName.Split(".")[3]
                    if($sharingLinkInfo){
                        switch([Int]$sharingLinkInfo.LinkKind){
                            {$_ -in (2,3)}  { #Org wide
                                New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity @{Title = "All Internal Users";PrincipalType="ORG-WIDE"} -object $obj -permission $permissionLevel.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                            }                            
                            {$_ -in (4,5)}  { #Anonymous
                                New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity @{Title = "Anyone / Anonymous";PrincipalType="ANYONE"} -object $obj -permission $permissionLevel.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                            }                            
                            {$_ -in (1,6)}  { #direct, flexible
                                foreach($invitee in $sharingLinkInfo.invitees){
                                    New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity (get-spoInvitee -invitee $invitee -siteUrl $siteUrl) -object $obj -permission $permissionLevel.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                                }
                            }
                        }
                    }else{
                        New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $roleAssignment.Member -object $obj -permission $permissionLevel.Name -Through "SharingLink")
                    }                    
                }else{
                    if($expandGroups){
                        Get-PnPGroupMembers -Group $roleAssignment.Member -parentId $roleAssignment.Member.Id -siteConn (Get-SpOConnection -Type User -Url $siteUrl) | ForEach-Object {
                            if($_.PrincipalType -ne "User"){$through = "DirectAssignment"}else{$through = "GroupMembership"}
                            New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $_ -object $obj -permission $permissionLevel.Name -Through $through -parent $roleAssignment.Member.Title)
                        }
                    }else{
                        New-SpOPermissionEntry -Path $obj.Url -Permission (get-spopermissionEntry -entity $roleAssignment.Member -object $obj -permission $permissionLevel.Name -Through "DirectAssignment")
                    }
                }
            }else{
                Write-Error "Unknown type of permission assignment detected for $($roleAssignment.Member.Title) called $($roleAssignment.Member.PrincipalType)" -ErrorAction Continue
            }
        }   
    }

    #retrieve permissions for any (if present) child objects
    Switch($Object.TypedObject.ToString()){
        "Microsoft.SharePoint.Client.Web"  {     
            Write-Progress -Id 2 -PercentComplete 0 -Activity $($siteUrl.Split("/")[4]) -Status "Getting child objects..."
            $Null = Get-PnPProperty -ClientObject $Object -Property Webs -Connection (Get-SpOConnection -Type User -Url $siteUrl)
            $childObjects = $Null; $childObjects = $Object.Webs
            foreach($childObject in $childObjects){
                #check if permissions are unique
                Get-PnPProperty -ClientObject $childObject -Property HasUniqueRoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
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
            try{
                $global:sharedLinks = $Null;$global:sharedLinks = Get-PnPListItem -List $sharedLinksList.Id -PageSize 500 -Fields ID,AvailableLinks -Connection (Get-SpOConnection -Type User -Url $siteUrl) | ForEach-Object {
                    try{$_.FieldValues["AvailableLinks"] | ConvertFrom-Json }catch{$Null}
                }
            }catch{
                $global:sharedLinks
            }

            Write-Verbose "Cached $($sharedLinks.Count) shared links for $($Object.Title)..."

            $counter = 0
            ForEach($List in $childObjects){
                Update-StatisticsObject -Category $Category -Subject $siteUrl -Amount $List.ItemCount
                If($List.Hidden -eq $False -and $ExcludedListTitles -notcontains $List.Title -and $List.ItemCount -gt 0 -and $List.TemplateFeatureId -notin $ExcludedListFeatureIDs){
                    $counter++
                    Write-Progress -Id 2 -PercentComplete ($Counter / ($childObjects.Count) * 100) -Activity $($siteUrl.Split("/")[4]) -Status "'$($List.Title)': $($List.ItemCount) items (List $counter of $($childObjects.Count))"
                    #grab top level info of the list first
                    get-PnPObjectPermissions -Object $List -siteUrl $siteUrl -Category $Category

                    #check if permissions are unique
                    Get-PnPProperty -ClientObject $List -Property Title, HasUniqueRoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                    if($List.HasUniqueRoleAssignments -eq $False){
                        Write-Verbose "Skipping $($List.Title) List as it fully inherits permissions from parent"
                        continue
                    }     

                    $allUniqueListItems = @()
                    Write-Verbose "List contains $($List.ItemCount) items"
                    $allListItems = $Null; $allListItems = New-GraphQuery -resource "https://www.sharepoint.com" -Uri "$($Object.Url)/_api/web/lists/getbyid('$($List.Id.Guid)')/items?`$select=ID,HasUniqueRoleAssignments&`$top=5000&`$format=json" -Method GET -expectedTotalResults $List.ItemCount
                    $allUniqueListItemIDs = $Null; $allUniqueListItemIDs = @($allListItems | Where-Object { $_.HasUniqueRoleAssignments -eq $True }) | select -ExpandProperty Id
                    for($a=0;$a -lt $allUniqueListItemIDs.Count;$a++){
                        Write-Progress -Id 3 -PercentComplete ((($a+1) / $allUniqueListItemIDs.Count) * 100) -Activity "Processing Item $($a+1) of $($allUniqueListItemIDs.Count)" -Status "Getting Metadata for each Unique Item"
                        $allUniqueListItems += Get-PnPListItem -List $List.Id -Connection (Get-SpOConnection -Type User -Url $siteUrl) -Id $allUniqueListItemIDs[$a]
                    }

                    for($l=0;$l -lt $allUniqueListItems.Count;$l++){
                        Write-Progress -Id 3 -PercentComplete (($($l+1) / $allUniqueListItems.Count) * 100) -Activity "Processing Item $($l+1) of $($allUniqueListItems.Count)" -Status "Searching for Unique Permissions"
                        get-PnPObjectPermissions -Object $allUniqueListItems[$l] -siteUrl $siteUrl -Category $Category
                    }
                    Write-Progress -Id 3 -Completed -Activity "Processing Item $ItemCounter of $($allUniqueListItems.Count)"
                }else{
                    Write-Verbose "Skipping $($List.Title) as it is hidden, empty or excluded"
                }
            }
            Write-Progress -Id 2 -Completed -Activity $($siteUrl.Split("/")[4])            
        }  
    }      
}