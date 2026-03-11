#Requires -Version 7.0

<#
.SYNOPSIS
    Reconfigures all sharing links under one or more SharePoint sites, or for specific document URLs, to a desired role (e.g., View-only).
    
    Author: Jos Lieben
    Blog: https://www.lieben.nu
    License: Free to use but keep the header intact and give credit.
    Disclaimer: Use at your own risk. Test in a non-production environment first. The script uses direct REST API calls and may have side effects if misused or used in an unexpected situation.
    I've tested the script against a variety of link types, but there may be edge cases or specific configurations I did not account for.

.DESCRIPTION
    This script connects to SharePoint Online using certificate-based app authentication and
    iterates through sharing links to update their role/permission level.

    You can supply either:
      - An array of site URLs: the script will enumerate ALL document libraries and ALL items
        in each site and update every sharing link found.
      - An array of item URLs (full URLs to individual documents or folders): the script will
        resolve each URL to its list and item, then update sharing links. If the URL points to
        a folder, the folder itself and all items within it are processed recursively.

    These two modes are mutually exclusive (parameter sets).

.PARAMETER TenantId
    Azure AD / Entra tenant ID (GUID).

.PARAMETER ClientId
    Azure AD / Entra app registration client ID (GUID).

.PARAMETER PfxPath
    Path to the PFX certificate file used for client-assertion authentication.
    Mutually exclusive with CertThumbprint.

.PARAMETER PfxPassword
    (Optional) Password for the PFX file. If omitted, an empty password is assumed.

.PARAMETER CertThumbprint
    Thumbprint of a certificate already installed in the local certificate store
    (Cert:\CurrentUser\My or Cert:\LocalMachine\My). Mutually exclusive with PfxPath.

.PARAMETER SiteUrls
    An array of SharePoint site URLs. All items in all document libraries of each site will be processed.

