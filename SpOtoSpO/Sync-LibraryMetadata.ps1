<#
.SYNOPSIS
    Mirrors file and folder metadata (Author, Editor, Created, Modified) from a source document library to a target.
    Author: Jos Lieben (Lieben Consultancy)
    Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Pure commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)


.DESCRIPTION
    Connects to two SharePoint Online or OneDrive for Business document libraries using
    certificate-based PnP authentication.  Supports standard SharePoint site URLs
    (sites/xxx, teams/xxx) as well as OneDrive URLs (personal/xxx).
    Identifies files and folders by their relative path within each library and updates the target's
    Author (Created By), Editor (Modified By), Created, and Modified timestamps to match the source.
    Handles system/app accounts (e.g. SharePoint-app) that have no email address.

    When the -FixVersionHistory switch is specified, also corrects metadata on previous
    file versions. SharePoint Online does not support direct modification of historical
    version metadata, so the script uses a RestoreByLabel + ValidateUpdateListItem approach:
    each old version is temporarily promoted to current, its metadata is overwritten, and
    the original current version is restored at the end. This creates additional version
    entries in the target (original + corrected copies).

    After correcting all versions, the script attempts to delete the original (pre-fix)
    version entries that carried incorrect metadata. This cleanup is best-effort: if a
    retention policy or other compliance hold prevents deletion, the error is logged as a
    warning and processing continues. In that scenario the target file will retain both
    the original and the corrected version entries.

    Without -FixVersionHistory, only the current version's metadata is synced.

    Items that exist in only one library are silently skipped.

.PARAMETER SourceUrl
    Full URL to the source document library. Supports SharePoint sites and OneDrive for Business.
    Examples:
      https://contoso.sharepoint.com/sites/SiteA/Shared Documents
      https://contoso-my.sharepoint.com/personal/username_contoso_com/Documents

.PARAMETER TargetUrl
    Full URL to the target document library. Supports SharePoint sites and OneDrive for Business.
    Examples:
      https://contoso.sharepoint.com/sites/SiteB/Shared Documents
      https://contoso-my.sharepoint.com/personal/username_contoso_com/Documents

.PARAMETER ClientId
    Azure AD app registration client ID.

.PARAMETER TenantId
    Tenant ID or domain.

.PARAMETER PfxPath
    Path to the PFX certificate file. Used for PFX-based auth (mutually exclusive with Thumbprint).

.PARAMETER PfxPassword
    Password for the PFX file (optional if the PFX has no password).

.PARAMETER PfxPasswordFile
    Path to a plain-text file containing the PFX password (first line is used).
    Safest option for passwords with special characters.

.PARAMETER Thumbprint
    Certificate thumbprint for a certificate installed in the local certificate store.
    Used for thumbprint-based auth (mutually exclusive with PfxPath).

.PARAMETER FixVersionHistory
    When specified, also corrects Author and Editor metadata on previous file versions.
    This is a slower operation as it must restore, update and re-restore each version.
    Without this switch, only the current version's metadata is synced.

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

