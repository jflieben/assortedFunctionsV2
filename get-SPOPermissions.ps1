<#
.DESCRIPTION
Generates a full CSV report of all unique permissions assigned to all sharepoint online files, libraries and sites.
Based on Salaudeen Rajack's work at https://www.sharepointdiary.com/2019/09/sharepoint-online-user-permissions-audit-report-using-pnp-powershell.html but heavily modified to 
run a lot faster in a single thread and to automatically and fully report on all O365 group members and security group members using the Graph API.

It will use device based login to get all groups+members in your tenant, but you can switch this to SPN/cert or secret based if you want to e.g. schedule this script.

.NOTES
filename:           get-SPOPermissions.ps1
author:             Jos Lieben (Lieben Consultancy)
created:            09/09/2021
last updated:       09/09/2021
Copyright/License:  https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
credits:            Salaudeen Rajack for the base script

Before running this script, your account will need to have administrative rights to all sites you wish to audit. This is assigned and removed automatically, see line 451

To do:
https://www.lieben.nu/liebensraum/2021/09/sharepoint-permission-auditing/#comment-11551

#>
#Requires -modules PnP.PowerShell

$adminURL = "https://YOURTENANT-admin.sharepoint.com"
$siteIgnoreList = @("https://xxxx.sharepoint.com/sites/xxxx","https://xxxx.sharepoint.com/sites/xxxx") #in case you want to exclude specific sites from the report
$principalIgnoreList = @("blue@xxxx.onmicrosoft.com","red@xxx.onmicrosoft.com") #in case you want to exclude specific accounts from the report
$script:ReportFile = "C:\Temp\data.CSV" #report will be generated here

$userUPN = Read-Host -Prompt "Please type your login name"

$tenantId = (Invoke-RestMethod "https://login.windows.net/$($userUPN.Split("@")[1])/.well-known/openid-configuration" -Method GET).userinfo_endpoint.Split("/")[3]
$response = Invoke-RestMethod -Method POST -UseBasicParsing -Uri "https://login.microsoftonline.com/$tenantId/oauth2/devicecode" -ContentType "application/x-www-form-urlencoded" -Body "resource=https%3A%2F%2Fgraph.microsoft.com&client_id=d1ddf0e4-d672-4dae-b554-9d5bdfd93547"
Write-Output $response.message
$waited = 0
while($true){
    try{
        $authResponse = Invoke-RestMethod -uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -ContentType "application/x-www-form-urlencoded" -Method POST -Body "grant_type=device_code&resource=https%3A%2F%2Fgraph.microsoft.com&code=$($response.device_code)&client_id=d1ddf0e4-d672-4dae-b554-9d5bdfd93547" -ErrorAction Stop
        $refreshToken = $authResponse.refresh_token
        break
    }catch{
        if($waited -gt 300){
            Write-Verbose "No valid login detected within 5 minutes"
            Throw
        }
        #try again
        Start-Sleep -s 5
        $waited += 5
    }
}

$groupMetaCache = @{}
try{
    $allGroups = @()
    Write-Output "Parsing all group owners and members in the tenant"
    $groups = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups" -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}
    $allGroups += $groups.value
    while($groups.'@odata.nextLink'){
        $groups = Invoke-RestMethod -Uri $groups.'@odata.nextLink' -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}  
        $allGroups += $groups.value  
    }
    foreach($group in $allGroups){
        if(!$groupMetaCache.$($group.id)){
            $groupMetaCache.$($group.id) = @{"Owners"=@{};"Members"=@{}}
        }
        write-output "Parsing owners of $($group.id)"
        $owners = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners" -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}
        foreach($owner in $owners.value){
            if(!$groupMetaCache.$($group.id).Owners.$($owner.id)){
                $groupMetaCache.$($group.id).Owners.$($owner.id) = @{"mail"=$owner.mail;"id"=$owner.id}
            }
        }
        write-output "Parsing members of $($group.id)"
        $members = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members" -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}
        foreach($member in $members.value){
            if(!$groupMetaCache.$($group.id).Members.$($member.id)){
                $groupMetaCache.$($group.id).Members.$($member.id) = @{"mail"=$member.mail;"id"=$member.id}
            }
        }
        while($members.'@odata.nextLink'){
            $members = Invoke-RestMethod -Uri $members.'@odata.nextLink' -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}  
            foreach($member in $members.value){
                if(!$groupMetaCache.$($group.id).Members.$($member.id)){
                    $groupMetaCache.$($group.id).Members.$($member.id) = @{"mail"=$member.mail;"id"=$member.id}
                }
            } 
        }
    }
}catch{
    Throw $_
}