.PARAMETER ItemUrls
    An array of full URLs to individual documents or folders inside a document library
    (e.g., https://contoso.sharepoint.com/sites/hr/Shared Documents/report.docx or
    https://contoso.sharepoint.com/sites/hr/Shared Documents/MyFolder).
    If a URL points to a folder, all items within it are processed recursively.

.PARAMETER TargetRole
    The role to set on every sharing link found. Valid values are
    View, Edit, Review, NoDownload

.PARAMETER ExistingRole
    The role to replace If specified, only sharing links that currently have this role will be updated to the TargetRole.
    View, Edit, Review, NoDownload

.EXAMPLE
    .\Update-SharingLinks.ps1 -TenantId "ab77..." -ClientId "fa17..." -PfxPath ".\cert.pfx" -SiteUrls "https://contoso.sharepoint.com/sites/marketing"

    Updates ALL sharing links across every item in the marketing site to View-only.

.EXAMPLE
    .\Update-SharingLinks.ps1 -TenantId "ab77..." -ClientId "fa17..." -CertThumbprint "A1B2C3D4..." `
        -SiteUrls "https://contoso.sharepoint.com/sites/marketing" -TargetRole View

    Uses a certificate from the local store instead of a PFX file.

.EXAMPLE
    .\Update-SharingLinks.ps1 -TenantId "ab77..." -ClientId "fa17..." -PfxPath ".\cert.pfx" `
        -ItemUrls "https://contoso.sharepoint.com/sites/sales/Shared Documents/proposal.pdf" -TargetRole View

    Updates sharing links for the specific document.

.EXAMPLE
    .\Update-SharingLinks.ps1 -TenantId "ab77..." -ClientId "fa17..." -PfxPath ".\cert.pfx" `
        -ItemUrls "https://contoso.sharepoint.com/sites/sales/Shared Documents/Reports" -TargetRole View -ExistingRole Edit

    Recursively updates Edit sharing links for every item inside the Reports folder.

.NOTES
    Requires: An Azure AD app registration with Sites.FullControl.All (or equivalent) application
    permission against Sharepoint and a valid certificate. This script uses raw REST APIs.
    Certain types of links cannot be edited (even through the portal) and will be skipped without warning.
#>

param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory, ParameterSetName = 'BySite_Pfx')]
    [Parameter(Mandatory, ParameterSetName = 'ByItem_Pfx')]
    [string]$PfxPath,
    [Parameter(ParameterSetName = 'BySite_Pfx')]
    [Parameter(ParameterSetName = 'ByItem_Pfx')]
    [string]$PfxPassword,
    [Parameter(Mandatory, ParameterSetName = 'BySite_Thumb')]
    [Parameter(Mandatory, ParameterSetName = 'ByItem_Thumb')]
    [string]$CertThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'BySite_Pfx')]
    [Parameter(Mandatory, ParameterSetName = 'BySite_Thumb')]
    [string[]]$SiteUrls,
    [Parameter(Mandatory, ParameterSetName = 'ByItem_Pfx')]
    [Parameter(Mandatory, ParameterSetName = 'ByItem_Thumb')]
    [string[]]$ItemUrls,
    [Parameter(Mandatory)]
    [ValidateSet('View','Edit','Review', 'NoDownload')]
    [string]$TargetRole,
    [ValidateSet('View','Edit','Review', 'NoDownload')]
    [string]$ExistingRole    
)

if($ExistingRole -and $ExistingRole -eq $TargetRole){
    Write-Host "Existing role is the same as target role ($TargetRole). No changes will be made." -ForegroundColor Green
    exit 0
}

#region --- Authentication helpers ---

# Load certificate from PFX file or local certificate store
if ($CertThumbprint) {
    $cert = Get-Item "Cert:\CurrentUser\My\$CertThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) {
        $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction SilentlyContinue
    }
    if (-not $cert) {
        throw "Certificate with thumbprint '$CertThumbprint' not found in CurrentUser\My or LocalMachine\My."
    }
    if (-not $cert.HasPrivateKey) {
        throw "Certificate with thumbprint '$CertThumbprint' does not have a private key."
    }
} elseif ($PfxPassword) {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $PfxPath, $PfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
    )
} else {
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $PfxPath, [string]::Empty,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
    )
}

function Get-ClientAssertionJwt {
    param(
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$TenantId,
        [string]$ClientId
    )
    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $thumbprint = [Convert]::ToBase64String($Certificate.GetCertHash()) -replace '\+','-' -replace '/','_' -replace '='
    $header = @{ alg = "RS256"; typ = "JWT"; x5t = $thumbprint } | ConvertTo-Json -Compress
    $headerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($header)) -replace '\+','-' -replace '/','_' -replace '='

    $now = [DateTimeOffset]::UtcNow
    $payload = @{
        aud = $tokenEndpoint; iss = $ClientId; sub = $ClientId
        jti = [Guid]::NewGuid().ToString()
        nbf = $now.ToUnixTimeSeconds(); exp = $now.AddMinutes(10).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
    $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)) -replace '\+','-' -replace '/','_' -replace '='

    $dataToSign = [Text.Encoding]::UTF8.GetBytes("$headerB64.$payloadB64")
    $rsa = $Certificate.PrivateKey -as [System.Security.Cryptography.RSA]
    if (-not $rsa) {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    }
    $sig = $rsa.SignData($dataToSign, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = [Convert]::ToBase64String($sig) -replace '\+','-' -replace '/','_' -replace '='
    return "$headerB64.$payloadB64.$sigB64"
}

# Token cache keyed by tenant-scoped resource
$script:tokenCache = @{}

function Get-AppToken {
    param([string]$Scope)
    if ($script:tokenCache[$Scope]) { return $script:tokenCache[$Scope] }
    $jwt = Get-ClientAssertionJwt -Certificate $cert -TenantId $TenantId -ClientId $ClientId
    $body = @{
        client_id = $ClientId; scope = $Scope
        client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        client_assertion = $jwt; grant_type = "client_credentials"
    }
    $response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $body -ContentType "application/x-www-form-urlencoded"
    $script:tokenCache[$Scope] = $response.access_token
    return $response.access_token
}

function Get-SpoHeaders {
    param([string]$SiteUrl)
    $tenantName = ([Uri]$SiteUrl).Host.Split('.')[0]
    $token = Get-AppToken -Scope "https://$tenantName.sharepoint.com/.default"
    return @{
        Authorization  = "Bearer $token"
        Accept         = "application/json;odata=verbose"
        "Content-Type" = "application/json;odata=verbose"
    }
}

#endregion

#region --- Core functions ---

function Update-SharingLinksForItem {
    param(
        [string]$SiteUrl,
        [string]$ListId,
        [int]$ItemId,
        [hashtable]$Headers,
        [int]$Role
    )

    $sharingInfoUrl = "$SiteUrl/_api/web/Lists(@a1)/GetItemById(@a2)/GetSharingInformation?@a1='$ListId'&@a2='$ItemId'&`$Select=permissionsInformation&`$Expand=permissionsInformation"
    $sharingBody = '{"request":{"maxPrincipalsToReturn":100,"maxLinkMembersToReturn":100}}'

    try {
        $sharingInfo = Invoke-RestMethod -Uri $sharingInfoUrl -Headers $Headers -Method POST -Body $sharingBody
    } catch {
        Write-Warning "  Could not get sharing info for List $ListId, Item $ItemId : $_"
        return
    }

    $sharingLinks = $sharingInfo.d.permissionsInformation.links.results.linkDetails
    if (-not $sharingLinks) { return }

    foreach ($sharingLink in $sharingLinks) {
        if (-not $sharingLink.ShareId -or $sharingLink.ShareId -eq "00000000-0000-0000-0000-000000000000") {
            continue
        }

        $currentRole = 1
        if($sharingLink.BlocksDownload){
            $currentRole = 7
        }elseif($sharingLink.IsReviewLink){
            $currentRole = 6
        }elseif($sharingLink.IsEditLink){
            $currentRole = 2
        }

        if($currentRole -eq $Role){
            Write-Host "    Not updating link $($sharingLink.ShareId) (current role $currentRole = $Role)" -ForegroundColor Green    
            continue
        }elseif($ExistingRole -and $currentRole -ne $ExistingRoleId){
            Write-Host "    Not updating link $($sharingLink.ShareId) (current role $currentRole does not match specified ExistingRole $ExistingRole)" -ForegroundColor Green 
            continue            
        }else{
            Write-Host "    Updating link $($sharingLink.ShareId) (current role $currentRole -> $Role)" -ForegroundColor Yellow
        }

        $body = @{
            request = @{
                createLink = $true
                settings   = @{
                    linkKind               = $sharingLink.LinkKind
                    expiration             = $sharingLink.Expiration
                    role                   = $Role
                    restrictShareMembership = $sharingLink.RestrictedShareMembership
                    shareId                = $sharingLink.ShareId
                    scope                  = $sharingLink.Scope
                    nav                    = ""
                }
                emailData = @{ body = "" }
            }
        }

        try {
            Invoke-RestMethod -Uri "$SiteUrl/_api/web/Lists(@a1)/GetItemById(@a2)/ShareLink?@a1='$ListId'&@a2='$ItemId'" `
                -Headers $Headers -Method POST -Body ($body | ConvertTo-Json -Depth 5) | Out-Null
            Write-Host "    Link $($sharingLink.ShareId) updated." -ForegroundColor Green
        } catch {
            Write-Warning "    Failed to update link $($sharingLink.ShareId): $_"
        }
    }
}