.EXAMPLE
    # OneDrive for Business
    .\Sync-LibraryMetadata.ps1 `
        -SourceUrl "https://contoso-my.sharepoint.com/personal/jdoe_contoso_com/Documents" `
        -TargetUrl "https://contoso.sharepoint.com/sites/Archive/Shared Documents" `
        -PfxPath "C:\certs\mycert.pfx" -PfxPassword "secret"

.EXAMPLE
    # Also fix metadata on previous file versions
    .\Sync-LibraryMetadata.ps1 `
        -SourceUrl "https://contoso.sharepoint.com/sites/SiteA/Shared Documents" `
        -TargetUrl "https://contoso.sharepoint.com/sites/SiteB/Shared Documents" `
        -Thumbprint "34CFAA860E5FB8C44335A38A097C1E41EEA206AA" `
        -FixVersionHistory
#>
param(
    [Parameter(Mandatory=$true)][string]$SourceUrl,
    [Parameter(Mandatory=$true)][string]$TargetUrl,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [string]$PfxPath        = "",
    [string]$PfxPassword    = "",
    [string]$PfxPasswordFile= "",
    [string]$Thumbprint     = "",
    [switch]$FixVersionHistory,
    [int]$BatchSize         = 100
)

$ErrorActionPreference = 'Stop'

# ============================================================
# HELPER: Parse a library URL into site URL + library relative path
# ============================================================
function Split-LibraryUrl {
    param([string]$LibraryUrl)

    $uri = [System.Uri]$LibraryUrl
    $pathSegments = $uri.AbsolutePath.TrimStart('/').Split('/')

    # Find the site boundary:
    #   sites/xxx  or  teams/xxx  = 2 segments (prefix + site name)
    #   personal/xxx             = 2 segments (prefix + user folder)  [OneDrive]
    $siteIndex = -1
    for ($i = 0; $i -lt $pathSegments.Count; $i++) {
        if ($pathSegments[$i] -in @('sites', 'teams', 'personal')) {
            $siteIndex = $i + 1  # include the site/user name
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

    # Separate library name from subfolder path.
    # The library name is the first segment (e.g. "Documents", "Shared Documents").
    # Anything after it is a subfolder filter, not part of the library identity.
    # "Shared Documents/Reports" → library = "Shared Documents", subfolder = "Reports"
    # For OneDrive "Documents/MyFolder" → library = "Documents", subfolder = "MyFolder"
    #
    # Known multi-word library names that should not be split:
    $knownLibraries = @('Shared Documents', 'Gedeelde documenten', 'Documents partages',
                        'Freigegebene Dokumente', 'Documentos compartidos', 'Site Assets',
                        'Style Library', 'Form Templates')
    $subfolderPath = ""
    $matchedLib = $knownLibraries | Where-Object {
        $libraryRelPath -eq $_ -or $libraryRelPath.StartsWith("$_/", [System.StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object { $_.Length } -Descending | Select-Object -First 1

    if ($matchedLib) {
        if ($libraryRelPath.Length -gt $matchedLib.Length) {
            $subfolderPath = $libraryRelPath.Substring($matchedLib.Length + 1)
        }
        $libraryRelPath = $matchedLib
    } else {
        # Single-word library (e.g. "Documents") — split on first /
        $slashPos = $libraryRelPath.IndexOf('/')
        if ($slashPos -gt 0) {
            $subfolderPath  = $libraryRelPath.Substring($slashPos + 1)
            $libraryRelPath = $libraryRelPath.Substring(0, $slashPos)
        }
    }

    return @{
        SiteUrl       = $siteUrl
        LibraryRel    = $libraryRelPath
        SubfolderPath = $subfolderPath
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
        if ($PfxPasswordFile) {
            $pwd = (Get-Content -Path $PfxPasswordFile -Raw -Encoding UTF8).TrimEnd("`r","`n")
            $connectParams.CertificatePassword = (ConvertTo-SecureString -String $pwd -AsPlainText -Force)
        } elseif ($PfxPassword) {
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
        [string]$SubfolderPath,
        [string]$LibraryServerRelUrl,
        $Connection
    )

    # On large OneDrive / SharePoint libraries (>5,000 items) every variant of
    # Get-PnPListItem hits the list-view threshold or silently ignores filters.
    # The only fully reliable approach is CSOM folder navigation:
    #   - Get-PnPFolder to reach each folder
    #   - Load Files + ListItemAllFields for file metadata
    #   - Load Folders to recurse
    # Folder navigation is not subject to the threshold.

    $rootPath = $LibraryServerRelUrl.TrimEnd('/')
    if ($SubfolderPath) {
        $rootPath = "$rootPath/$SubfolderPath"
        Write-Host "  Retrieving items from '$LibraryRelPath' subfolder '$SubfolderPath' ..." -ForegroundColor Cyan
    } else {
        Write-Host "  Retrieving all items from '$LibraryRelPath' ..." -ForegroundColor Cyan
    }

    $ctx = Get-PnPContext -Connection $Connection
    $allItems = [System.Collections.Generic.List[object]]::new()

    function Process-Folder {
        param([string]$FolderServerRelUrl)

        $folder = $ctx.Web.GetFolderByServerRelativeUrl($FolderServerRelUrl)
        $ctx.Load($folder)
        $ctx.Load($folder.Files)
        $ctx.Load($folder.Folders)

        # Also load the folder's own list item (so we can sync folder metadata)
        try { $ctx.Load($folder.ListItemAllFields) } catch {}

        $ctx.ExecuteQuery()

        # Add the folder itself as a list item (skip the root folder)
        if ($FolderServerRelUrl -ne $rootPath) {
            try {
                if ($folder.ListItemAllFields -and $folder.ListItemAllFields.FieldValues.Count -gt 0) {
                    $allItems.Add($folder.ListItemAllFields)
                }
            } catch {
                # Some system folders may not have list items
            }
        }

        # Load ListItemAllFields for each file
        foreach ($file in $folder.Files) {
            $ctx.Load($file.ListItemAllFields)
        }
        $ctx.ExecuteQuery()

        foreach ($file in $folder.Files) {
            try {
                if ($file.ListItemAllFields -and $file.ListItemAllFields.FieldValues.Count -gt 0) {
                    $allItems.Add($file.ListItemAllFields)
                }
            } catch {}
        }

        # Recurse into subfolders (skip hidden system folders like "Forms")
        foreach ($subFolder in $folder.Folders) {
            $sfName = $subFolder.Name
            if ($sfName -eq 'Forms' -or $sfName.StartsWith('_')) { continue }
            Process-Folder -FolderServerRelUrl $subFolder.ServerRelativeUrl
        }
    }

    Process-Folder -FolderServerRelUrl $rootPath

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
        [string]$LibraryServerRelUrl,
        [string]$SubfolderPath
    )

    $index = @{}
    # Build the prefix to strip: library root + optional subfolder
    $basePath = $LibraryServerRelUrl.TrimEnd('/')
    if ($SubfolderPath) {
        $basePath = "$basePath/$SubfolderPath"
    }
    $basePrefix = $basePath + '/'

    foreach ($item in $Items) {
        $fileRef = $item["FileRef"]
        # Relative path within the (sub)folder (e.g. "Subfolder/Report.docx")
        if ($fileRef.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relPath = $fileRef.Substring($basePrefix.Length)
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

Write-Host "Source site: $($source.SiteUrl)  |  Library: $($source.LibraryRel)$(if ($source.SubfolderPath) { "  |  Subfolder: $($source.SubfolderPath)" })" -ForegroundColor White
Write-Host "Target site: $($target.SiteUrl)  |  Library: $($target.LibraryRel)$(if ($target.SubfolderPath) { "  |  Subfolder: $($target.SubfolderPath)" })" -ForegroundColor White
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
$tgtListId       = $tgtList.Id.ToString()

# Retrieve all items (files + folders)
Write-Host "SOURCE library:" -ForegroundColor Yellow
$srcItems = Get-LibraryItems -LibraryRelPath $source.LibraryRel -SubfolderPath $source.SubfolderPath -LibraryServerRelUrl $srcLibServerRel -Connection $srcConn

Write-Host "TARGET library:" -ForegroundColor Yellow
$tgtItems = Get-LibraryItems -LibraryRelPath $target.LibraryRel -SubfolderPath $target.SubfolderPath -LibraryServerRelUrl $tgtLibServerRel -Connection $tgtConn
Write-Host ""

# Build indexes by relative path
$srcIndex = Build-RelativePathIndex -Items $srcItems -LibraryServerRelUrl $srcLibServerRel -SubfolderPath $source.SubfolderPath
$tgtIndex = Build-RelativePathIndex -Items $tgtItems -LibraryServerRelUrl $tgtLibServerRel -SubfolderPath $target.SubfolderPath

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

# Determine whether source and target are the same site collection.
# If they are, user LookupIds are identical and can be compared/copied directly.
# If not (e.g. OneDrive → SharePoint), we must compare by Email and resolve
# users on the target site to get the correct LookupId.
$sameSite = $source.SiteUrl.TrimEnd('/') -eq $target.SiteUrl.TrimEnd('/')

# Cache: source user email → target LookupId  (avoids repeated EnsureUser calls)
$script:userCache = @{}

function Resolve-TargetUserId {
    <#
    .SYNOPSIS
        Given a source SPFieldUserValue, returns the corresponding LookupId on the target site.
        Uses email-based resolution via EnsureUser when sites differ.
    #>
    param($SourceUserValue)

    if ($sameSite) { return $SourceUserValue.LookupId }

    $email = $SourceUserValue.Email
    if (-not $email) {
        # System/app accounts may have no email — use LookupValue (display name) as fallback
        $email = $SourceUserValue.LookupValue
    }
    if (-not $email) { return $null }

    if ($script:userCache.ContainsKey($email)) {
        return $script:userCache[$email]
    }

    try {
        $user = Get-PnPUser -Identity $email -Connection $tgtConn -ErrorAction SilentlyContinue
        if (-not $user) {
            # EnsureUser adds the user to the target site's User Information List
            $web = Get-PnPWeb -Connection $tgtConn
            $user = $web.EnsureUser($email)
            $ctx = Get-PnPContext -Connection $tgtConn
            $ctx.Load($user)
            $ctx.ExecuteQuery()
        }
        $script:userCache[$email] = $user.Id
        return $user.Id
    } catch {
        Write-Warning "    Could not resolve user '$email' on target site: $_"
        $script:userCache[$email] = $null
        return $null
    }
}

function Compare-Users {
    <#
    .SYNOPSIS
        Compares two SPFieldUserValues, using LookupId on same site or Email across sites.
    #>
    param($SourceUser, $TargetUser)

    if ($sameSite) {
        return ($SourceUser.LookupId -ne $TargetUser.LookupId)
    }

    # Cross-site: compare by email (or display name for system accounts)
    $srcIdentity = if ($SourceUser.Email) { $SourceUser.Email } else { $SourceUser.LookupValue }
    $tgtIdentity = if ($TargetUser.Email) { $TargetUser.Email } else { $TargetUser.LookupValue }
    return ($srcIdentity -ne $tgtIdentity)
}

function Get-UserLoginName {
    <#
    .SYNOPSIS
        Resolves a source user value to its claims login name on the target site
        (e.g. "i:0#.f|membership|user@contoso.com") for use with ValidateUpdateListItem.
    #>
    param($SourceUserValue)

    $email = $SourceUserValue.Email
    if (-not $email) { $email = $SourceUserValue.LookupValue }
    if (-not $email) { return $null }

    try {
        $web  = Get-PnPWeb -Connection $tgtConn
        $user = $web.EnsureUser($email)
        $ctx  = Get-PnPContext -Connection $tgtConn
        $ctx.Load($user)
        $ctx.ExecuteQuery()
        return $user.LoginName
    } catch {
        return $null
    }
}

function Update-VersionMetadata {
    <#
    .SYNOPSIS
        Updates Author, Editor, Created, Modified on previous versions of a file.

    .DESCRIPTION
        SharePoint Online does not allow direct modification of version metadata.
        The only working approach is:
        1. For each historical version needing metadata correction:
           a. RestoreByLabel() — promotes the old version's content to become the current item
           b. ValidateUpdateListItem with bNewDocumentUpdate=true — overwrites metadata in-place
              (acts like UpdateOverwriteVersion, no new version is created by this call)
        2. After processing all old versions, restore the original current version and fix its metadata.
        3. Attempt to delete the original (pre-fix) version entries that carried wrong metadata.

        Because RestoreByLabel creates a new version number each time it is called, the target
        file will end up with additional version entries (original + corrected copies).
        Step 3 cleans up the originals. If a retention policy or compliance hold prevents
        deletion, the error is logged as a warning and processing continues — the file will
        retain both the original and the corrected entries.

        Returns a hashtable with keys 'Fixed' (int) and 'Deleted' (int).
    #>
    param(
        [string]$SourceFileServerRelUrl,
        [string]$TargetFileServerRelUrl,
        $SourceItem,
        [string]$TargetListId,
        [int]$TargetItemId,
        $SourceConnection,
        $TargetConnection
    )

    # ---- Load source file versions ----
    $srcCtx  = Get-PnPContext -Connection $SourceConnection
    $srcFile = $srcCtx.Web.GetFileByServerRelativeUrl($SourceFileServerRelUrl)
    $srcCtx.Load($srcFile.ListItemAllFields)
    $srcCtx.Load($srcFile.ListItemAllFields.Versions)
    $srcCtx.ExecuteQuery()

    # Build a hashtable of source version metadata keyed by VersionLabel
    $srcVersions = @{}
    foreach ($sv in $srcFile.ListItemAllFields.Versions) {
        if ($sv.IsCurrentVersion) { continue }
        $srcVersions[$sv.VersionLabel] = $sv
    }

    if ($srcVersions.Count -eq 0) {
        return 0
    }

    # ---- Load target file versions ----
    $tgtCtx  = Get-PnPContext -Connection $TargetConnection
    $tgtFile = $tgtCtx.Web.GetFileByServerRelativeUrl($TargetFileServerRelUrl)
    $tgtCtx.Load($tgtFile)
    $tgtCtx.Load($tgtFile.ListItemAllFields)
    $tgtCtx.Load($tgtFile.ListItemAllFields.Versions)
    $tgtCtx.ExecuteQuery()

    $tgtVersions = @{}
    foreach ($tv in $tgtFile.ListItemAllFields.Versions) {
        if ($tv.IsCurrentVersion) { continue }
        $tgtVersions[$tv.VersionLabel] = $tv
    }

    # Record the current version label so we can restore it at the end
    $currentVersionLabel = $tgtFile.ListItemAllFields["_UIVersionString"]

    # ---- Identify versions that need updating ----
    $versionsToFix = [System.Collections.Generic.List[string]]::new()
    foreach ($label in $srcVersions.Keys) {
        if (-not $tgtVersions.ContainsKey($label)) { continue }

        $sv = $srcVersions[$label]
        $tv = $tgtVersions[$label]
        $svEditor = $sv.FieldValues["Editor"]
        $tvEditor = $tv.FieldValues["Editor"]
        $svAuthor = $sv.FieldValues["Author"]
        $tvAuthor = $tv.FieldValues["Author"]

        $needsFix = (Compare-Users -SourceUser $svEditor -TargetUser $tvEditor) -or
                    (Compare-Users -SourceUser $svAuthor -TargetUser $tvAuthor)

        if ($needsFix) {
            $versionsToFix.Add($label)
        }
    }

    if ($versionsToFix.Count -eq 0) {
        return @{ Fixed = 0; Deleted = 0 }
    }

    # Sort versions so we process from oldest to newest
    $versionsToFix = $versionsToFix | Sort-Object { [decimal]$_ }

    $fixedCount = 0

    foreach ($label in $versionsToFix) {
        $sv = $srcVersions[$label]
        try {
            # Restore this version — makes its content the current item (creates a new version number)
            $tgtFileReload = $tgtCtx.Web.GetFileByServerRelativeUrl($TargetFileServerRelUrl)
            $tgtCtx.Load($tgtFileReload.Versions)
            $tgtCtx.ExecuteQuery()
            $tgtFileReload.Versions.RestoreByLabel($label)
            $tgtCtx.ExecuteQuery()

            # Build the metadata payload for ValidateUpdateListItem
            $formValues = [System.Collections.Generic.List[object]]::new()

            $svEditor = $sv.FieldValues["Editor"]
            $loginName = Get-UserLoginName -SourceUserValue $svEditor
            if ($loginName) {
                $formValues.Add([ordered]@{ FieldName = "Editor"; FieldValue = "[{`"Key`":`"$loginName`"}]" })
            }

            $svAuthor = $sv.FieldValues["Author"]
            $loginName = Get-UserLoginName -SourceUserValue $svAuthor
            if ($loginName) {
                $formValues.Add([ordered]@{ FieldName = "Author"; FieldValue = "[{`"Key`":`"$loginName`"}]" })
            }

            $svModified = $sv.FieldValues["Modified"]
            if ($svModified) {
                $dt = ([datetime]$svModified).ToUniversalTime()
                $formValues.Add([ordered]@{ FieldName = "Modified"; FieldValue = $dt.ToString("M/d/yyyy h:mm tt") })
            }

            $svCreated = $sv.FieldValues["Created"]
            if ($svCreated) {
                $dt = ([datetime]$svCreated).ToUniversalTime()
                $formValues.Add([ordered]@{ FieldName = "Created"; FieldValue = $dt.ToString("M/d/yyyy h:mm tt") })
            }

            if ($formValues.Count -gt 0) {
                [string]$body = [ordered]@{ formValues = $formValues; bNewDocumentUpdate = $true } | ConvertTo-Json -Depth 5 -Compress
                $url  = "/_api/web/lists(guid'$TargetListId')/items($TargetItemId)/ValidateUpdateListItem"
                $null = Invoke-PnPSPRestMethod -Url $url -Method Post -Content $body -ContentType "application/json;odata=verbose" -Connection $TargetConnection
            }

            $fixedCount++
            Write-Host "      Fixed version $label metadata" -ForegroundColor DarkCyan
        } catch {
            Write-Warning "      Failed to fix version ${label}: $_"
        }
    }

    # ---- Restore the original current version ----
    try {
        $tgtFileReload = $tgtCtx.Web.GetFileByServerRelativeUrl($TargetFileServerRelUrl)
        $tgtCtx.Load($tgtFileReload.Versions)
        $tgtCtx.ExecuteQuery()
        $tgtFileReload.Versions.RestoreByLabel($currentVersionLabel)
        $tgtCtx.ExecuteQuery()

        # Fix the restored current version metadata (it gets the restore user/timestamp)
        $formValues = [System.Collections.Generic.List[object]]::new()

        $srcEditor = $SourceItem["Editor"]
        $loginName = Get-UserLoginName -SourceUserValue $srcEditor
        if ($loginName) {
            $formValues.Add([ordered]@{ FieldName = "Editor"; FieldValue = "[{`"Key`":`"$loginName`"}]" })
        }

        $srcAuthor = $SourceItem["Author"]
        $loginName = Get-UserLoginName -SourceUserValue $srcAuthor
        if ($loginName) {
            $formValues.Add([ordered]@{ FieldName = "Author"; FieldValue = "[{`"Key`":`"$loginName`"}]" })
        }

        $srcModified = $SourceItem["Modified"]
        if ($srcModified) {
            $dt = ([datetime]$srcModified).ToUniversalTime()
            $formValues.Add([ordered]@{ FieldName = "Modified"; FieldValue = $dt.ToString("M/d/yyyy h:mm tt") })
        }

        $srcCreated = $SourceItem["Created"]
        if ($srcCreated) {
            $dt = ([datetime]$srcCreated).ToUniversalTime()
            $formValues.Add([ordered]@{ FieldName = "Created"; FieldValue = $dt.ToString("M/d/yyyy h:mm tt") })
        }

        if ($formValues.Count -gt 0) {
            [string]$body = [ordered]@{ formValues = $formValues; bNewDocumentUpdate = $true } | ConvertTo-Json -Depth 5 -Compress
            $url  = "/_api/web/lists(guid'$TargetListId')/items($TargetItemId)/ValidateUpdateListItem"
            $null = Invoke-PnPSPRestMethod -Url $url -Method Post -Content $body -ContentType "application/json;odata=verbose" -Connection $TargetConnection
        }

        Write-Host "      Restored current version ($currentVersionLabel)" -ForegroundColor DarkCyan
    } catch {
        Write-Warning "      Failed to restore current version ($currentVersionLabel): $_"
    }

    # ---- Delete original (pre-fix) version entries ----
    $deletedCount = 0
    if ($fixedCount -gt 0) {
        try {
            $tgtFileReload = $tgtCtx.Web.GetFileByServerRelativeUrl($TargetFileServerRelUrl)
            $tgtCtx.Load($tgtFileReload.Versions)
            $tgtCtx.ExecuteQuery()

            foreach ($label in $versionsToFix) {
                try {
                    $tgtFileReload.Versions.DeleteByLabel($label)
                    $tgtCtx.ExecuteQuery()
                    $deletedCount++
                    Write-Host "      Deleted original version $label" -ForegroundColor DarkGray
                } catch {
                    Write-Warning "      Could not delete version ${label} (retention policy?): $_"
                }
            }
        } catch {
            Write-Warning "      Could not load versions for cleanup: $_"
        }
    }

    return @{ Fixed = $fixedCount; Deleted = $deletedCount }
}

