#Requires -Version 7.0
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    Reports all folders with unique (broken-inheritance) permissions under one or more SharePoint sites or folder URLs.

    Author: Jos Lieben
    Blog: https://www.lieben.nu
    License: Free to use but keep the header intact and give credit.
    Disclaimer: Use at your own risk. Test in a non-production environment first.

.DESCRIPTION
    This script connects to SharePoint Online using certificate-based app authentication and
    enumerates folders across document libraries to find those with unique role assignments
    (i.e., permissions inheritance has been broken).

    You can supply either:
      - An array of site URLs: the script will enumerate ALL document libraries in each site
        and check every folder recursively for unique permissions.
      - An array of folder URLs (full URLs to folders inside a document library): the script
        will check the specified folder and all subfolders recursively.

    These two modes are mutually exclusive (parameter sets).

    Results are exported to an Excel (.xlsx) file.

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
    An array of SharePoint site URLs. All folders in all document libraries of each site will be checked.

.PARAMETER FolderUrls
    An array of full URLs to folders inside a document library
    (e.g., https://contoso.sharepoint.com/sites/hr/Shared Documents/MyFolder).
    Each folder and all subfolders are checked recursively.

.PARAMETER OutputPath
    Path to the output .xlsx file. Defaults to FoldersWithUniquePermissions_<timestamp>.xlsx
    in the current directory.

.EXAMPLE
    .\Get-FoldersWithUniquePermissions.ps1 -TenantId "ab77..." -ClientId "fa17..." -PfxPath ".\cert.pfx" `
        -SiteUrls "https://contoso.sharepoint.com/sites/marketing"

    Exports all folders with unique permissions across the marketing site to an Excel file.

.EXAMPLE
    .\Get-FoldersWithUniquePermissions.ps1 -TenantId "ab77..." -ClientId "fa17..." -CertThumbprint "A1B2C3D4..." `
        -FolderUrls "https://contoso.sharepoint.com/sites/sales/Shared Documents/Reports"

    Checks the Reports folder and all subfolders for unique permissions.

.NOTES
    Requires: An Azure AD app registration with Sites.FullControl.All (or equivalent) application
    permission against SharePoint and a valid certificate. This script uses raw REST APIs.
    Requires: The ImportExcel PowerShell module (Install-Module ImportExcel).
#>

param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory, ParameterSetName = 'BySite_Pfx')]
    [Parameter(Mandatory, ParameterSetName = 'ByFolder_Pfx')]
    [string]$PfxPath,
    [Parameter(ParameterSetName = 'BySite_Pfx')]
    [Parameter(ParameterSetName = 'ByFolder_Pfx')]
    [string]$PfxPassword,
    [Parameter(Mandatory, ParameterSetName = 'BySite_Thumb')]
    [Parameter(Mandatory, ParameterSetName = 'ByFolder_Thumb')]
    [string]$CertThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'BySite_Pfx')]
    [Parameter(Mandatory, ParameterSetName = 'BySite_Thumb')]
    [string[]]$SiteUrls,
    [Parameter(Mandatory, ParameterSetName = 'ByFolder_Pfx')]
    [Parameter(Mandatory, ParameterSetName = 'ByFolder_Thumb')]
    [string[]]$FolderUrls,
    [string]$OutputPath = "FoldersWithUniquePermissions_$(Get-Date -Format 'yyyyMMdd_HHmmss').xlsx"
)

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

function Get-RoleAssignmentDetails {
    <#
    .SYNOPSIS
        Retrieves the role assignments for a given list item, returning principal name/type and role names.
    #>
    param(
        [string]$SiteUrl,
        [string]$ListId,
        [int]$ItemId,
        [hashtable]$Headers
    )

    $url = "$SiteUrl/_api/web/Lists(@a1)/GetItemById(@a2)/RoleAssignments?@a1='$ListId'&@a2='$ItemId'&`$expand=Member,RoleDefinitionBindings"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $Headers -Method GET
        if ($response -and $response.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject") {
            $response = $response | ConvertFrom-Json -AsHashtable
        }

        $assignments = @()
        foreach ($ra in $response.d.results) {
            $principal = $ra.Member.Title
            $principalType = switch ($ra.Member.PrincipalType) {
                1 { "User" }
                2 { "DL" }
                4 { "SecurityGroup" }
                8 { "SharePointGroup" }
                default { "Unknown ($($ra.Member.PrincipalType))" }
            }
            $roles = ($ra.RoleDefinitionBindings.results | ForEach-Object { $_.Name }) -join ", "
            $assignments += "$principal ($principalType): $roles"
        }
        return $assignments -join " | "
    } catch {
        Write-Warning "    Could not retrieve role assignments for Item $ItemId : $_"
        return "Error retrieving assignments"
    }
}