function Resolve-ItemUrl {
    <#
    .SYNOPSIS
        Resolves a full document or folder URL to SiteUrl, ListId, ItemId, and whether it is a folder.
    #>
    param([string]$DocumentUrl)

    # Determine site URL by calling the RemoteItem endpoint or _api/Site
    $uri = [Uri]$DocumentUrl
    $tenantName = $uri.Host.Split('.')[0]
    $headers = Get-SpoHeaders -SiteUrl "https://$($uri.Host)"

    # Use the contextinfo approach: call GetFileByServerRelativePath to resolve the file
    # First we need the site URL. Try progressively shorter paths to find the site.
    $pathSegments = $uri.AbsolutePath.TrimEnd('/').Split('/')
    $siteUrl = $null

    # Typical patterns: /sites/SiteName or /teams/SiteName or root /
    for ($i = [Math]::Min($pathSegments.Count - 1, 3); $i -ge 0; $i--) {
        $candidatePath = ($pathSegments[0..$i] -join '/').TrimEnd('/')
        $candidateUrl = "https://$($uri.Host)$candidatePath"
        try {
            $null = Invoke-RestMethod -Uri "$candidateUrl/_api/web/Id" -Headers $headers -Method GET -ErrorAction Stop
            $siteUrl = $candidateUrl
            break
        } catch {
            continue
        }
    }

    if (-not $siteUrl) {
        Write-Warning "Could not resolve site URL for $DocumentUrl"
        return $null
    }

    $headers = Get-SpoHeaders -SiteUrl $siteUrl
    $serverRelativeUrl = $uri.AbsolutePath

    # Try resolving as a file first
    try {
        $fileInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFileByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields?`$select=Id" -Headers $headers -Method GET
        if($fileInfo -and $fileInfo.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
            $fileInfo = $fileInfo | ConvertFrom-Json -AsHashtable
        }    
        $itemId = $fileInfo.d.Id

        $listInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFileByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields/ParentList?`$select=Id" -Headers $headers -Method GET
        $listId = $listInfo.d.Id

        return @{
            SiteUrl  = $siteUrl
            ListId   = $listId
            ItemId   = [int]$itemId
            IsFolder = $false
        }
    } catch {
        # Not a file — try as a folder
    }

    # Try resolving as a folder
    try {
        $folderInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields?`$select=Id" -Headers $headers -Method GET
        if($folderInfo -and $folderInfo.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
            $folderInfo = $folderInfo | ConvertFrom-Json -AsHashtable
        }          
        $itemId = $folderInfo.d.Id

        $listInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields/ParentList?`$select=Id" -Headers $headers -Method GET
        $listId = $listInfo.d.Id

        return @{
            SiteUrl              = $siteUrl
            ListId               = $listId
            ItemId               = [int]$itemId
            IsFolder             = $true
            FolderRelativeUrl    = $serverRelativeUrl
        }
    } catch {
        Write-Warning "Could not resolve '$DocumentUrl' as a file or folder: $_"
        return $null
    }
}