#Function to Get Permissions of All List Items of a given List
Function Get-PnPListItemsPermission(){
    Param(
        [Microsoft.SharePoint.Client.List]$List,
        $groupId
    )
    Write-host -f Yellow "`t `t Getting Permissions of List Items in the List:"$List.Title
  
    #Get All Items from List in batches
    $ListItems = Get-PnPListItem -List $List -PageSize 500 -Fields ID,Title,FileSystemObjectType,URL
    $ItemCounter = 0
    #Loop through each List item
    ForEach($ListItem in $ListItems){
        #Check if List Item has unique permissions (SharedWithUsers:SW| will exist and have a name/email or similar listed)
        If($ListItem.FieldValues.MetaInfo.Split([Environment]::NewLine) | Where{$_ -and $_.StartsWith("SharedWithUsers") -and $_.Length -gt 22}){
            #Call the function to generate Permission report
            Get-PnPPermissions -Object $ListItem -groupId $groupId
        }
        $ItemCounter++
        Write-Progress -Id 3 -PercentComplete ($ItemCounter / ($List.ItemCount) * 100) -Activity "Processing Item $ItemCounter of $($List.ItemCount)" -Status "Searching for Unique Permissions in list items of '$($List.Title)'"
    }
}
 
#Function to Get Permissions of all lists from the given web
Function Get-PnPListPermission(){
    Param(
        [Microsoft.SharePoint.Client.Web]$Web,
        $groupId
    )
    #Get All Lists from the web
    $Lists = Get-PnPProperty -ClientObject $Web -Property Lists
   
    #Exclude system lists
    $ExcludedLists = @("Access Requests","App Packages","appdata","appfiles","Apps in Testing","Cache Profiles","Composed Looks","Content and Structure Reports","Content type publishing error log","Converted Forms",
    "Device Channels","Form Templates","fpdatasources","Get started with Apps for Office and SharePoint","List Template Gallery", "Long Running Operation Status","Maintenance Log Library", "Images", "site collection images"
    ,"Master Docs","Master Page Gallery","MicroFeed","NintexFormXml","Quick Deploy Items","Relationships List","Reusable Content","Reporting Metadata", "Reporting Templates", "Search Config List","Site Assets","Preservation Hold Library",
    "Site Pages", "Solution Gallery","Style Library","Suggested Content Browser Locations","Theme Gallery", "TaxonomyHiddenList","User Information List","Web Part Gallery","wfpub","wfsvc","Workflow History","Workflow Tasks", "Pages")
             
    $Counter = 0
    #Get all lists from the web   
    ForEach($List in $Lists){
        #Exclude System Lists
        If($List.Hidden -eq $False -and $ExcludedLists -notcontains $List.Title){
            $Counter++
            Write-Progress -Id 2 -PercentComplete ($Counter / ($Lists.Count) * 100) -Activity "Exporting Permissions from List '$($List.Title)' in $($Web.URL)" -Status "Processing $($List.ItemCount) items from List $Counter of $($Lists.Count)"
 
            #Get Item Level Permissions
            If($List.ItemCount -gt 0){
                #Get List Items Permissions
                Get-PnPListItemsPermission -List $List -groupId $groupId
            }
 
            #Check if List has unique permissions
            $HasUniquePermissions = Get-PnPProperty -ClientObject $List -Property HasUniqueRoleAssignments
            If($HasUniquePermissions -eq $True){
                #Call the function to check permissions
                Get-PnPPermissions -Object $List -groupId $groupId
            }
        }
    }
}
   
#Function to Get Webs's Permissions from given URL
Function Get-PnPWebPermission(){
    Param(
        [Microsoft.SharePoint.Client.Web]$Web,
        $groupId
    )
    Write-host -f Yellow "Getting Permissions of the Web: $($Web.URL)..." 
    Get-PnPPermissions -Object $Web -groupId $groupId
   
    #Get List Permissions
    Write-host -f Yellow "`t Getting Permissions of Lists and Libraries..."
    Get-PnPListPermission $Web -groupId $groupId
 
    #Recursively get permissions from all sub-webs
    #Get Subwebs of the Web
    $Subwebs = Get-PnPProperty -ClientObject $Web -Property Webs
 
    #Iterate through each subsite in the current web
    Foreach ($Subweb in $web.Webs){
        #Check if the Web has unique permissions
        $HasUniquePermissions = Get-PnPProperty -ClientObject $SubWeb -Property HasUniqueRoleAssignments
   
        #Get the Web's Permissions
        If($HasUniquePermissions -eq $true){ 
            #Call the function recursively                            
            Get-PnPWebPermission -Web $Subweb -groupId $groupId
        }
    }
}

