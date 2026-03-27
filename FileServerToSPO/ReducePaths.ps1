<#
.SYNOPSIS
    Reduces file/folder paths and file names to comply with SharePoint Online limits.
    Author: Jos Lieben (Lieben Consultancy)
    Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Pure commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)

.DESCRIPTION
    Recursively scans a root folder structure and enforces two SharePoint Online constraints:

    1. File names are truncated to MaxFileNameLength (default 128 characters including extension).
    2. Paths whose length relative to RootPath exceeds MaxPathLength (default 400 characters) are
       moved to a flat overflow folder. The RootPath prefix itself is NOT counted.

    File name truncation is applied first so that shortening a name may bring the full path under the
    limit, avoiding an unnecessary move to the overflow folder.

    Uses AlphaFS (AlphaFS.dll in the same folder) for all file system operations so that paths longer
    than 256 characters can be enumerated, moved and validated correctly on Windows.

    Run with -WhatIf to preview changes without modifying anything.

.PARAMETER RootPath
    Path to the root of the folder structure to scan (e.g. \\fileserver\homedirs$\user1 or C:\Data\Migration).

.PARAMETER MaxPathLength
    Maximum allowed full path length. Defaults to 400 (SharePoint Online limit).

.PARAMETER MaxFileNameLength
    Maximum allowed file name length including extension. Defaults to 128 (SharePoint Online limit).

.PARAMETER OverflowFolderName
    Name of the folder (created under RootPath) where items with paths that are too long will be moved.
    Defaults to '_ReducedPaths'.

.PARAMETER MaxRetries
    Number of retry attempts for file/folder operations. Defaults to 5.

.PARAMETER RetryDelayMs
    Milliseconds to wait between retries. Defaults to 500.

.PARAMETER IncludeFolders
    Optional list of folder paths (relative to RootPath) to limit the scope of the
    scan. Use the folder name alone for top-level folders, or Name\SubName for nested
    paths. Forward slashes are also accepted. When omitted, everything under RootPath
    is in scope. When specified, only the listed folders (and everything underneath
    them) are processed; other top-level folders are skipped.
    Takes precedence over ExcludeFolders — when both are supplied, ExcludeFolders is ignored.

.PARAMETER ExcludeFolders
    Optional list of folder paths (relative to RootPath) to exclude from the scan.
    Use the folder name alone for top-level folders, or Name\SubName for nested paths.
    Forward slashes are also accepted. Only matches anchored at the root — a folder
    name that happens to appear deeper in the tree is not excluded.
    Ignored when IncludeFolders is also supplied.

.PARAMETER WhatIf
    When specified, the script reports what it would do without making any changes.

.EXAMPLE
    # Dry run — preview what would be renamed or moved
    .\ReducePaths.ps1 -RootPath "\\fileserver\data$\project" -WhatIf

.EXAMPLE
    # Actually fix items that exceed SPO limits
    .\ReducePaths.ps1 -RootPath "C:\Migration\HomeDir"

.EXAMPLE
    # Custom limits and overflow folder
    .\ReducePaths.ps1 -RootPath "D:\Shares\Team" -MaxPathLength 256 -MaxFileNameLength 100 -OverflowFolderName "_TooLong"

.EXAMPLE
    # Only fix issues inside specific folders
    .\ReducePaths.ps1 -RootPath "D:\Shares\Team" -IncludeFolders @("Finance", "HR\Recruitment")

.EXAMPLE
    # Single include folder with WhatIf
    .\ReducePaths.ps1 -RootPath "\\server\share$" -IncludeFolders "Projects\2025" -WhatIf

.EXAMPLE
    # Exclude specific folders from the scan
    .\ReducePaths.ps1 -RootPath "D:\Shares\Team" -ExcludeFolders @("Archive", "Temp\OldData")
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$RootPath,
    [int]$MaxPathLength        = 206,
    [int]$MaxFileNameLength    = 127,
    [string]$OverflowFolderName = "_Fix",
    [string[]]$IncludeFolders  = @(),
    [string[]]$ExcludeFolders  = @(),
    [int]$MaxRetries           = 5,
    [int]$RetryDelayMs         = 500,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Load AlphaFS — required for long path (>256 char) support
