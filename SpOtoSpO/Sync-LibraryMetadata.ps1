<#
.SYNOPSIS
    Mirrors file and folder metadata (Author, Editor, Created, Modified) from a source document library to a target.
    Author: Jos Lieben (Lieben Consultancy)
    Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Pure commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)


.DESCRIPTION
    Connects to two SharePoint Online document libraries using certificate-based PnP authentication.
    Identifies files and folders by their relative path within each library and updates the target's
    Author (Created By), Editor (Modified By), Created, and Modified timestamps to match the source.
    Handles system/app accounts (e.g. SharePoint-app) that have no email address.

    Items that exist in only one library are silently skipped.

.PARAMETER SourceUrl
    Full URL to the source document library (e.g. https://contoso.sharepoint.com/sites/SiteA/Shared Documents).

.PARAMETER TargetUrl
    Full URL to the target document library (e.g. https://contoso.sharepoint.com/sites/SiteB/Shared Documents).

.PARAMETER ClientId
    Azure AD app registration client ID.

.PARAMETER TenantId
    Tenant ID or domain.

.PARAMETER PfxPath
    Path to the PFX certificate file. Used for PFX-based auth (mutually exclusive with Thumbprint).

.PARAMETER PfxPassword
    Password for the PFX file (optional if the PFX has no password).

.PARAMETER Thumbprint
    Certificate thumbprint for a certificate installed in the local certificate store.
    Used for thumbprint-based auth (mutually exclusive with PfxPath).

.PARAMETER BatchSize
    Number of items to process per PnP batch (default 100).

.EXAMPLE
    # PFX-based auth
    .\Sync-LibraryMetadata.ps1 `
        -SourceUrl "https://nmlan.sharepoint.com/sites/SiteA/Gedeelde documenten" `
        -TargetUrl "https://nmlan.sharepoint.com/sites/SiteB/Gedeelde documenten" `
        -PfxPath "C:\certs\mycert.pfx" -PfxPassword "secret"

.EXAMPLE
    # Thumbprint-based auth
    .\Sync-LibraryMetadata.ps1 `
        -SourceUrl "https://nmlan.sharepoint.com/sites/SiteA/Gedeelde documenten" `
        -TargetUrl "https://nmlan.sharepoint.com/sites/SiteB/Gedeelde documenten" `
        -Thumbprint "34CFAA860E5FB8C44335A38A097C1E41EEA206AA"
#>
param(
    [Parameter(Mandatory=$true)][string]$SourceUrl,
    [Parameter(Mandatory=$true)][string]$TargetUrl,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [string]$PfxPath     = "",
    [string]$PfxPassword = "",
    [string]$Thumbprint  = "",
    [int]$BatchSize      = 100
)

$ErrorActionPreference = 'Stop'

# ============================================================
# HELPER: Parse a library URL into site URL + library relative path
# ============================================================
function Split-LibraryUrl {
    param([string]$LibraryUrl)

    $uri = [System.Uri]$LibraryUrl
    $pathSegments = $uri.AbsolutePath.TrimStart('/').Split('/')

    # Find the site boundary (sites/xxx or teams/xxx = 2 segments after sites/)
    $siteIndex = -1
    for ($i = 0; $i -lt $pathSegments.Count; $i++) {
        if ($pathSegments[$i] -in @('sites', 'teams')) {
            $siteIndex = $i + 1  # include the site name
            break
        }
    }

    if ($siteIndex -lt 0) {
        # Root site — library is the first path segment
        $siteUrl = "$($uri.Scheme)://$($uri.Host)"
        $libraryRelPath = ($pathSegments -join '/')
    } else {
        $siteParts   = $pathSegments[0..$siteIndex]
        $siteUrl     = "$($uri.Scheme)://$($uri.Host)/$($siteParts -join '/')"
        if ($siteIndex + 1 -lt $pathSegments.Count) {
            $libraryRelPath = ($pathSegments[($siteIndex + 1)..($pathSegments.Count - 1)] -join '/')
        } else {
            Write-Error "No library path found in URL: $LibraryUrl"
        }
    }

    # Decode %20 etc.
    $libraryRelPath = [System.Uri]::UnescapeDataString($libraryRelPath)

    return @{
        SiteUrl    = $siteUrl
        LibraryRel = $libraryRelPath
    }
}

# ============================================================
# HELPER: Connect to a site with cert-based auth
# ============================================================
function Connect-Site {
    param([string]$SiteUrl)

    $connectParams = @{
        Url              = $SiteUrl
        ClientId         = $ClientId
        Tenant           = $TenantId
        ReturnConnection = $true
    }

    if ($Thumbprint) {
        $connectParams.Thumbprint = $Thumbprint
    } elseif ($PfxPath) {
        $connectParams.CertificatePath = $PfxPath
        if ($PfxPassword) {
            $connectParams.CertificatePassword = (ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force)
        }
    } else {
        Write-Error "Either -PfxPath or -Thumbprint must be provided."
    }

    return (Connect-PnPOnline @connectParams)
}

# ============================================================
# HELPER: Get all items (files + folders) in a library recursively
# ============================================================
function Get-LibraryItems {
    param(
        [string]$LibraryRelPath,
        $Connection
    )

    Write-Host "  Retrieving all items from '$LibraryRelPath' ..." -ForegroundColor Cyan
    $allItems = Get-PnPListItem -List $LibraryRelPath -PageSize 2000 -Connection $Connection -Fields "FileRef","FileLeafRef","Author","Editor","Created","Modified","FSObjType"

    $files   = @($allItems | Where-Object { $_["FSObjType"] -eq 0 -or $_["FSObjType"] -eq "0" })
    $folders = @($allItems | Where-Object { $_["FSObjType"] -eq 1 -or $_["FSObjType"] -eq "1" })
    Write-Host "  Found $($files.Count) file(s) and $($folders.Count) folder(s)." -ForegroundColor Green
    return $allItems
}

# ============================================================
# HELPER: Build a relative-path lookup from library items
# ============================================================
function Build-RelativePathIndex {
    param(
        $Items,
        [string]$LibraryServerRelUrl
    )

    $index = @{}
    $libPrefix = $LibraryServerRelUrl.TrimEnd('/') + '/'

    foreach ($item in $Items) {
        $fileRef = $item["FileRef"]
        # Relative path within the library (e.g. "Subfolder/Report.docx")
        if ($fileRef.StartsWith($libPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relPath = $fileRef.Substring($libPrefix.Length)
        } else {
            $relPath = $fileRef
        }
        $index[$relPath.ToLowerInvariant()] = $item
    }

    return $index
}

# ============================================================
# MAIN
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Ensure PnP.PowerShell is available
if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Host "Installing PnP.PowerShell module..." -ForegroundColor Yellow
    Install-Module -Name PnP.PowerShell -Force -Scope CurrentUser
}
Import-Module PnP.PowerShell -ErrorAction Stop

# Parse URLs
$source = Split-LibraryUrl -LibraryUrl $SourceUrl
$target = Split-LibraryUrl -LibraryUrl $TargetUrl

Write-Host "Source site: $($source.SiteUrl)  |  Library: $($source.LibraryRel)" -ForegroundColor White
Write-Host "Target site: $($target.SiteUrl)  |  Library: $($target.LibraryRel)" -ForegroundColor White
Write-Host ""

# Connect to both sites
Write-Host "Connecting to source site..." -ForegroundColor Cyan
$srcConn = Connect-Site -SiteUrl $source.SiteUrl
Write-Host "  Connected." -ForegroundColor Green

Write-Host "Connecting to target site..." -ForegroundColor Cyan
$tgtConn = Connect-Site -SiteUrl $target.SiteUrl
Write-Host "  Connected." -ForegroundColor Green
Write-Host ""

# Get library server-relative URLs
$srcList = Get-PnPList -Identity $source.LibraryRel -Connection $srcConn
$tgtList = Get-PnPList -Identity $target.LibraryRel -Connection $tgtConn
$srcLibServerRel = $srcList.RootFolder.ServerRelativeUrl
$tgtLibServerRel = $tgtList.RootFolder.ServerRelativeUrl

# Retrieve all items (files + folders)
Write-Host "SOURCE library:" -ForegroundColor Yellow
$srcItems = Get-LibraryItems -LibraryRelPath $source.LibraryRel -Connection $srcConn

Write-Host "TARGET library:" -ForegroundColor Yellow
$tgtItems = Get-LibraryItems -LibraryRelPath $target.LibraryRel -Connection $tgtConn
Write-Host ""

# Build indexes by relative path
$srcIndex = Build-RelativePathIndex -Items $srcItems -LibraryServerRelUrl $srcLibServerRel
$tgtIndex = Build-RelativePathIndex -Items $tgtItems -LibraryServerRelUrl $tgtLibServerRel

# Find common paths
$commonPaths = @($srcIndex.Keys | Where-Object { $tgtIndex.ContainsKey($_) })
Write-Host "Items present in both libraries: $($commonPaths.Count)" -ForegroundColor Cyan
Write-Host "Items only in source: $($srcIndex.Count - $commonPaths.Count)" -ForegroundColor DarkGray
Write-Host "Items only in target: $($tgtIndex.Count - $commonPaths.Count)" -ForegroundColor DarkGray
Write-Host ""

if ($commonPaths.Count -eq 0) {
    Write-Host "No common items found \u2014 nothing to update." -ForegroundColor Yellow
    exit 0
}

# Process updates
$updated   = 0
$skipped   = 0
$errors    = 0
$total     = $commonPaths.Count
$counter   = 0

foreach ($relPath in $commonPaths) {
    $counter++
    $srcItem = $srcIndex[$relPath]
    $tgtItem = $tgtIndex[$relPath]

    $srcEditor   = $srcItem["Editor"]  # SPFieldUserValue
    $srcAuthor   = $srcItem["Author"]  # SPFieldUserValue
    $srcCreated  = $srcItem["Created"]
    $srcModified = $srcItem["Modified"]

    $tgtEditor   = $tgtItem["Editor"]
    $tgtAuthor   = $tgtItem["Author"]
    $tgtCreated  = $tgtItem["Created"]
    $tgtModified = $tgtItem["Modified"]

    # Determine whether anything differs
    # For user fields, compare by LookupId (handles system accounts with no email)
    $editorChanged  = ($srcEditor.LookupId -ne $tgtEditor.LookupId)
    $authorChanged  = ($srcAuthor.LookupId -ne $tgtAuthor.LookupId)
    $createdChanged = ([datetime]$srcCreated -ne [datetime]$tgtCreated)
    $modifiedChanged= ([datetime]$srcModified -ne [datetime]$tgtModified)

    if (-not ($editorChanged -or $authorChanged -or $createdChanged -or $modifiedChanged)) {
        $skipped++
        continue
    }

    try {
        $changes = @()
        $itemId  = $tgtItem.Id

        # Use CSOM UpdateOverwriteVersion for all field updates
        # - Dates: pass UTC DateTime objects (locale-independent)
        # - Users: pass FieldUserValue with LookupId (handles system/app accounts)
        # UpdateOverwriteVersion overwrites system fields without creating a new version
        $csomItem = Get-PnPListItem -List $target.LibraryRel -Id $itemId -Connection $tgtConn

        if ($editorChanged) {
            $userVal = [Microsoft.SharePoint.Client.FieldUserValue]::new()
            $userVal.LookupId = $srcEditor.LookupId
            $csomItem["Editor"] = $userVal
            $changes += "Editor"
        }
        if ($authorChanged) {
            $userVal = [Microsoft.SharePoint.Client.FieldUserValue]::new()
            $userVal.LookupId = $srcAuthor.LookupId
            $csomItem["Author"] = $userVal
            $changes += "Author"
        }
        if ($createdChanged) {
            $csomItem["Created"] = [DateTime]::SpecifyKind(([datetime]$srcCreated).ToUniversalTime(), [DateTimeKind]::Utc)
            $changes += "Created"
        }
        if ($modifiedChanged) {
            $csomItem["Modified"] = [DateTime]::SpecifyKind(([datetime]$srcModified).ToUniversalTime(), [DateTimeKind]::Utc)
            $changes += "Modified"
        }

        $csomItem.UpdateOverwriteVersion()
        $ctx = Get-PnPContext -Connection $tgtConn
        $ctx.ExecuteQuery()

        $updated++
        Write-Host "  [$counter/$total] Updated ($($changes -join ', ')): $relPath" -ForegroundColor Green
    } catch {
        $errors++
        Write-Warning "  [$counter/$total] FAILED: $relPath — $_"
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Completed in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Cyan
Write-Host "  Updated: $updated" -ForegroundColor Green
Write-Host "  Skipped (already matching): $skipped" -ForegroundColor DarkGray
Write-Host "  Errors: $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'Green' })
Write-Host "============================================" -ForegroundColor Cyan

# Disconnect (ignore errors if connections already disposed)
try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}