function Get-UniquePermissionFoldersRecursive {
    <#
    .SYNOPSIS
        Recursively checks folders for unique permissions (broken inheritance).
        Returns an array of result objects for folders that have unique permissions.
    #>
    param(
        [string]$SiteUrl,
        [string]$FolderServerRelativeUrl,
        [string]$ListId,
        [string]$LibraryTitle,
        [hashtable]$Headers,
        [System.Collections.Generic.List[PSObject]]$Results
    )

    # Get subfolders with HasUniqueRoleAssignments
    try {
        $foldersUrl = "$SiteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$FolderServerRelativeUrl')/Folders?" +
            "`$select=ServerRelativeUrl,Name,ItemCount,ListItemAllFields/Id,ListItemAllFields/HasUniqueRoleAssignments" +
            "&`$expand=ListItemAllFields"
        $foldersResponse = Invoke-RestMethod -Uri $foldersUrl -Headers $Headers -Method GET
        if ($foldersResponse -and $foldersResponse.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject") {
            $foldersResponse = $foldersResponse | ConvertFrom-Json -AsHashtable
        }
    } catch {
        Write-Warning "  Error enumerating subfolders of $FolderServerRelativeUrl : $_"
        return
    }

    foreach ($subfolder in $foldersResponse.d.results) {
        if ($subfolder.Name -eq "Forms") { continue }

        $itemId = $null
        $hasUnique = $false
        if ($subfolder.ListItemAllFields -and $null -ne $subfolder.ListItemAllFields.Id) {
            $itemId = [int]$subfolder.ListItemAllFields.Id
            $hasUnique = [bool]$subfolder.ListItemAllFields.HasUniqueRoleAssignments
        }

        if ($hasUnique -and $itemId) {
            Write-Host "    UNIQUE: $($subfolder.ServerRelativeUrl)" -ForegroundColor Yellow
            $roleDetails = Get-RoleAssignmentDetails -SiteUrl $SiteUrl -ListId $ListId -ItemId $itemId -Headers $Headers
            $Results.Add([PSCustomObject]@{
                SiteUrl            = $SiteUrl
                Library            = $LibraryTitle
                FolderPath         = $subfolder.ServerRelativeUrl
                ItemId             = $itemId
                ItemCount          = $subfolder.ItemCount
                RoleAssignments    = $roleDetails
            })
        }

        # Recurse into subfolder
        Get-UniquePermissionFoldersRecursive -SiteUrl $SiteUrl -FolderServerRelativeUrl $subfolder.ServerRelativeUrl `
            -ListId $ListId -LibraryTitle $LibraryTitle -Headers $Headers -Results $Results
    }
}

function Resolve-FolderUrl {
    <#
    .SYNOPSIS
        Resolves a full folder URL to SiteUrl, ListId, and server-relative path.
    #>
    param([string]$FolderUrl)

    $uri = [Uri]$FolderUrl
    $headers = Get-SpoHeaders -SiteUrl "https://$($uri.Host)"
    $pathSegments = $uri.AbsolutePath.TrimEnd('/').Split('/')
    $siteUrl = $null

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
        Write-Warning "Could not resolve site URL for $FolderUrl"
        return $null
    }

    $headers = Get-SpoHeaders -SiteUrl $siteUrl
    $serverRelativeUrl = $uri.AbsolutePath

    try {
        $folderInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields?`$select=Id,HasUniqueRoleAssignments" -Headers $headers -Method GET
        if ($folderInfo -and $folderInfo.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject") {
            $folderInfo = $folderInfo | ConvertFrom-Json -AsHashtable
        }
        $itemId = $folderInfo.d.Id

        $listInfo = Invoke-RestMethod -Uri "$siteUrl/_api/web/GetFolderByServerRelativePath(decodedurl='$serverRelativeUrl')/ListItemAllFields/ParentList?`$select=Id,Title" -Headers $headers -Method GET
        if ($listInfo -and $listInfo.PSObject.TypeNames -notcontains "System.Management.Automation.PSCustomObject") {
            $listInfo = $listInfo | ConvertFrom-Json -AsHashtable
        }

        return @{
            SiteUrl            = $siteUrl
            ListId             = $listInfo.d.Id
            LibraryTitle       = $listInfo.d.Title
            ItemId             = [int]$itemId
            HasUniquePerms     = [bool]$folderInfo.d.HasUniqueRoleAssignments
            FolderRelativeUrl  = $serverRelativeUrl
        }
    } catch {
        Write-Warning "Could not resolve '$FolderUrl' as a folder: $_"
        return $null
    }
}