# ============================================================
$alphaFsDll = Join-Path -Path $PSScriptRoot -ChildPath "AlphaFS.dll"
if (-not (Test-Path -LiteralPath $alphaFsDll)) {
    Write-Error "AlphaFS.dll not found at '$alphaFsDll'. Place it in the same folder as this script."
}
try {
    Add-Type -Path $alphaFsDll -ErrorAction Stop
} catch [System.Reflection.ReflectionTypeLoadException] {
    # Already loaded — safe to ignore
} catch {
    Write-Error "Failed to load AlphaFS.dll: $_"
}

# ============================================================
# Counters & state
# ============================================================
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:moved    = 0
$script:renamed  = 0
$script:skipped  = 0
$script:errors   = 0
$script:scanned  = 0
$script:reportEntries = [System.Collections.Generic.List[PSCustomObject]]::new()

# ============================================================
# Validate root path (AlphaFS handles long paths)
# ============================================================
if (-not [Alphaleonis.Win32.Filesystem.Directory]::Exists($RootPath)) {
    Write-Error "Root path does not exist: $RootPath"
}
$RootPath = $RootPath.TrimEnd('\')
$script:rootPathLength = $RootPath.Length   # used to compute relative path lengths

# ============================================================
# HELPER: Get the path length relative to RootPath (excludes the
#         root prefix so only the user's folder structure counts).
# ============================================================
function Get-RelativePathLength {
    param([string]$AbsolutePath)
    return $AbsolutePath.Length - $script:rootPathLength
}

# ============================================================
# Normalize IncludeFolders: backslash-separated, trimmed, lowered
# Build a lookup set of absolute include paths for fast matching.
# A path is "in scope" if it equals or is underneath an include.
# An ancestor of an include is also traversed so we can reach the
# included subfolder.
# ============================================================
$script:hasIncludeFilter = $IncludeFolders.Count -gt 0
$script:includeAbsolute  = @()   # Absolute paths of included folders (lower-cased)

if ($script:hasIncludeFilter) {
    $script:includeAbsolute = @($IncludeFolders | ForEach-Object {
        $rel = $_.Replace('/', '\').Trim('\')
        ($RootPath + '\' + $rel).ToLowerInvariant()
    })
}
# ============================================================
# Normalize ExcludeFolders (only used when IncludeFolders is NOT active)
# ============================================================
$script:hasExcludeFilter = (-not $script:hasIncludeFilter) -and ($ExcludeFolders.Count -gt 0)
$script:excludeAbsolute  = @()

if ($script:hasExcludeFilter) {
    $script:excludeAbsolute = @($ExcludeFolders | ForEach-Object {
        $rel = $_.Replace('/', '\').Trim('\\')
        ($RootPath + '\' + $rel).ToLowerInvariant()
    })
}
function Test-Excluded {
    <#
    .SYNOPSIS
        Returns $true when the absolute path equals or is underneath one of the
        ExcludeFolders entries (anchored at RootPath). Only active when
        IncludeFolders is not supplied.
    #>
    param([string]$AbsolutePath)

    if (-not $script:hasExcludeFilter) { return $false }

    $lower = $AbsolutePath.ToLowerInvariant()
    foreach ($exc in $script:excludeAbsolute) {
        if ($lower -eq $exc -or $lower.StartsWith("$exc\")) {
            return $true
        }
    }
    return $false
}

function Test-InScope {
    <#
    .SYNOPSIS
        Returns $true when the given absolute path is in scope.
        A path is in scope when:
          - No IncludeFolders filter is active (everything in scope), OR
          - It equals one of the include paths, OR
          - It is underneath one of the include paths, OR
          - It is an ancestor of an include path (so we recurse into it).
    #>
    param([string]$AbsolutePath)

    if (-not $script:hasIncludeFilter) { return $true }

    $lower = $AbsolutePath.ToLowerInvariant()
    foreach ($inc in $script:includeAbsolute) {
        # Exact match or path is underneath the include
        if ($lower -eq $inc -or $lower.StartsWith("$inc\")) {
            return $true
        }
        # Path is an ancestor of the include (we must recurse through it)
        if ($inc.StartsWith("$lower\")) {
            return $true
        }
    }
    return $false
}

function Test-FullyIncluded {
    <#
    .SYNOPSIS
        Returns $true when the path equals or is underneath an include path.
        This means the path itself (and its files) should be processed for fixes,
        not just traversed.
    #>
    param([string]$AbsolutePath)

    if (-not $script:hasIncludeFilter) { return $true }

    $lower = $AbsolutePath.ToLowerInvariant()
    foreach ($inc in $script:includeAbsolute) {
        if ($lower -eq $inc -or $lower.StartsWith("$inc\")) {
            return $true
        }
    }
    return $false
}

# ============================================================
# Ensure overflow folder exists
# ============================================================
$overflowPath = Join-Path -Path $RootPath -ChildPath $OverflowFolderName
if (-not $WhatIf -and -not [Alphaleonis.Win32.Filesystem.Directory]::Exists($overflowPath)) {
    try {
        [Alphaleonis.Win32.Filesystem.Directory]::CreateDirectory($overflowPath) | Out-Null
        Write-Output "Created overflow folder: $overflowPath"
    } catch {
        Write-Error "Failed to create overflow folder '$overflowPath': $_"
    }
}

# ============================================================
# HELPER: Find a unique path by appending _2, _3, etc.
# ============================================================
function Get-UniquePath {
    param(
        [string]$DesiredPath,
        [switch]$IsDirectory
    )

    if ($IsDirectory) {
        if (-not [Alphaleonis.Win32.Filesystem.Directory]::Exists($DesiredPath)) { return $DesiredPath }
        for ($i = 2; $i -le 99999; $i++) {
            $candidate = "${DesiredPath}_$i"
            if (-not [Alphaleonis.Win32.Filesystem.Directory]::Exists($candidate)) { return $candidate }
        }
    } else {
        if (-not [Alphaleonis.Win32.Filesystem.File]::Exists($DesiredPath)) { return $DesiredPath }
        $dir  = [Alphaleonis.Win32.Filesystem.Path]::GetDirectoryName($DesiredPath)
        $name = [Alphaleonis.Win32.Filesystem.Path]::GetFileNameWithoutExtension($DesiredPath)
        $ext  = [Alphaleonis.Win32.Filesystem.Path]::GetExtension($DesiredPath)
        for ($i = 2; $i -le 99999; $i++) {
            $candidate = [Alphaleonis.Win32.Filesystem.Path]::Combine($dir, "${name}_$i${ext}")
            if (-not [Alphaleonis.Win32.Filesystem.File]::Exists($candidate)) { return $candidate }
        }
    }

    Write-Warning "Could not find a unique name for: $DesiredPath"
    return $null
}

# ============================================================
# HELPER: Retry wrapper for AlphaFS file/folder operations
# ============================================================
function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [string]$Description
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            & $Action
            return $true
        } catch {
            if ($attempt -ge $MaxRetries) {
                $script:errors++
                Write-Warning "  FAILED after $MaxRetries attempts: $Description — $_"
                return $false
            }
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
    return $false
}

# ============================================================
# HELPER: Truncate a file name to MaxFileNameLength, preserving
#         the extension. Returns the new full path after rename,
#         or the original path if no rename was needed.
# ============================================================
function Invoke-TruncateFileName {
    param(
        [string]$FilePath
    )

    $fileName = [Alphaleonis.Win32.Filesystem.Path]::GetFileName($FilePath)

    if ($fileName.Length -le $MaxFileNameLength) {
        return $FilePath
    }

    $dir      = [Alphaleonis.Win32.Filesystem.Path]::GetDirectoryName($FilePath)
    $baseName = [Alphaleonis.Win32.Filesystem.Path]::GetFileNameWithoutExtension($FilePath)
    $ext      = [Alphaleonis.Win32.Filesystem.Path]::GetExtension($FilePath)

    # Calculate how many characters the base name can keep (leave room for extension)
    $maxBase = $MaxFileNameLength - $ext.Length
    if ($maxBase -lt 1) { $maxBase = 1 }

    $newBase    = $baseName.Substring(0, [Math]::Min($baseName.Length, $maxBase))
    $newName    = "${newBase}${ext}"
    $newPath    = [Alphaleonis.Win32.Filesystem.Path]::Combine($dir, $newName)
    $uniquePath = Get-UniquePath -DesiredPath $newPath

    if (-not $uniquePath) {
        $script:errors++
        Write-Warning "  SKIP truncate (no unique name): $FilePath"
        return $FilePath
    }

    if ($WhatIf) {
        $script:renamed++
        Write-Host "  WHATIF: Would truncate '$fileName' -> '$([Alphaleonis.Win32.Filesystem.Path]::GetFileName($uniquePath))' ($($fileName.Length) -> $([Alphaleonis.Win32.Filesystem.Path]::GetFileName($uniquePath).Length) chars)"
        $script:reportEntries.Add([PSCustomObject]@{ Action = 'Truncated'; OldPath = $FilePath; NewPath = $uniquePath })
        return $uniquePath
    }

    $moveOptions = [Alphaleonis.Win32.Filesystem.MoveOptions]::ReplaceExisting
    $success = Invoke-WithRetry -Description "Truncate $FilePath" -Action {
        [Alphaleonis.Win32.Filesystem.File]::Move($FilePath, $uniquePath, $moveOptions)
    }

    if ($success) {
        $script:renamed++
        Write-Host "  TRUNCATED: '$fileName' -> '$([Alphaleonis.Win32.Filesystem.Path]::GetFileName($uniquePath))' ($($fileName.Length) -> $([Alphaleonis.Win32.Filesystem.Path]::GetFileName($uniquePath).Length) chars)"
        $script:reportEntries.Add([PSCustomObject]@{ Action = 'Truncated'; OldPath = $FilePath; NewPath = $uniquePath })
        return $uniquePath
    }

    return $FilePath
}

# ============================================================
# HELPER: Move an item to the overflow folder
# ============================================================
function Move-ToOverflow {
    param(
        [string]$ItemPath,
        [string]$ItemName,
        [switch]$IsDirectory
    )

    $destination = Join-Path -Path $overflowPath -ChildPath $ItemName
    $destination = Get-UniquePath -DesiredPath $destination -IsDirectory:$IsDirectory

    if (-not $destination) {
        $script:errors++
        Write-Warning "  SKIP move (no unique name): $ItemPath"
        return $false
    }

    if ($WhatIf) {
        $script:moved++
        Write-Output "  WHATIF: Would move '$ItemPath' -> '$destination' (relative path length: $(Get-RelativePathLength $ItemPath))"
        $destName = [Alphaleonis.Win32.Filesystem.Path]::GetFileName($destination)
        $script:reportEntries.Add([PSCustomObject]@{ Action = 'Moved'; OldPath = $ItemPath; NewPath = "$OverflowFolderName\$destName" })
        return $true
    }

    $moveOptions = [Alphaleonis.Win32.Filesystem.MoveOptions]::ReplaceExisting
    $success = Invoke-WithRetry -Description "Move $ItemPath" -Action {
        if ($IsDirectory) {
            [Alphaleonis.Win32.Filesystem.Directory]::Move($ItemPath, $destination, $moveOptions)
        } else {
            [Alphaleonis.Win32.Filesystem.File]::Move($ItemPath, $destination, $moveOptions)
        }
    }

    if ($success) {
        $script:moved++
        Write-Output "  MOVED: $ItemPath -> $destination (relative path length: $(Get-RelativePathLength $ItemPath))"
        $destName = [Alphaleonis.Win32.Filesystem.Path]::GetFileName($destination)
        $script:reportEntries.Add([PSCustomObject]@{ Action = 'Moved'; OldPath = $ItemPath; NewPath = "$OverflowFolderName\$destName" })
    }
    return $success
}

# ============================================================
# CORE: Recursively scan and fix paths/names that exceed limits
# ============================================================
function Invoke-ScanFolder {
    param(
        [string]$FolderPath
    )

    # Skip the overflow folder itself
    if ($FolderPath -eq $overflowPath) { return }

    try {
        $directories = @([Alphaleonis.Win32.Filesystem.Directory]::EnumerateDirectories($FolderPath, '*', [System.IO.SearchOption]::TopDirectoryOnly))
        $files       = @([Alphaleonis.Win32.Filesystem.Directory]::EnumerateFiles($FolderPath, '*', [System.IO.SearchOption]::TopDirectoryOnly))
    } catch {
        $script:errors++
        Write-Warning "  ERROR reading folder: $FolderPath — $_"
        return
    }

    # Process folders first — moving a folder removes all its children from the scan
    foreach ($dirPath in $directories) {
        $script:scanned++

        if ($dirPath -eq $overflowPath) { continue }

        # Skip excluded folders
        if (Test-Excluded -AbsolutePath $dirPath) { continue }

        # Skip folders that are completely outside the include scope
        if (-not (Test-InScope -AbsolutePath $dirPath)) { 
            Write-Output "  Skipping $dirPath because it is not in scope"
            continue 
        }

        # Determine if this folder is fully included (process its contents)
        # vs merely an ancestor we must traverse to reach an included subfolder
        $fullyIncluded = Test-FullyIncluded -AbsolutePath $dirPath

        if ($fullyIncluded -and (Get-RelativePathLength $dirPath) -ge $MaxPathLength) {
            $dirName = [Alphaleonis.Win32.Filesystem.Path]::GetFileName($dirPath)
            $null = Move-ToOverflow -ItemPath $dirPath -ItemName $dirName -IsDirectory
        } else {
            Invoke-ScanFolder -FolderPath $dirPath
        }
    }

    # Only process files if this folder is fully within the include scope
    $processFiles = Test-FullyIncluded -AbsolutePath $FolderPath
    if ($processFiles) {
        # Process files: truncate name first, then check full path length
        foreach ($filePath in $files) {
            $script:scanned++

            # Skip files in excluded folders
            if (Test-Excluded -AbsolutePath $filePath) { $script:skipped++; continue }

            try {
                $currentPath = $filePath

                # Step 1: Truncate file name if it exceeds MaxFileNameLength
                $currentPath = Invoke-TruncateFileName -FilePath $currentPath

                # Step 2: If the (possibly shortened) relative path still exceeds MaxPathLength, move to overflow
                if ((Get-RelativePathLength $currentPath) -ge $MaxPathLength) {
                    $fileName = [Alphaleonis.Win32.Filesystem.Path]::GetFileName($currentPath)
                    $null = Move-ToOverflow -ItemPath $currentPath -ItemName $fileName
                } else {
                    $script:skipped++
                }
            } catch {
                $script:errors++
                Write-Warning "  ERROR processing file: $filePath — $_"
            }
        }
    }
}

# ============================================================
# REPORT: Generate a self-contained, searchable HTML report
# ============================================================
function New-HtmlReport {
    # Ensure the overflow folder exists (needed in WhatIf mode for the report file)
    if (-not [Alphaleonis.Win32.Filesystem.Directory]::Exists($overflowPath)) {
        [Alphaleonis.Win32.Filesystem.Directory]::CreateDirectory($overflowPath) | Out-Null
    }

    $reportFile = [Alphaleonis.Win32.Filesystem.Path]::Combine($overflowPath, "_opruimrapport.html")
    $dateLabel  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build table rows
    $rows = [System.Text.StringBuilder]::new()
    $i = 0
    foreach ($entry in $script:reportEntries) {
        $i++
        $actionClass = if ($entry.Action -eq 'Moved') { 'action-moved' } else { 'action-truncated' }
        # Show paths relative to RootPath (strip the root prefix)
        $oldRelative = $entry.OldPath
        if ($oldRelative.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $oldRelative = $oldRelative.Substring($RootPath.Length)
        }
        $oldDisplay = [System.Net.WebUtility]::HtmlEncode($oldRelative)
        if ($entry.Action -eq 'Moved') {
            $newDisplay = [System.Net.WebUtility]::HtmlEncode($entry.NewPath)
        } else {
            $newRelative = $entry.NewPath
            if ($newRelative.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $newRelative = $newRelative.Substring($RootPath.Length)
            }
            $newDisplay = [System.Net.WebUtility]::HtmlEncode($newRelative)
        }
        $actionLabel = if ($entry.Action -eq 'Moved') { 'Verplaatst' } else { 'Ingekort' }
        $null = $rows.AppendLine("                    <tr><td>$i</td><td class=`"$actionClass`">$actionLabel</td><td>$oldDisplay</td><td>$newDisplay</td></tr>")
    }

    $html = @"
<!DOCTYPE html>
<html lang="nl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Opruimrapport</title>
    <style>
        *{box-sizing:border-box;margin:0;padding:0}
        body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:#f4f7f2;color:#2b2b2b;padding:0}
        .header-bar{background:linear-gradient(135deg,#00553a 0%,#1b7a4e 50%,#3a8f5c 100%);color:#fff;padding:2rem 2.5rem 1.5rem;position:relative;overflow:hidden}
        .header-bar::before{content:'';position:absolute;top:-40px;right:-40px;width:200px;height:200px;background:rgba(255,255,255,.06);border-radius:50%}
        .header-bar::after{content:'';position:absolute;bottom:-60px;left:30%;width:300px;height:300px;background:rgba(255,255,255,.03);border-radius:50%}
        .header-bar h1{font-size:1.85rem;font-weight:700;margin-bottom:.35rem;position:relative;z-index:1}
        .header-bar h1 span{opacity:.85;margin-right:.5rem}
        .header-bar .subtitle{color:rgba(255,255,255,.8);font-size:.95rem;position:relative;z-index:1}
        .container{max-width:1600px;margin:0 auto;padding:1.75rem 2.5rem 2rem}
        .card{background:#fff;border-radius:10px;padding:1.5rem 1.75rem;margin-bottom:1.25rem;box-shadow:0 1px 6px rgba(0,80,40,.08);border:1px solid #e2ebe5}
        .card h2{margin-bottom:.85rem;color:#00553a;font-size:1.15rem;font-weight:700;display:flex;align-items:center;gap:.45rem}
        .card h2::before{content:'';display:inline-block;width:4px;height:1.15rem;background:#7ab648;border-radius:2px}
        .stats{display:flex;gap:1rem;flex-wrap:wrap}
        .stat{background:#f4f7f2;border:1px solid #d6e4d0;border-radius:8px;padding:.9rem 1.3rem;min-width:135px;text-align:center;transition:transform .15s,box-shadow .15s}
        .stat:hover{transform:translateY(-2px);box-shadow:0 4px 12px rgba(0,80,40,.1)}
        .stat .value{font-size:1.85rem;font-weight:700;color:#00553a}
        .stat .value.errors{color:#c0392b}
        .stat .label{font-size:.78rem;color:#5a7a5a;margin-top:.2rem;text-transform:uppercase;letter-spacing:.3px}
        .explainer{border-left:4px solid #7ab648}
        .explainer p{line-height:1.7;color:#444;margin-bottom:.55rem}
        .explainer strong{color:#00553a}
        .explainer code{background:#edf5e7;padding:.15rem .45rem;border-radius:3px;font-size:.88em;color:#2d6a1e}
        .search-box{margin-bottom:.85rem}
        .search-box input{width:100%;max-width:500px;padding:.7rem 1rem;border:2px solid #d6e4d0;border-radius:8px;font-size:.95rem;outline:none;transition:border-color .2s,box-shadow .2s;background:#fafcf8}
        .search-box input:focus{border-color:#7ab648;box-shadow:0 0 0 3px rgba(122,182,72,.15)}
        .table-wrap{overflow-x:auto}
        table{width:100%;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden}
        thead th{background:#00553a;color:#fff;padding:.75rem 1rem;text-align:left;font-weight:600;position:sticky;top:0;white-space:nowrap;font-size:.85rem;text-transform:uppercase;letter-spacing:.3px}
        tbody tr{border-bottom:1px solid #e8f0e4;transition:background .15s}
        tbody tr:hover{background:#f0f7eb}
        tbody td{padding:.6rem 1rem;font-size:.85rem;word-break:break-all}
        tbody td:first-child{text-align:center;width:50px;color:#8faa85;font-weight:500;white-space:nowrap}
        .action-moved{color:#c0392b;font-weight:600;white-space:nowrap}
        .action-truncated{color:#d4830a;font-weight:600;white-space:nowrap}
        .no-results{text-align:center;padding:2rem;color:#8faa85;font-style:italic;display:none}
        .footer{margin-top:2rem;padding-top:1.25rem;border-top:1px solid #d6e4d0;text-align:center;color:#8faa85;font-size:.8rem}
        @media(max-width:768px){.container{padding:1rem}.header-bar{padding:1.5rem 1rem 1rem}.stats{flex-direction:column}}
    </style>
</head>
<body>
    <div class="header-bar">
        <h1><span>&#127795;</span> Opruimrapport</h1>
        <p class="subtitle">$dateLabel</p>
    </div>
    <div class="container">

        <div class="card explainer">
            <p>U kunt hier terugvinden welke <b>$($script:renamed + $script:moved)</b> bestanden en mappen zijn aangepast voor Online Samenwerken.</p>
        </div>

        <div class="card">
            <h2>Gewijzigde items ($($script:reportEntries.Count))</h2>
            <div class="search-box">
                <input type="text" id="searchInput" onkeyup="filterTable()" placeholder="Zoeken op pad of actie...">
            </div>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr><th>#</th><th>Actie</th><th>Oorspronkelijk pad</th><th>Nieuw pad</th></tr>
                    </thead>
                    <tbody>
$($rows.ToString())                    </tbody>
                </table>
            </div>
            <div id="noResults" class="no-results">Geen resultaten gevonden.</div>
        </div>
    </div>
    <script>
    function filterTable(){var e=document.getElementById("searchInput").value.toLowerCase(),t=document.querySelectorAll("tbody tr"),n=0;t.forEach(function(t){t.textContent.toLowerCase().indexOf(e)>-1?(t.style.display="",n++):t.style.display="none"});document.getElementById("noResults").style.display=0===n?"block":"none"}
    </script>
</body>
</html>
"@

    [Alphaleonis.Win32.Filesystem.File]::WriteAllText($reportFile, $html, [System.Text.Encoding]::UTF8)
    Write-Output ""
    Write-Output "  HTML report saved to: $reportFile"
}

# ============================================================
# MAIN
# ============================================================
$mode = if ($WhatIf) { "WhatIf (read-only)" } else { "Live (read-write)" }
Write-Output ""
Write-Output "ReducePaths — SPO Path & Name Reducer"
Write-Output "============================================"
Write-Output "  Root path:          $RootPath"
Write-Output "  Max path length:    $MaxPathLength"
Write-Output "  Max filename length: $MaxFileNameLength"
Write-Output "  Overflow folder:    $OverflowFolderName"
if ($script:hasIncludeFilter) {
    Write-Output "  Include folders:    $($IncludeFolders -join ', ')"
} else {
    Write-Output "  Include folders:    (all)"
}
if ($script:hasExcludeFilter) {
    Write-Output "  Exclude folders:    $($ExcludeFolders -join ', ')"
}
Write-Output "  Mode:               $mode"
Write-Output "============================================"
Write-Output ""

Invoke-ScanFolder -FolderPath $RootPath

Write-Output ""
Write-Output "============================================"
Write-Output "  Completed in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s"
Write-Output "  Items scanned:       $($script:scanned)"
Write-Output "  File names truncated: $($script:renamed)"
Write-Output "  Moved to overflow:   $($script:moved)"
Write-Output "  Already OK (skipped): $($script:skipped)"
Write-Output "  Errors:              $($script:errors)"
Write-Output "============================================"

# Generate HTML report if any items were changed
if ($script:reportEntries.Count -gt 0) {
    New-HtmlReport
} else {
    Write-Output ""
    Write-Output "  No changes needed - all items within SharePoint Online limits."
}