function Get-FolderItemsRecursive {
    <#
    .SYNOPSIS
        Recursively enumerates all files and subfolders inside a SharePoint folder,
        returning ListId/ItemId pairs for each.
    #>
    param(
        [string]$SiteUrl,
        [string]$FolderServerRelativeUrl,
        [string]$ListId,
        [hashtable]$Headers
    )

    $results = @()

    # Get files in this folder
    try {
        $filesUrl = "$SiteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$FolderServerRelativeUrl')/Files?`$select=Name,ListItemAllFields/Id&`$expand=ListItemAllFields"
        $filesResponse = Invoke-RestMethod -Uri $filesUrl -Headers $Headers -Method GET
        if($filesResponse -and $filesResponse.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
            $filesResponse = $filesResponse | ConvertFrom-Json -AsHashtable
        }        
        foreach ($file in $filesResponse.d.results) {
            if ($file.ListItemAllFields -and $file.ListItemAllFields.Id) {
                $results += @{
                    ListId = $ListId
                    ItemId = [int]$file.ListItemAllFields.Id
                }
            }
        }
    } catch {
        Write-Warning "  Error fetching files from folder $FolderServerRelativeUrl : $_"
    }

    # Get subfolders, add them as items (they can have sharing links too), and recurse
    try {
        $foldersUrl = "$SiteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$FolderServerRelativeUrl')/Folders?`$select=ServerRelativeUrl,Name,ListItemAllFields/Id&`$expand=ListItemAllFields"
        $foldersResponse = Invoke-RestMethod -Uri $foldersUrl -Headers $Headers -Method GET
        if($foldersResponse -and $foldersResponse.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
            $foldersResponse = $foldersResponse | ConvertFrom-Json -AsHashtable
        }
        foreach ($subfolder in $foldersResponse.d.results) {
            if ($subfolder.Name -eq "Forms") { continue } # Skip system folders

            # Add the subfolder itself as an item (it may have sharing links)
            if ($subfolder.ListItemAllFields -and $subfolder.ListItemAllFields.Id) {
                $results += @{
                    ListId = $ListId
                    ItemId = [int]$subfolder.ListItemAllFields.Id
                }
            }

            # Recurse into the subfolder
            $results += Get-FolderItemsRecursive -SiteUrl $SiteUrl -FolderServerRelativeUrl $subfolder.ServerRelativeUrl -ListId $ListId -Headers $Headers
        }
    } catch {
        Write-Warning "  Error fetching subfolders from $FolderServerRelativeUrl : $_"
    }

    return $results
}