#Function to Get Permissions Applied on a particular Object, such as: Web, List, Folder or List Item
Function Get-PnPPermissions(){
    Param(
        [Microsoft.SharePoint.Client.SecurableObject]$Object,
        $groupId
    )

    #Get permissions assigned to the object
    Get-PnPProperty -ClientObject $Object -Property HasUniqueRoleAssignments, RoleAssignments
    #Check if Object has unique permissions
    if(!$Object.HasUniqueRoleAssignments -and $Object.TypedObject.ToString() -eq "Microsoft.SharePoint.Client.ListItem"){
        return $Null
    }
    $HasUniquePermissions = $Object.HasUniqueRoleAssignments

    #Determine the type of the object
    Switch($Object.TypedObject.ToString()){
        "Microsoft.SharePoint.Client.Web"  { $ObjectType = "Site" ; $ObjectURL = $Object.URL; $ObjectTitle = $Object.Title }
        "Microsoft.SharePoint.Client.ListItem"{ 
            If($Object.FileSystemObjectType -eq "Folder")
            {
                $ObjectType = "Folder"
                #Get the URL of the Folder 
                $Folder = Get-PnPProperty -ClientObject $Object -Property Folder
                $ObjectTitle = $Object.Folder.Name
                $ObjectURL = $("{0}{1}" -f $Web.Url.Replace($Web.ServerRelativeUrl,''),$Object.Folder.ServerRelativeUrl)
            }
            Else #File or List Item
            {
                #Get the URL of the Object
                Get-PnPProperty -ClientObject $Object -Property File, ParentList
                If($Object.File.Name -ne $Null)
                {
                    $ObjectType = "File"
                    $ObjectTitle = $Object.File.Name
                    $ObjectURL = $("{0}{1}" -f $Web.Url.Replace($Web.ServerRelativeUrl,''),$Object.File.ServerRelativeUrl)
                }
                else
                {
                    $ObjectType = "List Item"
                    $ObjectTitle = $Object["Title"]
                    #Get the URL of the List Item
                    $DefaultDisplayFormUrl = Get-PnPProperty -ClientObject $Object.ParentList -Property DefaultDisplayFormUrl                     
                    $ObjectURL = $("{0}{1}?ID={2}" -f $Web.Url.Replace($Web.ServerRelativeUrl,''), $DefaultDisplayFormUrl,$Object.ID)
                }
            }
        }
        Default{ 
            $ObjectType = "List or Library"
            $ObjectTitle = $Object.Title
            #Get the URL of the List or Library
            $RootFolder = Get-PnPProperty -ClientObject $Object -Property RootFolder     
            $ObjectURL = $("{0}{1}" -f $Web.Url.Replace($Web.ServerRelativeUrl,''), $RootFolder.ServerRelativeUrl)
        }
    }
     
    #Loop through each permission assigned and extract details
    $PermissionCollection = @()
    Foreach($RoleAssignment in $Object.RoleAssignments){ 
        #Get the Permission Levels assigned and Member
        Get-PnPProperty -ClientObject $RoleAssignment -Property RoleDefinitionBindings, Member
 
        #Get the Principal Type: User, SP Group, AD Group
        $PermissionType = $RoleAssignment.Member.PrincipalType
    
        #Get the Permission Levels assigned
        $PermissionLevels = $RoleAssignment.RoleDefinitionBindings | Select -ExpandProperty Name
 
        #Remove Limited Access
        $PermissionLevels = ($PermissionLevels | Where { $_ -ne "Limited Access"}) -join ","
 
        #Leave Principals with no Permissions
        If($PermissionLevels.Length -eq 0) {Continue}
 
        #Get SharePoint group members
        If($PermissionType -eq "SharePointGroup"){
            #limited access system group should be ignored as this just means 'clickthrough without read' permissions
            if($RoleAssignment.Member.LoginName -like "Limited Access System Group*"){
                continue
            }
            #Get Group Members
            $GroupMembers = Get-PnPGroupMember -Identity $RoleAssignment.Member.LoginName  | Where-Object {$_.LoginName -ne "SHAREPOINT\system"}
                 
            #Leave Empty Groups
            If($GroupMembers.count -eq 0){Continue}
            foreach($member in $GroupMembers){
                if($member.Email -and $principalIgnoreList -contains $member.Email){
                    continue
                }
                #Office 365 group owners need to be retrieved from AzureAD
                if($groupId -and $member.LoginName -like "*$($groupId)*" -and $RoleAssignment.Member.LoginName.EndsWith("Owners")){
                    $owners = $groupMetaCache.$groupId.Owners.Keys
                    foreach($owner in $owners){
                        $Permissions = New-Object PSObject
                        $Permissions | Add-Member NoteProperty Object($ObjectType)
                        $Permissions | Add-Member NoteProperty Title($ObjectTitle)
                        $Permissions | Add-Member NoteProperty URL($ObjectURL)
                        $Permissions | Add-Member NoteProperty HasUniquePermissions($HasUniquePermissions)
                        if($groupMetaCache.$groupId.Owners.$($owner).mail){
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupId.Owners.$($owner).mail)
                        }else{
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupId.Owners.$($owner).id)
                        }
                        $Permissions | Add-Member NoteProperty Type("O365GroupOwners")
                        $Permissions | Add-Member NoteProperty Permissions($PermissionLevels)
                        $Permissions | Add-Member NoteProperty GrantedThrough("O365 Linked Group: $groupId")
                        $PermissionCollection += $Permissions   
                    }
                }
                #nested AAD group
                ElseIf($member.PrincipalType -eq "SecurityGroup" -and $member.LoginName.Split("|")[2]){
                    $groupGuid = $member.LoginName.Split("|")[2]
                    $aadMembers = $groupMetaCache.$groupGuid.Members.Keys
                    foreach($aadMember in $aadMembers){
                        $Permissions = New-Object PSObject
                        $Permissions | Add-Member NoteProperty Object($ObjectType)
                        $Permissions | Add-Member NoteProperty Title($ObjectTitle)
                        $Permissions | Add-Member NoteProperty URL($ObjectURL)
                        $Permissions | Add-Member NoteProperty HasUniquePermissions($HasUniquePermissions)
                        if($groupMetaCache.$groupGuid.Members.$($aadMember).mail){
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupGuid.Members.$($aadMember).mail)
                        }else{
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupGuid.Members.$($aadMember).id)
                        }
                        $Permissions | Add-Member NoteProperty Type("AADSecurityGroup")
                        $Permissions | Add-Member NoteProperty Permissions($PermissionLevels)
                        if($RoleAssignment.Member.Title){
                            $Permissions | Add-Member NoteProperty GrantedThrough("AAD Group: $($RoleAssignment.Member.Title)")
                        }else{
                            $Permissions | Add-Member NoteProperty GrantedThrough("AAD Group: $groupGuid")
                        }
                        $PermissionCollection += $Permissions   
                    }
                } 
                #Office 365 group members also need to be retrieved from AzureAD
                elseif($groupId -and $member.LoginName -like "*$($groupId)*" -and $RoleAssignment.Member.LoginName.EndsWith("Members")){
                    $aadMembers = $groupMetaCache.$groupId.Members.Keys
                    foreach($aadMember in $aadMembers){
                        $Permissions = New-Object PSObject
                        $Permissions | Add-Member NoteProperty Object($ObjectType)
                        $Permissions | Add-Member NoteProperty Title($ObjectTitle)
                        $Permissions | Add-Member NoteProperty URL($ObjectURL)
                        $Permissions | Add-Member NoteProperty HasUniquePermissions($HasUniquePermissions)
                        if($groupMetaCache.$groupId.Members.$($aadMember).mail){
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupId.Members.$($aadMember).mail)
                        }else{
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupId.Members.$($aadMember).id)
                        }
                        $Permissions | Add-Member NoteProperty Type("O365GroupMembers")
                        $Permissions | Add-Member NoteProperty Permissions($PermissionLevels)
                        $Permissions | Add-Member NoteProperty GrantedThrough("O365 Linked Group: $groupId")
                        $PermissionCollection += $Permissions   
                    }
                }
                else{
                    $Permissions = New-Object PSObject
                    $Permissions | Add-Member NoteProperty Object($ObjectType)
                    $Permissions | Add-Member NoteProperty Title($ObjectTitle)
                    $Permissions | Add-Member NoteProperty URL($ObjectURL)
                    $Permissions | Add-Member NoteProperty HasUniquePermissions($HasUniquePermissions)
                    if($member.Email){
                        $Permissions | Add-Member NoteProperty User($member.Email)
                    }else{
                        $Permissions | Add-Member NoteProperty User($member.Title)
                    }
                    $Permissions | Add-Member NoteProperty Type($PermissionType)
                    $Permissions | Add-Member NoteProperty Permissions($PermissionLevels)
                    $Permissions | Add-Member NoteProperty GrantedThrough("SharePoint Group: $($RoleAssignment.Member.LoginName)")
                    $PermissionCollection += $Permissions                    
                }
            }
        }
        #Get Azure AD group members
        ElseIf($PermissionType -eq "SecurityGroup" -and $RoleAssignment.Member.LoginName.Split("|")[2]){
            $groupGuid = $RoleAssignment.Member.LoginName.Split("|")[2]
            $aadMembers = $groupMetaCache.$groupGuid.Members.Keys
            foreach($aadMember in $aadMembers){
                $Permissions = New-Object PSObject
                $Permissions | Add-Member NoteProperty Object($ObjectType)
                $Permissions | Add-Member NoteProperty Title($ObjectTitle)
                $Permissions | Add-Member NoteProperty URL($ObjectURL)
                $Permissions | Add-Member NoteProperty HasUniquePermissions($HasUniquePermissions)
                if($groupMetaCache.$groupGuid.Members.$($aadMember).mail){
                    $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupGuid.Members.$($aadMember).mail)
                }else{
                    $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupGuid.Members.$($aadMember).id)
                }
                $Permissions | Add-Member NoteProperty Type("AADSecurityGroup")
                $Permissions | Add-Member NoteProperty Permissions($PermissionLevels)
                if($RoleAssignment.Member.Title){
                    $Permissions | Add-Member NoteProperty GrantedThrough("AAD Group: $($RoleAssignment.Member.Title)")
                }else{
                    $Permissions | Add-Member NoteProperty GrantedThrough("AAD Group: $groupGuid")
                }
                $PermissionCollection += $Permissions   
            }
        }        
        Else{
            $Permissions = New-Object PSObject
            $Permissions | Add-Member NoteProperty Object($ObjectType)
            $Permissions | Add-Member NoteProperty Title($ObjectTitle)
            $Permissions | Add-Member NoteProperty URL($ObjectURL)
            $Permissions | Add-Member NoteProperty HasUniquePermissions($HasUniquePermissions)
            if($RoleAssignment.Member.Email){
                $Permissions | Add-Member NoteProperty User($RoleAssignment.Member.Email)
            }elseif($RoleAssignment.Member.LoginName){
                $Permissions | Add-Member NoteProperty User($RoleAssignment.Member.LoginName)
            }else{
                $Permissions | Add-Member NoteProperty User($RoleAssignment.Member.Title)
            }
            $Permissions | Add-Member NoteProperty Type($PermissionType)
            $Permissions | Add-Member NoteProperty Permissions($PermissionLevels)
            $Permissions | Add-Member NoteProperty GrantedThrough("Direct Permissions")
            $PermissionCollection += $Permissions
        }
    }
    #Export Permissions to CSV File
    $PermissionCollection | Export-CSV $ReportFile -NoTypeInformation -Append
}
   
