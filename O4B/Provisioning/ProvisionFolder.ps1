<#
.SYNOPSIS
    Provisions a folder (from local disk or a remote ZIP URL) into OneDrive for Business sites.
    Author: Jos Lieben (Lieben Consultancy)
    Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Pure commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)

.DESCRIPTION
    Uploads an entire folder structure into one or more OneDrive for Business document
    libraries using PnP authentication (Managed Identity, certificate, or PFX).

    The source can be either a local folder (-SourcePath) or a publicly accessible
    ZIP file URL (-SourceZipUrl). When a ZIP URL is provided the archive is downloaded
    to a temporary directory, extracted, and the extracted root is used as the source.

    Targets can be an explicit list of OneDrive site URLs (-OneDriveUrls) or the
    script can enumerate every OneDrive in the tenant (-AllOneDrives) via the
    SharePoint admin center.

    Files are uploaded into the Documents library, either at the root or under a
    specific relative path (-TargetRelativePath). If a file already exists at the
    destination it is forcibly overwritten — even when the file is checked out or
    locked — by forcing a check-in and then re-uploading.

    Folder structures are created recursively to match the source hierarchy.

.PARAMETER OneDriveUrls
    One or more OneDrive for Business site URLs to provision.
    Example: "https://contoso-my.sharepoint.com/personal/jdoe_contoso_com"
    Mutually exclusive with -AllOneDrives.

.PARAMETER AllOneDrives
    When specified, enumerates all OneDrive for Business sites in the tenant and
    provisions each one. Requires -TenantName so the script can connect to the
    SharePoint admin center. Mutually exclusive with -OneDriveUrls.

.PARAMETER TenantName
    The tenant prefix (e.g. "contoso" for contoso.sharepoint.com). Required when
    -AllOneDrives is used to build the admin center URL.

.PARAMETER SourcePath
    Path to a local folder whose contents will be uploaded.
    Mutually exclusive with -SourceZipUrl.

.PARAMETER SourceZipUrl
    URL to a publicly accessible ZIP file. The archive is downloaded, extracted to a
    temp folder, and its contents are uploaded. Mutually exclusive with -SourcePath.

.PARAMETER TargetRelativePath
    Optional relative path within the Documents library where the folder should be
    placed. Use forward slashes (e.g. "Company/Templates"). When omitted, files are
    uploaded directly into the Documents root.

.PARAMETER ClientId
    Azure AD / Entra ID app registration client ID. When omitted, the script
    authenticates using Managed Identity (suitable for Azure Automation Runbooks
    or Azure VMs with a system/user-assigned managed identity).

.PARAMETER TenantId
    Tenant ID or domain (e.g. "contoso.onmicrosoft.com"). Required for
    certificate-based authentication.

.PARAMETER PfxPath
    Path to the PFX certificate file. Mutually exclusive with -Thumbprint.

.PARAMETER PfxPassword
    Password for the PFX file (optional if the PFX has no password).

.PARAMETER Thumbprint
    Certificate thumbprint for a certificate installed in the local certificate store.
    Mutually exclusive with -PfxPath.

.EXAMPLE
    # Provision using Managed Identity (e.g. from an Azure Automation Runbook)
    .\ProvisionFolder.ps1 `
        -AllOneDrives -TenantName "contoso" `
        -SourcePath "C:\Templates\Finance"

.EXAMPLE
    # Provision a local folder to a specific OneDrive using certificate
    .\ProvisionFolder.ps1 `
        -OneDriveUrls "https://contoso-my.sharepoint.com/personal/jdoe_contoso_com" `
        -SourcePath "C:\Templates\Finance" `
        -ClientId "12345678-..." -TenantId "abcdef12-..." `
        -Thumbprint "34CFAA860E5FB8C44335A38A097C1E41EEA206AA"

