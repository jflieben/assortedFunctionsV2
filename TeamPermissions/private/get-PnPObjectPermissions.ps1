Function get-PnPObjectPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)][Microsoft.SharePoint.Client.SecurableObject]$Object,
        $siteUrl
    )

    $ignoreablePermissions = @("Guest","RestrictedGuest","None")
    $global:statObj."Total objects scanned"++

    $obj = [PSCustomObject]@{
        "Title" = $null
        "Type" = $null
        "Url" = $Null
    }    

    Switch($Object.TypedObject.ToString()){
        "Microsoft.SharePoint.Client.Web"  { 
            $siteUrl = "https://$($Object.Url.Split("/")[2..4] -join "/")"
            $obj.Title = $Object.Title
            $obj.Url = $Object.Url
            $obj.Type = "Site"
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
        }
    }    

    #retrieve all permissions for the supplied object
    Get-PnPProperty -ClientObject $Object -Property HasUniqueRoleAssignments, RoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)    
    if(!$global:performanceDebug -and $Object.HasUniqueRoleAssignments -eq $False){
        Write-Verbose "Skipping $($obj.Title) as it fully inherits permissions from parent"
        continue
    }

    #sharepoint libraries / subsites etc do not list root level owner permissions, but we should still add them since those always trickle down
    if($Object.TypedObject.ToString() -ne "Microsoft.SharePoint.Client.ListItem"){
        foreach($folder in $($global:permissions.Keys)){
            if($obj.Url.Contains($folder)){
                foreach($permission in $global:permissions.$folder){
                    if($Permission.Object -eq "root"){
                        Write-Verbose "Added: $($rootPermission.Permission) for $($rootPermission.Name) because of forced inheritance through the site root"
                        New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -entity @{Email = $Permission.Email; LoginName = $Permission.Identity;Title = $Permission.Name;PrincipalType=$Permission.Type} -object $obj -permission $Permission.Permission -Through "ForcedInheritance" -parent $folder)
                    }
                }
            }
        }
    }
    
    Foreach($roleAssignment in $Object.RoleAssignments){
        Get-PnPProperty -ClientObject $roleAssignment -Property RoleDefinitionBindings, Member -Connection (Get-SpOConnection -Type User -Url $siteUrl)
        
        foreach($permissionLevel in $roleAssignment.RoleDefinitionBindings){
            Write-Verbose "Detected: $($roleAssignment.Member.Title) $($permissionLevel.Name) ($($permissionLevel.RoleTypeKind))"
            if($ignoreablePermissions -contains $permissionLevel.RoleTypeKind){
                Write-Verbose "Ignoring $($permissionLevel.Name) permission type for $($roleAssignment.Member.Title) because it is only relevant at a deeper level"
                continue
            }
            if($roleAssignment.Member.PrincipalType -eq "User"){
                New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -entity $roleAssignment.Member -object $obj -permission $permissionLevel.Name -Through "DirectAssignment")
            }elseif($roleAssignment.Member.PrincipalType -in ("SecurityGroup","SharePointGroup")){
                if($roleAssignment.Member.LoginName -like "SharingLinks*"){
                    $sharingLinkInfo = $Null; $sharingLinkInfo = get-SharingLinkinfo -sharingLinkGuid $roleAssignment.Member.LoginName.Split(".")[3]
                    if($sharingLinkInfo){
                        switch([Int]$sharingLinkInfo.LinkKind){
                            {$_ -in (2,3)}  { #Org wide
                                New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity @{Title = "All Internal Users";PrincipalType="ORG-WIDE"} -object $obj -permission $permissionLevel.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                            }                            
                            {$_ -in (4,5)}  { #Anonymous
                                New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity @{Title = "Anyone / Anonymous";PrincipalType="ANYONE"} -object $obj -permission $permissionLevel.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                            }                            
                            {$_ -in (1,6)}  { #direct, flexible
                                foreach($invitee in $sharingLinkInfo.invitees){
                                    New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -linkCreationDate $sharingLinkInfo.CreatedDate -linkExpirationDate $sharingLinkInfo.ExpirationDateTime -entity (get-Invitee -invitee $invitee -siteUrl $siteUrl) -object $obj -permission $permissionLevel.Name -Through "SharingLink" -parent "LinkId: $($sharingLinkInfo.ShareId)")
                                }
                            }
                        }
                    }else{
                        New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -entity $roleAssignment.Member -object $obj -permission $permissionLevel.Name -Through "SharingLink")
                    }                    
                }else{
                    if($expandGroups){
                        Get-PnPGroupMembers -Group $roleAssignment.Member -parentId $roleAssignment.Member.Id -siteConn (Get-SpOConnection -Type User -Url $siteUrl) | ForEach-Object {
                            if($_.PrincipalType -ne "User"){$through = "DirectAssignment"}else{$through = "GroupMembership"}
                            New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -entity $_ -object $obj -permission $permissionLevel.Name -Through $through -parent $roleAssignment.Member.Title)
                        }
                    }else{
                        New-PermissionEntry -Path $obj.Url -Permission (get-permissionEntry -entity $roleAssignment.Member -object $obj -permission $permissionLevel.Name -Through "DirectAssignment")
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
            Get-PnPProperty -ClientObject $Object -Property Webs -Connection (Get-SpOConnection -Type User -Url $siteUrl)
            $childObjects = $Null; $childObjects = $Object.Webs
            foreach($childObject in $childObjects){
                #check if permissions are unique
                Get-PnPProperty -ClientObject $childObject -Property HasUniqueRoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                if(!$global:performanceDebug -and $childObject.HasUniqueRoleAssignments -eq $False){
                    Write-Verbose "Skipping $($childObject.Title) child web as it fully inherits permissions from parent"
                    continue
                }                
                Write-Verbose "Enumerating permissions for sub web $($childObject.Title)..."
                get-PnPObjectPermissions -Object $childObject
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
                If($List.Hidden -eq $False -and $ExcludedListTitles -notcontains $List.Title -and $List.ItemCount -gt 0 -and $List.TemplateFeatureId -notin $ExcludedListFeatureIDs){
                    $counter++
                    Write-Progress -Id 2 -PercentComplete ($Counter / ($childObjects.Count) * 100) -Activity "Exporting Permissions from List '$($List.Title)' in $($Object.URL)" -Status "Processing $($List.ItemCount) items from List $counter of $($childObjects.Count)"
                    #grab top level info of the list first
                    get-PnPObjectPermissions -Object $List -siteUrl $siteUrl

                    #check if permissions are unique
                    Get-PnPProperty -ClientObject $List -Property Title, HasUniqueRoleAssignments -Connection (Get-SpOConnection -Type User -Url $siteUrl)
                    if(!$global:performanceDebug -and $List.HasUniqueRoleAssignments -eq $False){
                        Write-Verbose "Skipping $($List.Title) List as it fully inherits permissions from parent"
                        continue
                    }     

                    #Get unique child items in the list and iterate over them
                    $csomContext = (Get-SpOConnection -Type User -Url $siteUrl).Context
                    $csomList = $csomContext.Web.Lists.GetById($List.Id)
                    $csomContext.Load($csomList)
                    $csomContext.ExecuteQuery()
                    $camlQuery = New-Object Microsoft.SharePoint.Client.CamlQuery
                    $camlQuery.ViewXml = "
                    <Query><Where>
                          <Eq>
                             <FieldRef Name='HasUniqueRoleAssignments'/>
                             <Value Type='Boolean'>1</Value>
                          </Eq>
                    </Where></Query>
                    "
                    $allUniqueListItems = @()
                    $camlQuery.ListItemCollectionPosition = $null
                    do {
                        $uniqueListItems = $Null; $uniqueListItems = $csomList.GetItems($camlQuery)
                        $csomContext.Load($uniqueListItems)
                        $csomContext.ExecuteQuery()
                        $allUniqueListItems += $uniqueListItems
                        $camlQuery.ListItemCollectionPosition = $uniqueListItems.ListItemCollectionPosition
                    } while ($Null -ne $camlQuery.ListItemCollectionPosition)    

                    $ItemCounter = 0
                    ForEach($ListItem in $uniqueListItems){
                        $ItemCounter++
                        Write-Progress -Id 3 -PercentComplete ($ItemCounter / ($uniqueListItems.Count) * 100) -Activity "Processing Item $ItemCounter of $($uniqueListItems.ItemCount)" -Status "Searching for Unique Permissions in list items of '$($List.Title)'"
                        get-PnPObjectPermissions -Object $ListItem -siteUrl $siteUrl
                    }
                }else{
                    Write-Verbose "Skipping $($List.Title) as it is hidden, empty or excluded"
                }
            }
        }  
    }      
}