# Process updates
$updated   = 0
$skipped   = 0
$errors    = 0
$versionsFixed   = 0
$versionsDeleted = 0
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
    $editorChanged  = (Compare-Users -SourceUser $srcEditor  -TargetUser $tgtEditor)
    $authorChanged  = (Compare-Users -SourceUser $srcAuthor  -TargetUser $tgtAuthor)
    $createdChanged = ([datetime]$srcCreated -ne [datetime]$tgtCreated)
    $modifiedChanged= ([datetime]$srcModified -ne [datetime]$tgtModified)

    if (-not ($editorChanged -or $authorChanged -or $createdChanged -or $modifiedChanged)) {
        if ($FixVersionHistory) {
            # Current version metadata matches, but version history may still differ.
            # Check files (not folders) for mismatched version metadata.
            $isFolder = ($tgtItem["FSObjType"] -eq 1 -or $tgtItem["FSObjType"] -eq "1")
            if (-not $isFolder) {
                $vFixed = Update-VersionMetadata `
                    -SourceFileServerRelUrl $srcItem["FileRef"] `
                    -TargetFileServerRelUrl $tgtItem["FileRef"] `
                    -SourceItem       $srcItem `
                    -TargetListId     $tgtListId `
                    -TargetItemId     $tgtItem.Id `
                    -SourceConnection $srcConn `
                    -TargetConnection $tgtConn
                if ($vFixed.Fixed -gt 0) {
                    $versionsFixed   += $vFixed.Fixed
                    $versionsDeleted += $vFixed.Deleted
                    Write-Host "  [$counter/$total] Fixed $($vFixed.Fixed) version(s) metadata, deleted $($vFixed.Deleted) original(s): $relPath" -ForegroundColor DarkCyan
                } else {
                    $skipped++
                }
            } else {
                $skipped++
            }
        } else {
            $skipped++
        }
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
            $resolvedId = Resolve-TargetUserId -SourceUserValue $srcEditor
            if ($null -ne $resolvedId) {
                $userVal = [Microsoft.SharePoint.Client.FieldUserValue]::new()
                $userVal.LookupId = $resolvedId
                $csomItem["Editor"] = $userVal
                $changes += "Editor"
            } else {
                Write-Warning "    Could not resolve Editor for $relPath — skipping Editor update."
            }
        }
        if ($authorChanged) {
            $resolvedId = Resolve-TargetUserId -SourceUserValue $srcAuthor
            if ($null -ne $resolvedId) {
                $userVal = [Microsoft.SharePoint.Client.FieldUserValue]::new()
                $userVal.LookupId = $resolvedId
                $csomItem["Author"] = $userVal
                $changes += "Author"
            } else {
                Write-Warning "    Could not resolve Author for $relPath — skipping Author update."
            }
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

        # For files (not folders), also update version history metadata when requested
        if ($FixVersionHistory) {
            $isFolder = ($tgtItem["FSObjType"] -eq 1 -or $tgtItem["FSObjType"] -eq "1")
            if (-not $isFolder) {
                $vFixed = Update-VersionMetadata `
                    -SourceFileServerRelUrl $srcItem["FileRef"] `
                    -TargetFileServerRelUrl $tgtItem["FileRef"] `
                    -SourceItem       $srcItem `
                    -TargetListId     $tgtListId `
                    -TargetItemId     $itemId `
                    -SourceConnection $srcConn `
                    -TargetConnection $tgtConn
                if ($vFixed.Fixed -gt 0) {
                    $versionsFixed   += $vFixed.Fixed
                    $versionsDeleted += $vFixed.Deleted
                    Write-Host "    [$counter/$total] Fixed $($vFixed.Fixed) version(s) metadata, deleted $($vFixed.Deleted) original(s)" -ForegroundColor DarkCyan
                }
            }
        }
    } catch {
        $errors++
        Write-Warning "  [$counter/$total] FAILED: $relPath — $_"
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Completed in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Cyan
Write-Host "  Updated: $updated" -ForegroundColor Green
if ($FixVersionHistory) {
    Write-Host "  Version history entries fixed: $versionsFixed" -ForegroundColor DarkCyan
    Write-Host "  Original versions deleted: $versionsDeleted" -ForegroundColor DarkGray
}
Write-Host "  Skipped (already matching): $skipped" -ForegroundColor DarkGray
Write-Host "  Errors: $errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'Green' })
Write-Host "============================================" -ForegroundColor Cyan

# Disconnect (ignore errors if connections already disposed)
try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}