#Function to get sharepoint online site permissions report
Function Generate-PnPSitePermissionRpt(){
[cmdletbinding()]
    Param 
    (    
        [Parameter(Mandatory=$false)] [String] $SiteURL,     
        [String]$groupId      
    )  
    Try {
        Connect-PnPOnline -URL $SiteURL -UseWebLogin
        
        $Web = Get-PnPWeb
 
        Write-host -f Yellow "Getting Site Collection Administrators..."
        $SiteAdmins = Get-PnPSiteCollectionAdmin
         
        if($SiteAdmins){
            foreach($SiteCollectionAdmin in $SiteAdmins){
                if($SiteCollectionAdmin.Email -and $principalIgnoreList -contains $SiteCollectionAdmin.Email){
                    continue
                }
                if($groupId -and $SiteCollectionAdmin.LoginName -like "*$($groupId)*" -and $SiteCollectionAdmin.Title.EndsWith("Owners")){
                    $owners = $groupMetaCache.$groupId.Owners.Keys
                    foreach($owner in $owners){
                        $Permissions = New-Object PSObject
                        $Permissions | Add-Member NoteProperty Object("Site Collection")
                        $Permissions | Add-Member NoteProperty Title($Web.Title)
                        $Permissions | Add-Member NoteProperty URL($Web.URL)
                        $Permissions | Add-Member NoteProperty HasUniquePermissions("TRUE")
                        if($groupMetaCache.$groupId.Owners.$($owner).mail){
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupId.Owners.$($owner).mail)
                        }else{
                            $Permissions | Add-Member NoteProperty User($groupMetaCache.$groupId.Owners.$($owner).id)
                        }
                        $Permissions | Add-Member NoteProperty Type("O365GroupOwners")
                        $Permissions | Add-Member NoteProperty Permissions("Site Owner")
                        $Permissions | Add-Member NoteProperty GrantedThrough("O365 Linked Group: $groupId")
                        $Permissions | Export-CSV $ReportFile -NoTypeInformation -Append
                    }
                }else{
                    $Permissions = New-Object PSObject
                    $Permissions | Add-Member NoteProperty Object("Site Collection")
                    $Permissions | Add-Member NoteProperty Title($Web.Title)
                    $Permissions | Add-Member NoteProperty URL($Web.URL)
                    $Permissions | Add-Member NoteProperty HasUniquePermissions("TRUE")
                    if($SiteCollectionAdmin.Email){
                        $Permissions | Add-Member NoteProperty User($SiteCollectionAdmin.Email)
                    }else{
                        $Permissions | Add-Member NoteProperty User($SiteCollectionAdmin.Title)
                    }
                    $Permissions | Add-Member NoteProperty Type("Site Collection Administrators")
                    $Permissions | Add-Member NoteProperty Permissions("Site Owner")
                    $Permissions | Add-Member NoteProperty GrantedThrough("Direct Permissions")
                    $Permissions | Export-CSV $ReportFile -NoTypeInformation -Append
                }
            }
        }

        #Call the function with RootWeb to get site collection permissions
        Get-PnPWebPermission -Web $Web -groupId $groupId
        Write-host -f Green "`n*** Site Permission Report Generated Successfully!***"
     }Catch {
        write-host -f Red "Error Generating Site Permission Report!" $_.Exception.Message
   }
}