function Get-AllLibraryFolders {
    <#
    .SYNOPSIS
        Enumerates all document libraries in a site and checks all folders for unique permissions.
    #>
    param(
        [string]$SiteUrl,
        [hashtable]$Headers,
        [System.Collections.Generic.List[PSObject]]$Results
    )

    $listsUrl = "$SiteUrl/_api/web/lists?`$filter=BaseTemplate eq 101 and Hidden eq false&`$select=Id,Title,RootFolder/ServerRelativeUrl&`$expand=RootFolder"
    try {
        $lists = Invoke-RestMethod -Uri $listsUrl -Headers $Headers -Method GET
    } catch {
        Write-Warning "Could not enumerate lists for $SiteUrl : $_"
        return
    }

    $totalLibraries = $lists.d.results.Count
    for ($libIdx = 0; $libIdx -lt $totalLibraries; $libIdx++) {
        $list = $lists.d.results[$libIdx]
        $listId = $list.Id
        $listTitle = $list.Title
        $rootFolderUrl = $list.RootFolder.ServerRelativeUrl
        $libPct = [math]::Floor(($libIdx / $totalLibraries) * 100)
        Write-Progress -Id 2 -Activity "Scanning libraries" -Status "[$($libIdx + 1)/$totalLibraries] $listTitle" -PercentComplete $libPct
        Write-Host "  Processing library: $listTitle ($listId)" -ForegroundColor Cyan

        Get-UniquePermissionFoldersRecursive -SiteUrl $SiteUrl -FolderServerRelativeUrl $rootFolderUrl `
            -ListId $listId -LibraryTitle $listTitle -Headers $Headers -Results $Results
    }
    Write-Progress -Id 2 -Activity "Scanning libraries" -Completed
}

#endregion

#region --- Main execution ---

Write-Host "`n=== Get-FoldersWithUniquePermissions ===" -ForegroundColor Cyan

$allResults = [System.Collections.Generic.List[PSObject]]::new()

if ($PSCmdlet.ParameterSetName -like 'ByFolder*') {
    for ($urlIdx = 0; $urlIdx -lt $FolderUrls.Count; $urlIdx++) {
        $folderUrl = $FolderUrls[$urlIdx]
        $urlPct = [math]::Floor(($urlIdx / $FolderUrls.Count) * 100)
        Write-Progress -Id 0 -Activity "Processing folder URLs" -Status "[$($urlIdx + 1)/$($FolderUrls.Count)] $folderUrl" -PercentComplete $urlPct
        Write-Host "Resolving folder: $folderUrl" -ForegroundColor Cyan

        $resolved = Resolve-FolderUrl -FolderUrl $folderUrl
        if (-not $resolved) { continue }

        $headers = Get-SpoHeaders -SiteUrl $resolved.SiteUrl
        Write-Host "  Site: $($resolved.SiteUrl) | Library: $($resolved.LibraryTitle) | Folder Item: $($resolved.ItemId)"

        # Check if the folder itself has unique permissions
        if ($resolved.HasUniquePerms) {
            Write-Host "    UNIQUE: $($resolved.FolderRelativeUrl)" -ForegroundColor Yellow
            $roleDetails = Get-RoleAssignmentDetails -SiteUrl $resolved.SiteUrl -ListId $resolved.ListId -ItemId $resolved.ItemId -Headers $headers
            $allResults.Add([PSCustomObject]@{
                SiteUrl            = $resolved.SiteUrl
                Library            = $resolved.LibraryTitle
                FolderPath         = $resolved.FolderRelativeUrl
                ItemId             = $resolved.ItemId
                ItemCount          = ""
                RoleAssignments    = $roleDetails
            })
        }

        # Recurse into subfolders
        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning subfolders" -Status "Enumerating..." -PercentComplete 0
        Get-UniquePermissionFoldersRecursive -SiteUrl $resolved.SiteUrl -FolderServerRelativeUrl $resolved.FolderRelativeUrl `
            -ListId $resolved.ListId -LibraryTitle $resolved.LibraryTitle -Headers $headers -Results $allResults
        Write-Progress -Id 1 -ParentId 0 -Activity "Scanning subfolders" -Completed
    }
    Write-Progress -Id 0 -Activity "Processing folder URLs" -Completed
} else {
    for ($siteIdx = 0; $siteIdx -lt $SiteUrls.Count; $siteIdx++) {
        $siteUrl = $SiteUrls[$siteIdx]
        $sitePct = [math]::Floor(($siteIdx / $SiteUrls.Count) * 100)
        Write-Progress -Id 0 -Activity "Processing sites" -Status "[$($siteIdx + 1)/$($SiteUrls.Count)] $siteUrl" -PercentComplete $sitePct
        Write-Host "Processing site: $siteUrl" -ForegroundColor Cyan

        $headers = Get-SpoHeaders -SiteUrl $siteUrl
        Get-AllLibraryFolders -SiteUrl $siteUrl -Headers $headers -Results $allResults
    }
    Write-Progress -Id 0 -Activity "Processing sites" -Completed
}

# Export results
if ($allResults.Count -eq 0) {
    Write-Host "`nNo folders with unique permissions found." -ForegroundColor Green
} else {
    Write-Host "`nFound $($allResults.Count) folder(s) with unique permissions." -ForegroundColor Yellow
    $allResults | Export-Excel -Path $OutputPath -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -WorksheetName "UniquePermissions"
    Write-Host "Results exported to: $OutputPath" -ForegroundColor Cyan
}

Write-Host "`n=== Done ===" -ForegroundColor Green

#endregion