function Get-AllListItems {
    <#
    .SYNOPSIS
        Enumerates all document libraries and their items in a site.
    #>
    param(
        [string]$SiteUrl,
        [hashtable]$Headers
    )

    # Get all document libraries (BaseTemplate 101)
    $listsUrl = "$SiteUrl/_api/web/lists?`$filter=BaseTemplate eq 101 and Hidden eq false&`$select=Id,Title"
    try {
        $lists = Invoke-RestMethod -Uri $listsUrl -Headers $Headers -Method GET
    } catch {
        Write-Warning "Could not enumerate lists for $SiteUrl : $_"
        return @()
    }

    $results = @()
    $totalLibraries = $lists.d.results.Count
    for ($libIdx = 0; $libIdx -lt $totalLibraries; $libIdx++) {
        $list = $lists.d.results[$libIdx]
        $listId = $list.Id
        $listTitle = $list.Title
        $libPct = [math]::Floor(($libIdx / $totalLibraries) * 100)
        Write-Progress -Id 2 -Activity "Enumerating libraries" -Status "[$($libIdx + 1)/$totalLibraries] $listTitle" -PercentComplete $libPct
        Write-Host "  Processing library: $listTitle ($listId)" -ForegroundColor Cyan

        $itemsUrl = "$SiteUrl/_api/web/lists(guid'$listId')/items?`$select=Id&`$top=5000"
        $allItems = @()

        while ($itemsUrl) {
            try {
                $response = Invoke-RestMethod -Uri $itemsUrl -Headers $Headers -Method GET
                if($response -and $response.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject"){
                    $response = $response | ConvertFrom-Json -AsHashtable
                }                
                $allItems += $response.d.results
                $itemsUrl = if ($response.d.__next) { $response.d.__next } else { $null }
            } catch {
                Write-Warning "  Error fetching items from $listTitle : $_"
                $itemsUrl = $null
            }
        }

        foreach ($item in $allItems) {
            $results += @{
                ListId = $listId
                ItemId = [int]$item.ID
            }
        }

        Write-Host "    Found $($allItems.Count) items" -ForegroundColor Gray
    }
    Write-Progress -Id 2 -Activity "Enumerating libraries" -Completed

    return $results
}

#endregion

#region --- Main execution ---

Write-Host "`n=== Update-SharingLinks ===" -ForegroundColor Cyan

$TargetRoleId = 7
Switch($TargetRole){
    "View" {$TargetRoleId = 1}
    "Edit" {$TargetRoleId = 2}
    "Review" {$TargetRoleId = 6}
    "NoDownload" {$TargetRoleId = 7}
}

$ExistingRoleId = 7
Switch($ExistingRole){
    "View" {$ExistingRoleId = 1}
    "Edit" {$ExistingRoleId = 2}
    "Review" {$ExistingRoleId = 6}
    "NoDownload" {$ExistingRoleId = 7}
}

Write-Host "Target role: $TargetRole (ID: $($TargetRoleId))"