Connect-PnPOnline -Url $adminURL -UseWebLogin
Connect-SPOService -Url $adminURL

#Get All Site collections - Exclude: Seach Center, Mysite Host, App Catalog, Content Type Hub, eDiscovery and Bot Sites
$SitesCollections = Get-PnPTenantSite -IncludeOneDriveSites | Where -Property Template -NotIn ("SRCHCEN#0", "SPSMSITEHOST#0", "APPCATALOG#0", "POINTPUBLISHINGHUB#0", "EDISC#0", "STS#-1") | Where -Property Url -NotIn $siteIgnoreList

For($s=0; $s -lt $SitesCollections.Count; $s++){
    Write-Progress -Id 1 -PercentComplete ($s / ($SitesCollections.Count) * 100) -Activity "Exporting Permissions from Site '$($SitesCollections[$s].Url)'" -Status "Processing site $s of $($SitesCollections.Count)"
    $SiteConn = Connect-PnPOnline -Url $SitesCollections[$s].Url -UseWebLogin
    Set-SPOUser -Site $SitesCollections[$s].Url -LoginName $userUPN -IsSiteCollectionAdmin $true
    Start-Sleep -s 5
    Write-host "Generating Report for Site:"$SitesCollections[$s].Url
    if($SitesCollections[$s].GroupId.Guid -eq "00000000-0000-0000-0000-000000000000"){
        $groupId = $Null
    }else{
        $groupId = $SitesCollections[$s].GroupId.Guid
    }
    Generate-PnPSitePermissionRpt -SiteURL $SitesCollections[$s].URL -groupId $groupId
    
}


For($s=0; $s -lt $SitesCollections.Count; $s++){
    Remove-SPOUser -Site $SitesCollections[$s].Url -LoginName $userUPN
}

For($s=0; $s -lt $SitesCollections.Count; $s++){
    Get-PnPSiteCollectionAdmin | where {$_.LoginName.EndsWith($userUPN)} | Remove-PnPSiteCollectionAdmin
}