.EXAMPLE
    # Provision a ZIP from a URL into a subfolder on all OneDrives
    .\ProvisionFolder.ps1 `
        -AllOneDrives -TenantName "contoso" `
        -SourceZipUrl "https://files.contoso.com/templates.zip" `
        -TargetRelativePath "Company/Templates" `
        -ClientId "12345678-..." -TenantId "abcdef12-..." `
        -PfxPath "C:\certs\mycert.pfx" -PfxPassword "secret"

.EXAMPLE
    # Provision a local folder into the Documents root of two OneDrives
    .\ProvisionFolder.ps1 `
        -OneDriveUrls @(
            "https://contoso-my.sharepoint.com/personal/jdoe_contoso_com",
            "https://contoso-my.sharepoint.com/personal/asmith_contoso_com"
        ) `
        -SourcePath "C:\Onboarding\StarterKit" `
        -ClientId "12345678-..." -TenantId "abcdef12-..." `
        -Thumbprint "34CFAA860E..."
#>
param(
    [string[]]$OneDriveUrls   = @(),
    [switch]$AllOneDrives,
    [string]$TenantName       = "",
    [string]$SourcePath       = "",
    [string]$SourceZipUrl     = "",
    [string]$TargetRelativePath = "",
    [string]$ClientId         = "",
    [string]$TenantId         = "",
    [string]$PfxPath          = "",
    [string]$PfxPassword      = "",
    [string]$Thumbprint       = ""
)

$ErrorActionPreference = 'Stop'

# ============================================================
# VALIDATION
# ============================================================
if ($OneDriveUrls.Count -gt 0 -and $AllOneDrives) {
    Write-Error "Specify either -OneDriveUrls or -AllOneDrives, not both."
}
if ($OneDriveUrls.Count -eq 0 -and -not $AllOneDrives) {
    Write-Error "Specify at least one -OneDriveUrls value or use -AllOneDrives."
}
if ($AllOneDrives -and -not $TenantName) {
    Write-Error "-TenantName is required when using -AllOneDrives."
}
if ($SourcePath -and $SourceZipUrl) {
    Write-Error "Specify either -SourcePath or -SourceZipUrl, not both."
}
if (-not $SourcePath -and -not $SourceZipUrl) {
    Write-Error "Specify either -SourcePath or -SourceZipUrl."
}
# Determine authentication mode
$useManagedIdentity = (-not $ClientId)
if (-not $useManagedIdentity -and -not $PfxPath -and -not $Thumbprint) {
    Write-Error "When using certificate auth (-ClientId), either -PfxPath or -Thumbprint must be provided."
}
if (-not $useManagedIdentity -and -not $TenantId) {
    Write-Error "-TenantId is required when using certificate auth (-ClientId)."
}
if ($useManagedIdentity) {
    Write-Host "Authentication mode: Managed Identity" -ForegroundColor Cyan
} else {
    Write-Host "Authentication mode: Certificate (ClientId $ClientId)" -ForegroundColor Cyan
}

# ============================================================
# HELPER: Connect to a site (Managed Identity or certificate)
# ============================================================
function Connect-Site {
    param([string]$SiteUrl)

    if ($useManagedIdentity) {
        return (Connect-PnPOnline -Url $SiteUrl -ReturnConnection -ManagedIdentity)
    }

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
    }

    return (Connect-PnPOnline @connectParams)
}

# ============================================================
# HELPER: Resolve the effective source folder (local or ZIP)
# ============================================================
function Resolve-SourceFolder {
    if ($SourcePath) {
        if (-not (Test-Path -Path $SourcePath -PathType Container)) {
            Write-Error "Source folder not found: $SourcePath"
        }
        return @{ Path = (Resolve-Path $SourcePath).Path; TempDir = $null }
    }

    # Download and extract ZIP
    $tempDir  = Join-Path ([System.IO.Path]::GetTempPath()) "ProvisionFolder_$([guid]::NewGuid().ToString('N'))"
    $zipFile  = Join-Path $tempDir "source.zip"
    $extractDir = Join-Path $tempDir "extracted"

    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null

    Write-Host "Downloading ZIP from $SourceZipUrl ..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $SourceZipUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Error "Failed to download ZIP: $_"
    }
    Write-Host "  Downloaded to $zipFile" -ForegroundColor Green

    Write-Host "Extracting ZIP ..." -ForegroundColor Cyan
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
    Write-Host "  Extracted to $extractDir" -ForegroundColor Green

    # If the ZIP contains a single root folder, use that as the source
    $children = Get-ChildItem -Path $extractDir
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        $effectivePath = $children[0].FullName
    } else {
        $effectivePath = $extractDir
    }

    return @{ Path = $effectivePath; TempDir = $tempDir }
}

# ============================================================
# HELPER: Ensure a folder path exists in the library, creating
#         each segment as needed. Returns the server-relative URL
#         of the final folder.
# ============================================================
function Ensure-FolderPath {
    param(
        [string]$LibraryServerRelUrl,
        [string]$RelativePath,
        $Connection
    )

    if (-not $RelativePath) {
        return $LibraryServerRelUrl
    }

    $segments  = $RelativePath.Replace('\', '/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    $currentUrl = $LibraryServerRelUrl.TrimEnd('/')

    foreach ($segment in $segments) {
        $targetUrl = "$currentUrl/$segment"
        try {
            $folder = Get-PnPFolder -Url $targetUrl -Connection $Connection -ErrorAction Stop
        } catch {
            Write-Host "    Creating folder: $targetUrl" -ForegroundColor DarkCyan
            $folder = Add-PnPFolder -Name $segment -Folder $currentUrl -Connection $Connection -ErrorAction Stop
        }
        $currentUrl = $targetUrl
    }

    return $currentUrl
}

# ============================================================
# HELPER: Force check-in of a file if it is checked out
# ============================================================
function Force-CheckIn {
    param(
        [string]$FileServerRelUrl,
        $Connection
    )

    try {
        $ctx  = Get-PnPContext -Connection $Connection
        $file = $ctx.Web.GetFileByServerRelativeUrl($FileServerRelUrl)
        $ctx.Load($file)
        $ctx.ExecuteQuery()

        if ($file.CheckOutType -ne [Microsoft.SharePoint.Client.CheckOutType]::None) {
            Write-Host "      Force checking in: $FileServerRelUrl" -ForegroundColor DarkYellow
            $file.CheckIn("Forced check-in by ProvisionFolder script", [Microsoft.SharePoint.Client.CheckinType]::OverwriteCheckIn)
            $ctx.ExecuteQuery()
        }
    } catch {
        # File may not exist yet — that's fine
    }
}

# ============================================================
# HELPER: Upload all files from a local folder to a library path
# ============================================================
function Upload-FolderContents {
    param(
        [string]$LocalFolderPath,
        [string]$LibraryServerRelUrl,
        [string]$RemoteBasePath,
        $Connection
    )

    $uploadedCount = 0
    $errorCount    = 0

    # Upload files in the current directory
    $files = Get-ChildItem -Path $LocalFolderPath -File
    foreach ($file in $files) {
        $remoteFileUrl = "$RemoteBasePath/$($file.Name)"
        try {
            # Force check-in if file is checked out
            Force-CheckIn -FileServerRelUrl $remoteFileUrl -Connection $Connection

            # Upload with -Force to overwrite existing files
            Add-PnPFile -Path $file.FullName -Folder $RemoteBasePath -NewFileName $file.Name `
                -Connection $Connection -ErrorAction Stop | Out-Null

            $uploadedCount++
            Write-Host "    Uploaded: $remoteFileUrl" -ForegroundColor Green
        } catch {
            $errorCount++
            Write-Warning "    Failed to upload $($file.Name): $_"
        }
    }

    # Recurse into subdirectories
    $subDirs = Get-ChildItem -Path $LocalFolderPath -Directory
    foreach ($subDir in $subDirs) {
        $subRemotePath = "$RemoteBasePath/$($subDir.Name)"

        # Ensure the subfolder exists
        try {
            $null = Get-PnPFolder -Url $subRemotePath -Connection $Connection -ErrorAction Stop
        } catch {
            Write-Host "    Creating folder: $subRemotePath" -ForegroundColor DarkCyan
            Add-PnPFolder -Name $subDir.Name -Folder $RemoteBasePath -Connection $Connection -ErrorAction Stop | Out-Null
        }

        $subResult = Upload-FolderContents `
            -LocalFolderPath $subDir.FullName `
            -LibraryServerRelUrl $LibraryServerRelUrl `
            -RemoteBasePath $subRemotePath `
            -Connection $Connection

        $uploadedCount += $subResult.Uploaded
        $errorCount    += $subResult.Errors
    }

    return @{ Uploaded = $uploadedCount; Errors = $errorCount }
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