if ($PSCmdlet.ParameterSetName -like 'ByItem*') {
    for ($urlIdx = 0; $urlIdx -lt $ItemUrls.Count; $urlIdx++) {
        $itemUrl = $ItemUrls[$urlIdx]
        $urlPct = [math]::Floor(($urlIdx / $ItemUrls.Count) * 100)
        Write-Progress -Id 0 -Activity "Processing item URLs" -Status "[$($urlIdx + 1)/$($ItemUrls.Count)] $itemUrl" -PercentComplete $urlPct
        Write-Host "Resolving item: $itemUrl" -ForegroundColor Cyan
        $resolved = Resolve-ItemUrl -DocumentUrl $itemUrl
        if (-not $resolved) { continue }

        $headers = Get-SpoHeaders -SiteUrl $resolved.SiteUrl

        if ($resolved.IsFolder) {
            Write-Host "  Folder detected — processing recursively" -ForegroundColor Yellow
            Write-Host "  Site: $($resolved.SiteUrl) | List: $($resolved.ListId) | Folder Item: $($resolved.ItemId)"

            # Process sharing links on the folder item itself
            Update-SharingLinksForItem -SiteUrl $resolved.SiteUrl -ListId $resolved.ListId -ItemId $resolved.ItemId -Headers $headers -Role $TargetRoleId

            # Process all child items recursively
            Write-Progress -Id 1 -ParentId 0 -Activity "Scanning folder contents" -Status "Enumerating items..." -PercentComplete 0
            $folderItems = Get-FolderItemsRecursive -SiteUrl $resolved.SiteUrl -FolderServerRelativeUrl $resolved.FolderRelativeUrl -ListId $resolved.ListId -Headers $headers
            Write-Host "  Total items in folder: $($folderItems.Count)" -ForegroundColor Cyan
            for ($fi = 0; $fi -lt $folderItems.Count; $fi++) {
                $fiPct = [math]::Floor(($fi / $folderItems.Count) * 100)
                Write-Progress -Id 1 -ParentId 0 -Activity "Updating folder items" -Status "[$($fi + 1)/$($folderItems.Count)] Item $($folderItems[$fi].ItemId)" -PercentComplete $fiPct
                Update-SharingLinksForItem -SiteUrl $resolved.SiteUrl -ListId $folderItems[$fi].ListId -ItemId $folderItems[$fi].ItemId -Headers $headers -Role $TargetRoleId
            }
            Write-Progress -Id 1 -ParentId 0 -Activity "Updating folder items" -Completed
        } else {
            Write-Host "  Site: $($resolved.SiteUrl) | List: $($resolved.ListId) | Item: $($resolved.ItemId)"
            Update-SharingLinksForItem -SiteUrl $resolved.SiteUrl -ListId $resolved.ListId -ItemId $resolved.ItemId -Headers $headers -Role $TargetRoleId
        }
    }
    Write-Progress -Id 0 -Activity "Processing item URLs" -Completed
} else {
    for ($siteIdx = 0; $siteIdx -lt $SiteUrls.Count; $siteIdx++) {
        $siteUrl = $SiteUrls[$siteIdx]
        $sitePct = [math]::Floor(($siteIdx / $SiteUrls.Count) * 100)
        Write-Progress -Id 0 -Activity "Processing sites" -Status "[$($siteIdx + 1)/$($SiteUrls.Count)] $siteUrl" -PercentComplete $sitePct
        Write-Host "Processing site: $siteUrl" -ForegroundColor Cyan
        $headers = Get-SpoHeaders -SiteUrl $siteUrl
        $items = Get-AllListItems -SiteUrl $siteUrl -Headers $headers

        Write-Host "  Total items to check: $($items.Count)" -ForegroundColor Cyan
        for ($itemIdx = 0; $itemIdx -lt $items.Count; $itemIdx++) {
            $itemPct = [math]::Floor(($itemIdx / $items.Count) * 100)
            Write-Progress -Id 1 -ParentId 0 -Activity "Updating sharing links" -Status "[$($itemIdx + 1)/$($items.Count)] Item $($items[$itemIdx].ItemId)" -PercentComplete $itemPct
            Update-SharingLinksForItem -SiteUrl $siteUrl -ListId $items[$itemIdx].ListId -ItemId $items[$itemIdx].ItemId -Headers $headers -Role $TargetRoleId
        }
        Write-Progress -Id 1 -ParentId 0 -Activity "Updating sharing links" -Completed
    }
    Write-Progress -Id 0 -Activity "Processing sites" -Completed
}

Write-Host "`n=== Done ===" -ForegroundColor Green

#endregion