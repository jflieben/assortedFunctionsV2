<#
.SYNOPSIS
    Reconfigures all sharing links under one or more SharePoint sites, or for specific document URLs, to a desired role (e.g., View-only).
    
    Author: Jos Lieben
    Blog: https://www.lieben.nu
    License: Free to use but keep the header intact and give credit.

.DESCRIPTION
    This script connects to SharePoint Online using certificate-based app authentication and
    iterates through sharing links to update their role/permission level.

    You can supply either:
      - An array of site URLs: the script will enumerate ALL document libraries and ALL items
        in each site and update every sharing link found.
      - An array of item URLs (full URLs to individual documents): the script will resolve each
        document to its list and item, then update sharing links for those specific items.

    These two modes are mutually exclusive (parameter sets).

.PARAMETER TenantId
    Azure AD / Entra tenant ID (GUID).

.PARAMETER ClientId
    Azure AD / Entra app registration client ID (GUID).

.PARAMETER PfxPath
    Path to the PFX certificate file used for client-assertion authentication.

.PARAMETER PfxPassword
    (Optional) Password for the PFX file. If omitted, an empty password is assumed.

.PARAMETER SiteUrls
    An array of SharePoint site URLs. All items in all document libraries of each site will be processed.

.PARAMETER ItemUrls
    An array of full document URLs (e.g., https://contoso.sharepoint.com/sites/hr/Shared Documents/report.docx).

.PARAMETER TargetRole
    The role to set on every sharing link found. Valid values are
    View, Edit, Review, Can View but Cannot Download.

.EXAMPLE
    .\Update-SharingLinks.ps1 -TenantId "ab77..." -ClientId "fa17..." -PfxPath ".\cert.pfx" -SiteUrls "https://contoso.sharepoint.com/sites/marketing"

    Updates ALL sharing links across every item in the marketing site to View-only.

.EXAMPLE
    .\Update-SharingLinks.ps1 -TenantId "ab77..." -ClientId "fa17..." -PfxPath ".\cert.pfx" `
        -ItemUrls "https://contoso.sharepoint.com/sites/sales/Shared Documents/proposal.pdf" -TargetRole View

    Updates sharing links for the specific document to Edit.

.NOTES
    Requires: An Azure AD app registration with Sites.FullControl.All (or equivalent) application
    permission against Sharepoint and a valid certificate. This script uses raw REST APIs.
#>

param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$PfxPath,
    [string]$PfxPassword,
    [Parameter(Mandatory, ParameterSetName = 'BySite')]
    [string[]]$SiteUrls,
    [Parameter(Mandatory, ParameterSetName = 'ByItem')]
    [string[]]$ItemUrls,
    [Parameter(Mandatory)]
    [ValidateSet('View','Edit','Review', 'NoDownload')]
    [string]$TargetRole
)

#region --- Authentication helpers ---

# Load PFX
if ($PfxPassword) {
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
        Resolves a full document URL to SiteUrl, ListId, and ItemId.
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

    try {
        $fileInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFileByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields?`$select=Id" -Headers $headers -Method GET
        $itemId = $fileInfo.d.Id

        $listInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFileByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields/ParentList?`$select=Id" -Headers $headers -Method GET
        $listId = $listInfo.d.Id

        return @{
            SiteUrl = $siteUrl
            ListId  = $listId
            ItemId  = [int]$itemId
        }
    } catch {
        Write-Warning "Could not resolve file $DocumentUrl : $_"
        return $null
    }
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
    foreach ($list in $lists.d.results) {
        $listId = $list.Id
        $listTitle = $list.Title
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

Write-Host "Target role: $TargetRole (ID: $($TargetRoleId))"

if ($PSCmdlet.ParameterSetName -eq 'ByItem') {
    foreach ($itemUrl in $ItemUrls) {
        Write-Host "Resolving item: $itemUrl" -ForegroundColor Cyan
        $resolved = Resolve-ItemUrl -DocumentUrl $itemUrl
        if (-not $resolved) { continue }

        $headers = Get-SpoHeaders -SiteUrl $resolved.SiteUrl
        Write-Host "  Site: $($resolved.SiteUrl) | List: $($resolved.ListId) | Item: $($resolved.ItemId)"
        Update-SharingLinksForItem -SiteUrl $resolved.SiteUrl -ListId $resolved.ListId -ItemId $resolved.ItemId -Headers $headers -Role $TargetRoleId
    }
} else {
    foreach ($siteUrl in $SiteUrls) {
        Write-Host "Processing site: $siteUrl" -ForegroundColor Cyan
        $headers = Get-SpoHeaders -SiteUrl $siteUrl
        $items = Get-AllListItems -SiteUrl $siteUrl -Headers $headers

        Write-Host "  Total items to check: $($items.Count)" -ForegroundColor Cyan
        foreach ($item in $items) {
            Update-SharingLinksForItem -SiteUrl $siteUrl -ListId $item.ListId -ItemId $item.ItemId -Headers $headers -Role $TargetRoleId
        }
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Green

#endregion