# Resolve source folder
$sourceInfo = Resolve-SourceFolder
$sourceFolderPath = $sourceInfo.Path
$sourceFolderName = Split-Path -Path $sourceFolderPath -Leaf

$sourceFileCount  = (Get-ChildItem -Path $sourceFolderPath -File -Recurse).Count
$sourceDirCount   = (Get-ChildItem -Path $sourceFolderPath -Directory -Recurse).Count
Write-Host ""
Write-Host "Source folder: $sourceFolderPath" -ForegroundColor White
Write-Host "  $sourceFileCount file(s) in $sourceDirCount subfolder(s)" -ForegroundColor White
Write-Host ""

# Build the list of target OneDrive URLs
if ($AllOneDrives) {
    Write-Host "Connecting to SharePoint admin center to enumerate OneDrive sites..." -ForegroundColor Cyan
    $adminConn = Connect-Site -SiteUrl "https://$TenantName-admin.sharepoint.com"
    Write-Host "  Connected." -ForegroundColor Green

    $odSites = Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '-my.sharepoint.com/personal/'" -Connection $adminConn
    $targetUrls = @($odSites | Select-Object -ExpandProperty Url)
    Write-Host "  Found $($targetUrls.Count) OneDrive site(s)." -ForegroundColor Green
    Write-Host ""

    try { Disconnect-PnPOnline -Connection $adminConn -ErrorAction SilentlyContinue } catch {}
} else {
    $targetUrls = $OneDriveUrls
}

if ($targetUrls.Count -eq 0) {
    Write-Host "No OneDrive sites to process." -ForegroundColor Yellow
    exit 0
}

# Process each OneDrive
$totalUploaded = 0
$totalErrors   = 0
$sitesProcessed = 0
$sitesFailed    = 0

foreach ($odUrl in $targetUrls) {
    $siteIndex = $targetUrls.IndexOf($odUrl) + 1
    Write-Host "[$siteIndex/$($targetUrls.Count)] Processing: $odUrl" -ForegroundColor Yellow

    try {
        # Connect to the OneDrive site
        $siteConn = Connect-Site -SiteUrl $odUrl.TrimEnd('/')
        Write-Host "  Connected." -ForegroundColor Green

        # Get the Documents library server-relative URL
        $docLib = Get-PnPList -Identity "Documents" -Connection $siteConn
        if (-not $docLib) {
            Write-Warning "  Documents library not found — skipping."
            $sitesFailed++
            continue
        }
        $libServerRelUrl = $docLib.RootFolder.ServerRelativeUrl.TrimEnd('/')

        # Build the target base path: library root + optional relative path + source folder name
        $targetBase = $libServerRelUrl
        if ($TargetRelativePath) {
            $targetBase = Ensure-FolderPath -LibraryServerRelUrl $libServerRelUrl `
                -RelativePath $TargetRelativePath -Connection $siteConn
        }

        # Create the top-level source folder in the target
        $destinationPath = "$targetBase/$sourceFolderName"
        try {
            $null = Get-PnPFolder -Url $destinationPath -Connection $siteConn -ErrorAction Stop
            Write-Host "  Folder already exists: $destinationPath (will overwrite contents)" -ForegroundColor DarkYellow
        } catch {
            Write-Host "  Creating folder: $destinationPath" -ForegroundColor DarkCyan
            Add-PnPFolder -Name $sourceFolderName -Folder $targetBase -Connection $siteConn -ErrorAction Stop | Out-Null
        }

        # Upload all contents
        $result = Upload-FolderContents `
            -LocalFolderPath $sourceFolderPath `
            -LibraryServerRelUrl $libServerRelUrl `
            -RemoteBasePath $destinationPath `
            -Connection $siteConn

        $totalUploaded += $result.Uploaded
        $totalErrors   += $result.Errors
        $sitesProcessed++

        Write-Host "  Done: $($result.Uploaded) file(s) uploaded, $($result.Errors) error(s)." -ForegroundColor $(if ($result.Errors -gt 0) { 'Yellow' } else { 'Green' })

        try { Disconnect-PnPOnline -Connection $siteConn -ErrorAction SilentlyContinue } catch {}
    } catch {
        $sitesFailed++
        Write-Warning "  FAILED to process $odUrl — $_"
    }

    Write-Host ""
}

# Clean up temp directory if we downloaded a ZIP
if ($sourceInfo.TempDir -and (Test-Path $sourceInfo.TempDir)) {
    Write-Host "Cleaning up temp directory..." -ForegroundColor DarkGray
    Remove-Item -Path $sourceInfo.TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Summary
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Completed in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Cyan
Write-Host "  Sites processed: $sitesProcessed" -ForegroundColor Green
Write-Host "  Sites failed: $sitesFailed" -ForegroundColor $(if ($sitesFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Total files uploaded: $totalUploaded" -ForegroundColor Green
Write-Host "  Total errors: $totalErrors" -ForegroundColor $(if ($totalErrors -gt 0) { 'Red' } else { 'Green' })
Write-Host "============================================" -ForegroundColor Cyan
