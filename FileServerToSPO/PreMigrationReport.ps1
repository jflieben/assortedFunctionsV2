<#
    Generates a full HTML migration readiness report for a given fileshare and stores it in $outputFolder\$Title.
    Historical data from previous runs in that folder is loaded and compared against.
    Reduces file/folder paths and file names to comply with SharePoint Online limits.
    Author: Jos Lieben (Lieben Consultancy)
    Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Pure commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
    Git: https://github.com/jflieben/assortedFunctionsV2/blob/main/FileServerToSPO/PreMigrationReport.ps1
#>
param(
    [Parameter(Mandatory = $true)][String]$RootPath, #e.g g:\Finance
    [Parameter(Mandatory = $true)][String]$Title, #report title, e.g. Finance
    [Parameter(Mandatory = $true)][String]$outputFolder, #e.g. c:\temp\reports (a folder $Title will be created if it doesn't exist yet)
    [String]$ExcludeFolderPattern = '', #optional regex; folders whose full path matches are skipped with their whole subtree (e.g. '_ToDelete|_Trash')
    [int]$ThrottleLimit = 8,
    [int]$MaxXlsxRows = 1048575,
    [int]$XlsxTimeoutMinutes = 60
)

$outputFolder = [System.IO.Path]::GetFullPath($outputFolder, (Get-Location).Path)
$reportDir = Join-Path $outputFolder $Title
[string]$CsvPath       = Join-Path $reportDir "sourcedata.csv"
[string]$OutputXlsx    = Join-Path $reportDir "source_annotated.xlsx"
[string]$OutputHtml    = Join-Path $reportDir "report.html"
[string]$OutputJs      = Join-Path $reportDir "report.js"
[string]$OutputHistory = Join-Path $reportDir "historicaldata.json"

$ErrorActionPreference = "Stop"

#load prereqs
Import-Module ActiveDirectory
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "Installing ImportExcel module..." -ForegroundColor Yellow
    Install-Module -Name ImportExcel -Force -Scope CurrentUser
}
Import-Module ImportExcel

# Use Get-Item instead of Test-Path -PathType Container: some roots are DFS
# reparse-point symlinks (Mode l----, Attributes Directory,ReparsePoint). Test-Path -PathType
# Container returns $false for those links, whereas Get-Item follows the reparse point and
# reports PSIsContainer correctly.
$rootProbe = $null
try {
    $rootProbe = Get-Item -LiteralPath $RootPath -Force -ErrorAction Stop
}
catch {
    Write-Error "Path '$RootPath' does not exist or is not accessible: $_"
    exit 1
}
if (-not $rootProbe.PSIsContainer) {
    Write-Error "Path '$RootPath' is not a directory."
    exit 1
}

if ([System.IO.Path]::GetExtension($CsvPath) -ne ".csv") {
    Write-Warning "CsvPath does not end with .csv. Continuing anyway."
}

$outputDir = Split-Path -Parent $CsvPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$rootItem = $rootProbe
$rootPathStr = $rootItem.FullName.TrimEnd('\')
$nowUtc = (Get-Date).ToUniversalTime()

$tempExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@('.tmp', '.temp', '.bak', '.old', '.log', '.dmp', '.cache', '.chk', '.etl') | ForEach-Object { [void]$tempExtensions.Add($_) }

# ── Macro / external-reference detection setup ──
# Extensions inspected for either VBA macros (Office/Access) or external path refs (QGIS)
$macroCapableExts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    # QGIS project files (external path scan only)
    '.qgs', '.qgz',
    # OOXML macro-enabled
    '.xlsm', '.xltm', '.xlam', '.xlsb',
    '.docm', '.dotm',
    '.pptm', '.potm', '.ppsm', '.ppam', '.sldm',
    # Legacy OLE formats (may contain macros)
    '.xls', '.xlt', '.xla',
    '.doc', '.dot', '.wiz',
    '.ppt', '.pps', '.pot', '.ppa',
    # Access
    '.mdb', '.mde', '.accdb', '.accde', '.accdr'
) | ForEach-Object { [void]$macroCapableExts.Add($_) }

# Patterns that indicate external access in VBA code
$externalPatterns = @(
    '(?i)https?://[A-Za-z0-9]',                    # HTTP/HTTPS URLs (must have host start)
    '(?i)\\\\[A-Za-z][A-Za-z0-9_.-]+\\',      # UNC paths (\\server\share)
    '(?i)g:\\',                                     # G-drive paths (g:\)
    '(?i)WScript\.Shell',                          # WScript shell object
    '(?i)CreateObject\s*\(\s*"',                  # COM object creation with string arg
    '(?i)GetObject\s*\(\s*"',                     # COM object binding with string arg
    '(?i)XMLHTTP|WinHttp\.WinHttpRequest|ServerXMLHTTP', # HTTP objects (specific names)
    '(?i)ADODB\.(?:Connection|Recordset|Command)',  # Database connections (specific)
    '(?i)Environ\s*\(',                            # Environment variables
    '(?i)Declare\s+(PtrSafe\s+)?(?:Sub|Function)\s+\w+\s+Lib\s+"', # DLL declarations
    '(?i)URLDownloadToFile',                        # URL downloads
    '(?i)Scripting\.FileSystemObject',              # File system access COM object
    '(?i)Shell\s*\(|Shell\s+"',                  # Shell() function call or Shell "cmd"
    '(?i)cmd\.exe|command\.com|powershell\.exe',  # Command execution (specific executables)
    '(?i)SendKeys\s',                               # Keystroke injection (with space after)
    '(?i)Workbooks\.Open\s*\(|Documents\.Open\s*\(' # Opening external files (with paren)
)

# QGIS files are not macro-enabled, but may reference external network/drive paths.
$qgisExternalPatterns = @(
    '(?i)\\\\[A-Za-z][A-Za-z0-9_.-]+\\[^\s"<>|]*', # UNC paths (\\server\share\...)
    '(?i)\bg:\\[^\s"<>|]*',                            # G-drive paths (g:\...)
    '(?i)\bh:\\[^\s"<>|]*'                             # H-drive paths (h:\...)
)

function Get-MacroInfo {
    <#
    .SYNOPSIS
        Inspects an Office file for VBA macros and classifies them.
    .DESCRIPTION
        For OOXML files (.xlsm, .docm, etc.) opens as ZIP and looks for vbaProject.bin.
        For legacy OLE files (.xls, .doc, etc.) scans binary for VBA signatures.
        Extracts readable strings from VBA project and classifies as Internal or External.
    .OUTPUTS
        PSCustomObject with HasMacros, MacroType, MacroDetails
    #>
    param([System.IO.FileInfo]$File)

    $result = [PSCustomObject]@{ HasMacros = $false; MacroType = 'None'; MacroDetails = '' }

    try {
        $ext = $File.Extension.ToLowerInvariant()
        $vbaBytes = $null

        # --- QGIS project files (.qgs text XML / .qgz zipped project) ---
        if ($ext -in '.qgs', '.qgz') {
            $qgisText = ''

            if ($ext -eq '.qgs') {
                try {
                    $qgisText = [System.IO.File]::ReadAllText($File.FullName)
                } catch {
                    $result.MacroDetails = "Could not read QGS: $($_.Exception.Message)"
                    return $result
                }
            }
            else {
                try {
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
                    try {
                        $qgsEntry = $zip.Entries |
                            Where-Object { $_.FullName -match '(?i)\.qgs$' } |
                            Select-Object -First 1

                        if (-not $qgsEntry) {
                            $result.MacroDetails = 'QGZ archive has no embedded .qgs file'
                            return $result
                        }

                        $stream = $qgsEntry.Open()
                        try {
                            $reader = [System.IO.StreamReader]::new($stream)
                            try {
                                $qgisText = $reader.ReadToEnd()
                            } finally {
                                $reader.Dispose()
                            }
                        } finally {
                            $stream.Dispose()
                        }
                    } finally {
                        $zip.Dispose()
                    }
                } catch {
                    $result.MacroDetails = "Could not open QGZ: $($_.Exception.Message)"
                    return $result
                }
            }

            $qgisMatches = [System.Collections.Generic.List[string]]::new()
            foreach ($pattern in $qgisExternalPatterns) {
                $matches = [regex]::Matches($qgisText, $pattern)
                foreach ($m in $matches) {
                    $matchVal = $m.Value.Trim()
                    if ($matchVal -and -not $qgisMatches.Contains($matchVal)) {
                        $qgisMatches.Add($matchVal)
                    }
                }
            }

            if ($qgisMatches.Count -gt 0) {
                $result.MacroType = 'External'
                $result.HasMacros = $true
                $details = ($qgisMatches | Select-Object -First 10) -join '; '
                if ($qgisMatches.Count -gt 10) { $details += "; ... (+$($qgisMatches.Count - 10) more)" }
                $result.MacroDetails = "QGIS external paths: $details"
            }
            else {
                $result.MacroType = 'Internal'
                $result.MacroDetails = 'QGIS project scanned, no UNC/G:/H: paths found'
            }

            return $result
        }

        # --- OOXML (ZIP-based) formats ---
        if ($ext -in '.xlsm','.xltm','.xlam','.xlsb','.docm','.dotm','.pptm','.potm','.ppsm','.ppam','.sldm') {
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
                try {
                    $vbaEntry = $zip.Entries | Where-Object { $_.FullName -match '(?i)vbaProject\.bin$' } | Select-Object -First 1
                    if ($vbaEntry) {
                        $result.HasMacros = $true
                        $stream = $vbaEntry.Open()
                        $ms = [System.IO.MemoryStream]::new()
                        $stream.CopyTo($ms)
                        $vbaBytes = $ms.ToArray()
                        $ms.Dispose()
                        $stream.Dispose()
                    }
                } finally {
                    $zip.Dispose()
                }
            } catch {
                # File may be corrupted or password-protected
                $result.MacroDetails = "Could not open ZIP: $($_.Exception.Message)"
                return $result
            }
        }
        # --- Legacy OLE (binary) formats ---
        elseif ($ext -in '.xls','.xlt','.xla','.doc','.dot','.wiz','.ppt','.pps','.pot','.ppa','.mdb','.mde','.accdb','.accde','.accdr') {
            # Stream in chunks instead of ReadAllBytes: legacy Access/Excel files can be GBs, and
            # holding the byte array plus ASCII and UTF-16 string copies tripled that in memory.
            # The chunk overlap keeps marker/path strings that straddle a boundary intact; the
            # even step size preserves UTF-16 alignment across chunks.
            $legacyFormat = $true
            $chunkOverlap = 1024
            if (-not $chunkBuffer) { $chunkBuffer = [byte[]]::new(4MB) }
            try {
                # Look for definitive VBA project markers (not just metadata)
                # _VBA_PROJECT_CUR is the OLE stream name for VBA projects
                # 'Attribute VB_Name' is the VBA module header
                $markerRegex = [regex]'_VBA_PROJECT|Attribute VB_Name|Attribute VB_Base|Attribute VB_GlobalNameSpace|VBAProject|\x00VBA\x00'
                $fs = [System.IO.File]::OpenRead($File.FullName)
                try {
                    $pos = [long]0
                    while ($true) {
                        $fs.Position = $pos
                        $read = $fs.Read($chunkBuffer, 0, $chunkBuffer.Length)
                        if ($read -le 0) { break }
                        $asciiChunk = [System.Text.Encoding]::ASCII.GetString($chunkBuffer, 0, $read)
                        if ($markerRegex.IsMatch($asciiChunk)) { $result.HasMacros = $true; break }
                        if ($read -lt $chunkBuffer.Length) { break }
                        $pos += ($chunkBuffer.Length - $chunkOverlap)
                    }
                } finally { $fs.Dispose() }
                if (-not $result.HasMacros) { return $result }
            } catch {
                $result.MacroDetails = "Could not read file: $($_.Exception.Message)"
                return $result
            }
        }
        else {
            return $result
        }

        # --- Classify macro content ---
        if ($result.HasMacros) {
            $externalMatches = [System.Collections.Generic.List[string]]::new()

            # Extracts printable ASCII + UTF-16LE string runs (min 8 chars) from a byte buffer —
            # avoids matching random binary data — and records external-access pattern matches.
            $scanBuffer = {
                param([byte[]]$bytes, [int]$byteCount)
                $printableRuns = [System.Collections.Generic.List[string]]::new()
                $asciiStr = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $byteCount)
                foreach ($rm in [regex]::Matches($asciiStr, '[\x20-\x7E]{8,}')) { $printableRuns.Add($rm.Value) }
                # Also extract UTF-16LE printable runs (VBA stores some strings as UTF-16)
                $utf16Str = [System.Text.Encoding]::Unicode.GetString($bytes, 0, $byteCount)
                foreach ($rm in [regex]::Matches($utf16Str, '[\x20-\x7E]{8,}')) { $printableRuns.Add($rm.Value) }
                $combinedText = $printableRuns -join "`n"
                foreach ($pattern in $externalPatterns) {
                    foreach ($m in [regex]::Matches($combinedText, $pattern)) {
                        $matchVal = $m.Value.Trim()
                        if ($matchVal -and -not $externalMatches.Contains($matchVal)) {
                            $externalMatches.Add($matchVal)
                        }
                    }
                }
            }

            $extracted = $false
            if ($vbaBytes) {
                # OOXML: vbaProject.bin is small enough to scan in one piece
                & $scanBuffer $vbaBytes $vbaBytes.Length
                $extracted = $true
            }
            elseif ($legacyFormat) {
                # Legacy OLE: stream the file again in chunks; only macro-bearing files pay this cost
                try {
                    $fs = [System.IO.File]::OpenRead($File.FullName)
                    try {
                        $pos = [long]0
                        while ($true) {
                            $fs.Position = $pos
                            $read = $fs.Read($chunkBuffer, 0, $chunkBuffer.Length)
                            if ($read -le 0) { break }
                            & $scanBuffer $chunkBuffer $read
                            if ($read -lt $chunkBuffer.Length) { break }
                            $pos += ($chunkBuffer.Length - $chunkOverlap)
                        }
                        $extracted = $true
                    } finally { $fs.Dispose() }
                } catch { }
            }

            if (-not $extracted) {
                $result.MacroType = 'Internal'
                $result.MacroDetails = 'VBA project present but could not extract content'
            }
            elseif ($externalMatches.Count -gt 0) {
                $result.MacroType = 'External'
                # Collect unique match categories (limit detail length)
                $details = ($externalMatches | Select-Object -First 10) -join '; '
                if ($externalMatches.Count -gt 10) { $details += "; ... (+$($externalMatches.Count - 10) more)" }
                $result.MacroDetails = $details
            } else {
                $result.MacroType = 'Internal'
                $result.MacroDetails = 'Macros detected, no external references found'
            }
        }
    }
    catch {
        $result.MacroDetails = "Scan error: $($_.Exception.Message)"
    }

    return $result
}

# Load .NET ZIP support
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Load ACL support: FileSecurity/DirectorySecurity DACL-only reads are far cheaper than Get-Acl,
# which also fetches owner/group and translates every SID on every call.
try {
    Add-Type -AssemblyName System.IO.FileSystem.AccessControl -ErrorAction Stop
} catch {
    # Referencing Get-Acl force-loads Microsoft.PowerShell.Security, which carries the same assembly
    try { $null = Get-Acl -LiteralPath $rootPathStr } catch { }
}
# LDAP fallback for SID resolution (LSA translation of domain SIDs fails on this hybrid worker)
try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop } catch { }

# Resolves an ACE identity (SID) to DOMAIN\name, cached per distinct SID in $sidNameCache.
# LSA translation (Translate) fails for domain SIDs in certain scenario's (e.g. azure hybrid workers), 
# so fall back to an LDAP query against the joined domain.
function Resolve-AceIdentity {
    param([System.Security.Principal.IdentityReference]$IdentityReference)
    $sidStr = $IdentityReference.Value
    $name = $null
    if ($sidNameCache.TryGetValue($sidStr, [ref]$name)) { return $name }
    try {
        $name = $IdentityReference.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        if ($sidStr -like 'S-1-5-21-*') {
            try {
                $searcher = [System.DirectoryServices.DirectorySearcher]::new("(objectSid=$sidStr)")
                try {
                    $null = $searcher.PropertiesToLoad.Add('sAMAccountName')
                    $found = $searcher.FindOne()
                    if ($found -and $found.Properties['samaccountname'].Count -gt 0) {
                        $name = "$($found.Properties['samaccountname'][0])"
                    }
                } finally { $searcher.Dispose() }
            } catch { }
        }
        if (-not $name) { $name = $sidStr }
    }
    $null = $sidNameCache.TryAdd($sidStr, $name)
    return $name
}

# ── Stage 1: discover the directory tree (parallel breadth-first walk) ──
# Replaces Get-ChildItem -Recurse, which enumerated single-threaded and materialized every
# FileSystemInfo in memory at once. Paths matching $ExcludeFolderPattern are pruned with their
# whole subtree (every descendant carries the name in its FullName). Reparse-point directories
# are listed but not traversed, matching Get-ChildItem -Recurse without -FollowSymlink.
Write-Host "Discovering directories under '$rootPathStr'..." -ForegroundColor Cyan
$swScan = [System.Diagnostics.Stopwatch]::StartNew()

$dirWork = [System.Collections.Generic.List[object]]::new()
$dirWork.Add([PSCustomObject]@{
    Path = $rootPathStr; IsRoot = $true; IsReparse = $false
    Attributes = $rootItem.Attributes
    CreatedUtc = $rootItem.CreationTimeUtc; LastWriteUtc = $rootItem.LastWriteTimeUtc; LastAccessUtc = $rootItem.LastAccessTimeUtc
})

$frontier = [System.Collections.Generic.List[string]]::new()
$frontier.Add($rootPathStr)
while ($frontier.Count -gt 0) {
    $frontierBatches = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $frontier.Count; $i += 64) {
        $frontierBatches.Add($frontier.GetRange($i, [math]::Min(64, $frontier.Count - $i)))
    }
    $discovered = @($frontierBatches | ForEach-Object -Parallel {
        $excludePattern = $using:ExcludeFolderPattern
        foreach ($dirPath in $_) {
            try {
                foreach ($sub in [System.IO.DirectoryInfo]::new($dirPath).EnumerateDirectories()) {
                    if ($excludePattern -and $sub.FullName -match $excludePattern) { continue }
                    [PSCustomObject]@{
                        Path = $sub.FullName; IsRoot = $false
                        IsReparse = (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                        Attributes = $sub.Attributes
                        CreatedUtc = $sub.CreationTimeUtc; LastWriteUtc = $sub.LastWriteTimeUtc; LastAccessUtc = $sub.LastAccessTimeUtc
                    }
                }
            } catch {
                Write-Warning "Could not enumerate subdirectories of '$dirPath': $($_.Exception.Message)"
            }
        }
    } -ThrottleLimit $ThrottleLimit)

    $frontier = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $discovered) {
        $dirWork.Add($d)
        if (-not $d.IsReparse) { $frontier.Add($d.Path) }
    }
}
Write-Host "  Discovered $($dirWork.Count) directories in $([math]::Round($swScan.Elapsed.TotalSeconds,1))s" -ForegroundColor Cyan

# ── Stage 2: scan directories in parallel ──
# Each work item is a batch of directories; per directory the worker produces the folder row
# (broken-inheritance check) and one row per file (metadata, DACL check, macro scan).
# ACLs are read DACL-only with explicit (non-inherited) rules requested by SID; SID→name
# translation is cached process-wide so each distinct group hits the domain controller once
# instead of once per file.
Write-Host "Scanning files and permissions with $ThrottleLimit parallel workers..." -ForegroundColor Cyan

$macroFnDef   = ${function:Get-MacroInfo}.ToString()
$resolveFnDef = ${function:Resolve-AceIdentity}.ToString()
$sidNameCache = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

# Process-wide atomic counters (PowerShell [ref] on an array element is not atomic across runspaces)
if (-not ('SpoScanCounter' -as [type])) {
    Add-Type -TypeDefinition @'
public static class SpoScanCounter {
    public static long Value;
    public static long AclErrors;
    public static long ExplicitAces;
    public static long DfMatches;
    public static long Increment() { return System.Threading.Interlocked.Increment(ref Value); }
    public static void AddAclError() { System.Threading.Interlocked.Increment(ref AclErrors); }
    public static void AddExplicitAces() { System.Threading.Interlocked.Increment(ref ExplicitAces); }
    public static void AddDfMatch() { System.Threading.Interlocked.Increment(ref DfMatches); }
}
'@
}
[SpoScanCounter]::Value = 0
[SpoScanCounter]::AclErrors = 0
[SpoScanCounter]::ExplicitAces = 0
[SpoScanCounter]::DfMatches = 0

$dirBatches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $dirWork.Count; $i += 25) {
    $dirBatches.Add($dirWork.GetRange($i, [math]::Min(25, $dirWork.Count - $i)))
}

$rows = @($dirBatches | ForEach-Object -Parallel {
    ${function:Get-MacroInfo}       = [scriptblock]::Create($using:macroFnDef)
    ${function:Resolve-AceIdentity} = [scriptblock]::Create($using:resolveFnDef)
    $externalPatterns     = $using:externalPatterns
    $qgisExternalPatterns = $using:qgisExternalPatterns
    $tempExtensions       = $using:tempExtensions
    $macroCapableExts     = $using:macroCapableExts
    $sidNameCache         = $using:sidNameCache
    $swScan               = $using:swScan
    $rootPathStr          = $using:rootPathStr
    $nowUtc               = $using:nowUtc
    $excludePattern       = $using:ExcludeFolderPattern
    $chunkBuffer          = [byte[]]::new(4MB)   # reused by Get-MacroInfo for legacy OLE streaming

    # Returns the joined explicit-ACE string, '' when none, $null when the ACL is unreadable
    function Get-DfAclString {
        param([string]$Path, [bool]$IsDirectory)
        try {
            $sections = [System.Security.AccessControl.AccessControlSections]::Access
            $sec = if ($IsDirectory) { [System.Security.AccessControl.DirectorySecurity]::new($Path, $sections) }
                   else { [System.Security.AccessControl.FileSecurity]::new($Path, $sections) }
        } catch { [SpoScanCounter]::AddAclError(); return $null }
        $entries = $null
        $sawExplicit = $false
        foreach ($rule in $sec.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
            $sawExplicit = $true
            $name = Resolve-AceIdentity $rule.IdentityReference
            if (-not $entries) { $entries = [System.Collections.Generic.List[string]]::new() }
            $entries.Add("$($name):$($rule.FileSystemRights.ToString())")
        }
        if ($sawExplicit) { [SpoScanCounter]::AddExplicitAces() }
        if ($entries) { [SpoScanCounter]::AddDfMatch(); return (($entries | Sort-Object -Unique) -join '; ') }
        return ''
    }

    foreach ($dirEntry in $_) {
        $dirPath = $dirEntry.Path
        $dirRel = [System.IO.Path]::GetRelativePath($rootPathStr, $dirPath)

        # ── Folder row (only folders with unique permissions are kept; the root itself is not reported) ──
        if (-not $dirEntry.IsRoot) {
            try {
                $dfGroups = Get-DfAclString -Path $dirPath -IsDirectory $true
                $hasUniquePermissions = if ($null -eq $dfGroups) { "Error" } elseif ($dfGroups) { $True } else { $False }
                if ($null -eq $dfGroups) { $dfGroups = '' }

                if ($hasUniquePermissions -eq $True -or $hasUniquePermissions -eq "Error") {
                    if ($hasUniquePermissions -eq $True) {
                        Write-Host "[Folder] $dirRel has unique permissions" -ForegroundColor Yellow
                    }
                    $parentRelativePath = [System.IO.Path]::GetRelativePath($rootPathStr, [System.IO.Path]::GetDirectoryName($dirPath))
                    if ($parentRelativePath -eq ".") { $parentRelativePath = "\" }
                    $ageDays = [int][math]::Floor(($nowUtc - $dirEntry.LastWriteUtc).TotalDays)
                    $ageBucket = if ($ageDays -le 30) { "0-30d" }
                        elseif ($ageDays -le 90) { "30-90d" }
                        elseif ($ageDays -le 365) { "90-365d" }
                        elseif ($ageDays -le 1095) { "1-3y" }
                        elseif ($ageDays -le 1825) { "3-5y" }
                        elseif ($ageDays -le 2555) { "5-7y" }
                        elseif ($ageDays -le 3650) { "7-10y" }
                        else { "10y+" }

                    [PSCustomObject]@{
                        ItemType                  = "Folder"
                        FileName                  = [System.IO.Path]::GetFileName($dirPath)
                        Extension                 = ""
                        RelativePath              = $dirRel
                        ParentRelativePath        = $parentRelativePath
                        FullPath                  = $dirPath
                        SizeBytes                 = 0
                        SizeMB                    = 0
                        CreatedUtc                = $dirEntry.CreatedUtc
                        LastWriteUtc              = $dirEntry.LastWriteUtc
                        LastAccessUtc             = $dirEntry.LastAccessUtc
                        AgeDays                   = $ageDays
                        AgeBucket                 = $ageBucket
                        IsReadOnly                = $false
                        IsHidden                  = (($dirEntry.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
                        UniquePermissions         = $hasUniquePermissions
                        UniqueACLs               = $dfGroups
                        IsLikelyTemporary         = $false
                        IsLargeFile               = $false
                        HasMacros                 = $false
                        MacroType                 = "N/A"
                        MacroDetails              = ""
                        DuplicateBySizeCount      = 0
                        DuplicateBySizeId         = ""
                        DuplicateByNameSizeCount  = 0
                        DuplicateByNameSizeId     = ""
                    }
                }
            }
            catch {
                Write-Warning "Skipped folder '$dirPath' due to error: $_"
            }
        }

        # ── File rows (reparse-point directories are listed above but not traversed) ──
        if ($dirEntry.IsReparse) { continue }
        $parentRelForFiles = if ($dirRel -eq ".") { "\" } else { $dirRel }
        try {
            foreach ($file in [System.IO.DirectoryInfo]::new($dirPath).EnumerateFiles()) {
                try {
                    if ($excludePattern -and $file.FullName -match $excludePattern) { continue }
                    $relativePath = if ($dirRel -eq ".") { $file.Name } else { "$dirRel\$($file.Name)" }

                    $ageDays = [int][math]::Floor(($nowUtc - $file.LastWriteTimeUtc).TotalDays)
                    $ageBucket = if ($ageDays -le 30) { "0-30d" }
                        elseif ($ageDays -le 90) { "30-90d" }
                        elseif ($ageDays -le 365) { "90-365d" }
                        elseif ($ageDays -le 1095) { "1-3y" }
                        elseif ($ageDays -le 1825) { "3-5y" }
                        elseif ($ageDays -le 2555) { "5-7y" }
                        elseif ($ageDays -le 3650) { "7-10y" }
                        else { "10y+" }

                    $dfGroups = Get-DfAclString -Path $file.FullName -IsDirectory $false
                    $hasUniquePermissions = if ($null -eq $dfGroups) { "Error" } elseif ($dfGroups) { $True } else { $False }
                    if ($null -eq $dfGroups) { $dfGroups = '' }

                    # ── Macro detection ──
                    $hasMacros = $false
                    $macroType = 'None'
                    $macroDetails = ''
                    if ($macroCapableExts.Contains($file.Extension)) {
                        $macroInfo = Get-MacroInfo -File $file
                        $hasMacros = $macroInfo.HasMacros
                        $macroType = $macroInfo.MacroType
                        $macroDetails = $macroInfo.MacroDetails
                        if ($hasMacros) {
                            $color = if ($macroType -eq 'External') { 'Red' } else { 'DarkYellow' }
                            Write-Host "[Macro:$macroType] $relativePath" -ForegroundColor $color
                        }
                    }

                    [PSCustomObject]@{
                        ItemType                  = "File"
                        FileName                  = $file.Name
                        Extension                 = $file.Extension
                        RelativePath              = $relativePath
                        ParentRelativePath        = $parentRelForFiles
                        FullPath                  = $file.FullName
                        SizeBytes                 = [int64]$file.Length
                        SizeMB                    = [math]::Round(($file.Length / 1MB), 3)
                        CreatedUtc                = $file.CreationTimeUtc
                        LastWriteUtc              = $file.LastWriteTimeUtc
                        LastAccessUtc             = $file.LastAccessTimeUtc
                        AgeDays                   = $ageDays
                        AgeBucket                 = $ageBucket
                        IsReadOnly                = (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
                        IsHidden                  = (($file.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
                        UniquePermissions         = $hasUniquePermissions
                        UniqueACLs               = $dfGroups
                        IsLikelyTemporary         = $tempExtensions.Contains($file.Extension)
                        IsLargeFile               = ($file.Length -ge 100MB)
                        HasMacros                 = $hasMacros
                        MacroType                 = $macroType
                        MacroDetails              = $macroDetails
                        DuplicateBySizeCount      = 1
                        DuplicateBySizeId         = ""
                        DuplicateByNameSizeCount  = 1
                        DuplicateByNameSizeId     = ""
                    }

                    $n = [SpoScanCounter]::Increment()
                    if ($n % 25000 -eq 0) {
                        $rate = [math]::Round($n / [math]::Max($swScan.Elapsed.TotalSeconds, 1))
                        Write-Host "  $n files scanned so far ($rate files/sec)..." -ForegroundColor DarkCyan
                    }
                }
                catch {
                    Write-Warning "Skipped file '$($file.FullName)' due to error: $_"
                }
            }
        }
        catch {
            Write-Warning "Could not enumerate files in '$dirPath': $($_.Exception.Message)"
        }
    }
} -ThrottleLimit $ThrottleLimit)

Write-Host "Scanned $([SpoScanCounter]::Value) files across $($dirWork.Count) directories in $([math]::Round($swScan.Elapsed.TotalMinutes,1)) min" -ForegroundColor Cyan

# ── ACL diagnostics: explains an empty 'Unique permissions' page ──
Write-Host "ACL diagnostics: $([SpoScanCounter]::ExplicitAces) items with explicit ACEs | $([SpoScanCounter]::DfMatches) all | $([SpoScanCounter]::AclErrors) unreadable ACLs" -ForegroundColor Cyan
if ($sidNameCache.Count -gt 0) {
    Write-Host "Distinct identities seen in explicit ACEs (max 40 of $($sidNameCache.Count)):" -ForegroundColor Cyan
    foreach ($idName in ($sidNameCache.Values | Sort-Object -Unique | Select-Object -First 40)) {
        Write-Host "  $idName"
    }
} elseif ([SpoScanCounter]::AclErrors -gt 0) {
    Write-Host "No ACLs could be read at all - the scan identity likely lacks READ_CONTROL on this share." -ForegroundColor Yellow
} else {
    Write-Host "No explicit (non-inherited) ACEs found anywhere in this tree." -ForegroundColor Yellow
}

# SIDs that neither LSA nor LDAP could resolve: check AD to distinguish a deleted group
# (orphaned ACE, data genuinely gone) from a lookup problem on this worker.
$unresolvedSids = @($sidNameCache.GetEnumerator() | Where-Object { $_.Value -eq $_.Key -and $_.Key -like 'S-1-5-21-*' } | ForEach-Object { $_.Key })
if ($unresolvedSids.Count -gt 0) {
    Write-Host "Verifying $($unresolvedSids.Count) unresolved domain SIDs against AD (max 40):" -ForegroundColor Cyan
    foreach ($sid in ($unresolvedSids | Sort-Object | Select-Object -First 40)) {
        $status = 'NOT FOUND in AD - group was deleted, ACE is orphaned'
        try {
            $adObj = @(Get-ADObject -Filter "objectSid -eq '$sid'" -Properties sAMAccountName -ErrorAction Stop)
            if ($adObj.Count -gt 0) { $status = "exists in AD as '$($adObj[0].sAMAccountName)' but could not be resolved on this worker" }
        } catch { $status = "AD lookup failed: $($_.Exception.Message)" }
        Write-Host "  $sid -> $status" -ForegroundColor Yellow
    }
}

Write-Host "Analyzing duplicate candidates..." -ForegroundColor Cyan

# Partition rows once and pick up summary counters in the same pass
$fileRows   = [System.Collections.Generic.List[object]]::new()
$folderRows = [System.Collections.Generic.List[object]]::new()
$totalSizeBytes = [long]0
foreach ($r in $rows) {
    if ($r.ItemType -eq "File") { $fileRows.Add($r); $totalSizeBytes += [long]$r.SizeBytes }
    else { $folderRows.Add($r) }
}

# Dictionary-based duplicate grouping (Group-Object needs minutes and GBs of memory at this scale)
$sizeCounts     = [System.Collections.Generic.Dictionary[long,int]]::new()
$nameSizeCounts = [System.Collections.Generic.Dictionary[string,int]]::new()
foreach ($r in $fileRows) {
    $sz = [long]$r.SizeBytes
    $sizeCounts[$sz] = ($sizeCounts.ContainsKey($sz) ? $sizeCounts[$sz] : 0) + 1
    $key = "$sz|$($r.FileName.ToLowerInvariant())"
    $nameSizeCounts[$key] = ($nameSizeCounts.ContainsKey($key) ? $nameSizeCounts[$key] : 0) + 1
}

$sizeIds     = [System.Collections.Generic.Dictionary[long,string]]::new()
$nameSizeIds = [System.Collections.Generic.Dictionary[string,string]]::new()
$sizeGroupId = 0
$nameGroupId = 0
foreach ($r in $fileRows) {
    $sz = [long]$r.SizeBytes
    if ($sizeCounts[$sz] -gt 1) {
        if (-not $sizeIds.ContainsKey($sz)) { $sizeGroupId++; $sizeIds[$sz] = ("S{0:D6}" -f $sizeGroupId) }
        $r.DuplicateBySizeCount = $sizeCounts[$sz]
        $r.DuplicateBySizeId    = $sizeIds[$sz]
    }
    $key = "$sz|$($r.FileName.ToLowerInvariant())"
    if ($nameSizeCounts[$key] -gt 1) {
        if (-not $nameSizeIds.ContainsKey($key)) { $nameGroupId++; $nameSizeIds[$key] = ("N{0:D6}" -f $nameGroupId) }
        $r.DuplicateByNameSizeCount = $nameSizeCounts[$key]
        $r.DuplicateByNameSizeId    = $nameSizeIds[$key]
    }
}

Write-Host "Exporting $($rows.Count) rows to '$CsvPath'..." -ForegroundColor Cyan
$rows |
    Sort-Object -Property `
        @{ Expression = "DuplicateByNameSizeCount"; Descending = $true }, `
        @{ Expression = "DuplicateBySizeCount"; Descending = $true }, `
        @{ Expression = "AgeDays"; Descending = $true }, `
        @{ Expression = "SizeBytes"; Descending = $true } |
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

$totalSizeGB = [math]::Round(($totalSizeBytes / 1GB), 2)
$macroFileCount = 0; $macroExternalCount = 0; $macroInternalCount = 0
foreach ($r in $fileRows) {
    if ($r.HasMacros -eq $true) {
        $macroFileCount++
        if ($r.MacroType -eq 'External') { $macroExternalCount++ }
        elseif ($r.MacroType -eq 'Internal') { $macroInternalCount++ }
    }
}

Write-Host "Report generated successfully." -ForegroundColor Green
Write-Host "Files: $($fileRows.Count) | Folders with unique permissions: $($folderRows.Count) | Total Size (GB): $totalSizeGB" -ForegroundColor Green
Write-Host "Macros: $macroFileCount total ($macroExternalCount external, $macroInternalCount internal)" -ForegroundColor Yellow

# Free the scan structures before phase 2 re-imports the CSV (roughly halves peak memory)
Remove-Variable -Name rows, fileRows, folderRows, sizeCounts, nameSizeCounts, sizeIds, nameSizeIds, dirWork, dirBatches -Force
[System.GC]::Collect()


$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Classification constants
$installerExts   = @('.iso','.msi','.exe','.7z','.cab')
$mediaExts       = @('.wav','.mp3','.mp4','.avi','.mts','.wmv')
$emailExts       = @('.msg','.pst')
$archivePattern  = '(?i)_archive|\\archive\\|\\archive |\\archive-|_old\\|\\old\\'
$spBadCharsRegex = '["*:<>?/\\|]|^ | $'
$priorityMap     = @{ Fix = 1; Link = 2; Delete = 3; Archive = 4; Review = 5; Migrate = 6 }

# ============================================================
# LOAD DATA
# ============================================================
Write-Host "Loading CSV from $CsvPath ..." -ForegroundColor Cyan
if (-not (Test-Path $reportDir)) { New-Item -Path $reportDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $CsvPath)) { Write-Host "ERROR: CSV not found: $CsvPath" -ForegroundColor Red; exit 1 }

$csv = Import-Csv -Path $CsvPath
$fileItems   = @($csv | Where-Object { $_.ItemType -eq 'File' })
$folderItems = @($csv | Where-Object { $_.ItemType -eq 'Folder' })
Write-Host "  Loaded $($fileItems.Count) files + $($folderItems.Count) folders in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

# ============================================================
# CLASSIFY FOLDERS (broken NTFS inheritance)
# ============================================================
Write-Host "Classifying items..." -ForegroundColor Cyan

foreach ($folder in $folderItems) {
    $rp = $folder.RelativePath
    $parts = $rp.TrimStart('\', '/').Split('\')
    $props = @{
        PrimaryAction = 'Permissions'
        Actions       = 'Permissions'
        ActionReasons = 'Folder with broken NTFS inheritance'
        ActionPriority = 0
        DuplicateFlag = ''
        Level1 = if ($parts.Count -gt 0) { $parts[0] } else { '' }
        Level2 = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        Level3 = if ($parts.Count -gt 2) { $parts[2] } else { '' }
        Level4 = if ($parts.Count -gt 3) { $parts[3] } else { '' }
        PathLength = $rp.Length
    }
    foreach ($k in $props.Keys) { $folder | Add-Member -NotePropertyName $k -NotePropertyValue $props[$k] -Force }
}

# ============================================================
# CLASSIFY FILES – MULTI-STATUS
# ============================================================
$counter = 0
foreach ($file in $fileItems) {
    $actionSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reasonList = [System.Collections.Generic.List[string]]::new()
    $rp = $file.RelativePath
    $fn = $file.FileName
    $fullPath = if ($rp) { $rp } else { $fn }

    # ── FIX: migration-blocking issues (all independent) ──
    if ($fn -match $spBadCharsRegex -or $fn -match '^\.') {
        [void]$actionSet.Add('Fix'); $reasonList.Add('SharePoint-incompatible file name')
    }
    if ($rp -match '(?:^|\\) | (?:$|\\)') {
        [void]$actionSet.Add('Fix'); $reasonList.Add('Leading/trailing space in folder or file name')
    }
    if ($fn.Length -gt 128) {
        [void]$actionSet.Add('Fix'); $reasonList.Add("File name > 128 characters ($($fn.Length))")
    }
    if ($fullPath.Length -gt 206) {
        [void]$actionSet.Add('Fix'); $reasonList.Add("Path too long ($($fullPath.Length)/206)")
    }

    # ── DELETE: cleanup targets (one reason suffices) ──
    if ($fn -match '^\._(.*)|\.DS_Store$') {
        [void]$actionSet.Add('Delete'); $reasonList.Add('Mac resource fork / .DS_Store')
    }
    elseif ($file.IsLikelyTemporary -eq 'True') {
        [void]$actionSet.Add('Delete'); $reasonList.Add('Temporary file')
    }
    elseif ($file.IsHidden -eq 'True') {
        [void]$actionSet.Add('Delete'); $reasonList.Add('Hidden/system file')
    }
    elseif ([long]$file.SizeBytes -eq 0) {
        [void]$actionSet.Add('Delete'); $reasonList.Add('Empty file (0 bytes)')
    }
    elseif ($file.Extension -in $installerExts) {
        [void]$actionSet.Add('Delete'); $reasonList.Add("Installer ($($file.Extension))")
    }
    elseif ($file.Extension -eq '.download') {
        [void]$actionSet.Add('Delete'); $reasonList.Add('Incomplete download file')
    }

    # ── ARCHIVE: cold storage candidates (one reason suffices) ──
    if ($rp -match $archivePattern) {
        [void]$actionSet.Add('Archive'); $reasonList.Add('In archive folder')
    }
    elseif ($file.AgeBucket -eq '10y+') {
        [void]$actionSet.Add('Archive'); $reasonList.Add('Not modified in > 10 years')
    }

    # ── LINKS & MACROS (separate category) ──
    if ($file.HasMacros -eq 'True') {
        if ($file.MacroType -eq 'External') {
            if ([int]$file.AgeDays -lt 365) {
                [void]$actionSet.Add('Link'); $reasonList.Add('Active file with external links - review before migration')
            } else {
                [void]$actionSet.Add('Link'); $reasonList.Add("External references ($($file.MacroType))")
            }
        } else {
            [void]$actionSet.Add('Link'); $reasonList.Add("Internal macro ($($file.MacroType))")
        }
    }

    # ── REVIEW: needs human assessment (independent checks) ──
    if ($rp -match '(?i)(?:^|\\)(?:photos?|photo.?archive)(?:\\|$)') {
        [void]$actionSet.Add('Review'); $reasonList.Add('Photo/photo-archive folder - verify retention need')
    }
    if ($file.Extension -in $mediaExts) {
        [void]$actionSet.Add('Review'); $reasonList.Add('Media file')
    }
    if ($file.Extension -in $emailExts) {
        [void]$actionSet.Add('Review'); $reasonList.Add("Email file ($($file.Extension))")
    }
    if ($file.IsLargeFile -eq 'True') {
        [void]$actionSet.Add('Review'); $reasonList.Add('Very large file (>100MB)')
    }
    if ($actionSet.Count -eq 0 -and [string]::IsNullOrWhiteSpace($file.Extension)) {
        [void]$actionSet.Add('Review'); $reasonList.Add('File without extension')
    }

    # ── DEFAULT: migrate ──
    if ($actionSet.Count -eq 0) {
        [void]$actionSet.Add('Migrate'); $reasonList.Add('Ready for migration')
    }

    # Determine primary action (highest priority)
    $sorted = @($actionSet | Sort-Object { $priorityMap[$_] ?? 99 })
    $primary  = $sorted[0]
    $priority = $priorityMap[$primary] ?? 5

    # Duplicate flag (orthogonal)
    $dupeFlag = if ([int]$file.DuplicateByNameSizeCount -gt 1) { "Potential duplicate ($($file.DuplicateByNameSizeCount)x)" } else { '' }

    # Path levels
    $parts = $rp.TrimStart('\', '/').Split('\')

    # Add properties via loop (cleaner than 10x Add-Member)
    $props = @{
        PrimaryAction  = $primary
        Actions        = ($sorted -join ' | ')
        ActionReasons  = (($reasonList | Select-Object -Unique) -join ' | ')
        ActionPriority = $priority
        DuplicateFlag  = $dupeFlag
        Level1 = if ($parts.Count -gt 1) { $parts[0] } else { '' }
        Level2 = if ($parts.Count -gt 2) { $parts[1] } else { '' }
        Level3 = if ($parts.Count -gt 3) { $parts[2] } else { '' }
        Level4 = if ($parts.Count -gt 4) { $parts[3] } else { '' }
        PathLength = $fullPath.Length
    }
    foreach ($k in $props.Keys) { $file | Add-Member -NotePropertyName $k -NotePropertyValue $props[$k] -Force }

    $counter++
    if ($counter % 25000 -eq 0) { Write-Host "  Classified $counter / $($fileItems.Count)..." }
}
Write-Host "  Classification complete ($($fileItems.Count) files, $($folderItems.Count) folders) in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"

# ============================================================
# EXPORT ANNOTATED XLSX
# ============================================================
# Define fixed column order so the XLSX structure is always identical
$fileColumnOrder = @(
    'PrimaryAction','Actions','ActionReasons','FullPath','ActionPriority','DuplicateFlag',
    'ItemType','FileName','Extension','RelativePath','ParentRelativePath',
    'Level1','Level2','Level3','Level4','PathLength',
    'SizeBytes','SizeMB','CreatedUtc','LastWriteUtc','LastAccessUtc','AgeDays','AgeBucket',
    'IsReadOnly','IsHidden','UniquePermissions','UniqueACLs',
    'IsLikelyTemporary','IsLargeFile',
    'HasMacros','MacroType','MacroDetails',
    'DuplicateBySizeCount','DuplicateBySizeId','DuplicateByNameSizeCount','DuplicateByNameSizeId'
)
$folderColumnOrder = @(
    'PrimaryAction','Actions','ActionReasons','FullPath','ActionPriority','DuplicateFlag',
    'ItemType','FileName','Extension','RelativePath','ParentRelativePath',
    'Level1','Level2','Level3','Level4','PathLength',
    'SizeBytes','SizeMB','CreatedUtc','LastWriteUtc','LastAccessUtc','AgeDays','AgeBucket',
    'IsReadOnly','IsHidden','UniquePermissions','UniqueACLs',
    'IsLikelyTemporary','IsLargeFile',
    'HasMacros','MacroType','MacroDetails',
    'DuplicateBySizeCount','DuplicateBySizeId','DuplicateByNameSizeCount','DuplicateByNameSizeId'
)
Write-Host "Exporting annotated Excel workbook..." -ForegroundColor Cyan

# The XLSX is a convenience copy for annotation; it must never take the whole report down in larger source folders
# EPPlus holds the entire workbook in memory, so at millions of rows an unbounded export runs
# for hours or OOMs the worker. Strategy:
#  - cap the exported rows at $MaxXlsxRows (brondata.csv keeps the full dataset),
#  - write cells in bulk via EPPlus LoadFromArrays instead of piping into Export-Excel. The
#    pipeline path inserts every cell individually (~30M try/catch'd assignments at 1M rows) and
#    is what makes the export take hours; it is also the source of the "Could not insert the
#    'LastAccessUtc' property at Row N" warnings (EPPlus rejects DateTimes before the 1900 Excel
#    epoch, e.g. FILETIME-zero timestamps). LoadFromArrays is one managed call and we coerce
#    pre-1900 dates to text so no row is dropped,
#  - only AutoFit columns below 50k rows (per-cell measurement is itself O(cells)),
#  - run the export on a worker thread and abandon it after $XlsxTimeoutMinutes,
#  - any failure degrades to "no XLSX this run" instead of a failed runbook.
$xlsxOk = $false
$exportItems = $fileItems
$xlsxFullPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputXlsx))
try {
    if (Test-Path -LiteralPath $xlsxFullPath) { Remove-Item -LiteralPath $xlsxFullPath -Force }

    if ($fileItems.Count -gt $MaxXlsxRows) {
        Write-Warning "  $($fileItems.Count) rows exceed MaxXlsxRows ($MaxXlsxRows); exporting the first $MaxXlsxRows (most-duplicated/oldest/largest first). Full dataset remains in brondata.csv."
        $exportItems = $fileItems[0..($MaxXlsxRows - 1)]
    }

    $exportScript = {
        param($fileItems, $folderItems, $fileColumnOrder, $folderColumnOrder, $xlsxPath)
        $ErrorActionPreference = 'Stop'
        Import-Module ImportExcel
        $maxRowsPerSheet = 1048575  # Excel max rows minus header

        # Columns holding DateTime values; they need an Excel date number-format after bulk load
        # (LoadFromArrays stores the raw serial, so without this they'd render as numbers).
        $dateColumns = @('CreatedUtc', 'LastWriteUtc', 'LastAccessUtc')

        # Bulk-write one sheet using EPPlus LoadFromArrays. Orders of magnitude faster than
        # piping into Export-Excel, and it never drops rows: values EPPlus can't store as a date
        # (pre-1900 timestamps) are coerced to text instead of triggering per-cell warnings.
        function Write-BulkSheet {
            param($Package, $Items, [string[]]$Columns, [string]$SheetName, [string]$TableName, [string]$TableStyle)

            $ws = $Package.Workbook.Worksheets.Add($SheetName)
            $colCount = $Columns.Count

            # Header row.
            for ($c = 0; $c -lt $colCount; $c++) { $ws.Cells[1, $c + 1].Value = $Columns[$c] }

            # Build one object[] per row in column order.
            $rows = [System.Collections.Generic.List[object[]]]::new()
            foreach ($it in $Items) {
                $arr = [object[]]::new($colCount)
                for ($c = 0; $c -lt $colCount; $c++) {
                    $v = $it.($Columns[$c])
                    # Excel's date system starts at 1900; EPPlus throws on earlier DateTimes.
                    if ($v -is [datetime] -and $v.Year -lt 1900) { $v = $v.ToString('o') }
                    $arr[$c] = $v
                }
                $rows.Add($arr)
            }
            if ($rows.Count -gt 0) { $null = $ws.Cells[2, 1].LoadFromArrays($rows) }
            $lastRow = [math]::Max($rows.Count + 1, 2)

            # Date number-format on any DateTime columns.
            for ($c = 0; $c -lt $colCount; $c++) {
                if ($dateColumns -contains $Columns[$c]) {
                    $ws.Column($c + 1).Style.Numberformat.Format = 'yyyy-mm-dd hh:mm:ss'
                }
            }

            # Styled table for filtering/sorting parity with the previous output.
            $range = $ws.Cells[1, 1, $lastRow, $colCount]
            $tbl = $ws.Tables.Add($range, $TableName)
            $tbl.TableStyle = [OfficeOpenXml.Table.TableStyles]$TableStyle

            # AutoFit is per-cell measurement (O(cells)); only affordable on small sheets.
            if ($rows.Count -le 50000) { $ws.Cells[$ws.Dimension.Address].AutoFitColumns() }
        }

        $pkg = Open-ExcelPackage -Path $xlsxPath -Create
        try {
            if ($fileItems.Count -le $maxRowsPerSheet) {
                Write-BulkSheet -Package $pkg -Items $fileItems -Columns $fileColumnOrder -SheetName 'Files' -TableName 'FileAnalysis' -TableStyle 'Medium2'
            } else {
                $sheetNum = 1
                for ($offset = 0; $offset -lt $fileItems.Count; $offset += $maxRowsPerSheet) {
                    $end   = [math]::Min($offset + $maxRowsPerSheet, $fileItems.Count)
                    $chunk = $fileItems[$offset..($end - 1)]
                    Write-Host "  Writing sheet Files_$sheetNum (rows $($offset+1) - $end)..." -ForegroundColor Cyan
                    Write-BulkSheet -Package $pkg -Items $chunk -Columns $fileColumnOrder -SheetName "Files_$sheetNum" -TableName "FileAnalysis_$sheetNum" -TableStyle 'Medium2'
                    $sheetNum++
                }
            }
            if ($folderItems.Count -gt 0) {
                Write-BulkSheet -Package $pkg -Items $folderItems -Columns $folderColumnOrder -SheetName 'FolderPermissions' -TableName 'FolderPermissions' -TableStyle 'Medium6'
                Write-Host "  Written $($folderItems.Count) folder permission rows" -ForegroundColor Cyan
            }
            Close-ExcelPackage $pkg
        } catch {
            try { Close-ExcelPackage $pkg -NoSave } catch { }
            throw
        }
    }
    $exportArgs = @($exportItems, $folderItems, $fileColumnOrder, $folderColumnOrder, $xlsxFullPath)

    if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
        $exportJob = Start-ThreadJob -ScriptBlock $exportScript -ArgumentList $exportArgs -StreamingHost $Host
        $timeoutSeconds = [math]::Max(60, $XlsxTimeoutMinutes * 60)
        $null = Wait-Job -Job $exportJob -Timeout $timeoutSeconds
        if ($exportJob.State -eq 'Running') {
            # EPPlus cannot be interrupted mid-operation; request a stop and move on. The
            # abandoned thread dies with the process and the partial file is not uploaded.
            Write-Warning "  Excel export still running after $XlsxTimeoutMinutes minutes; continuing without XLSX. Full dataset remains in brondata.csv."
            $null = $exportJob.StopJobAsync()
        } elseif ($exportJob.State -eq 'Completed') {
            # Host output already streamed live via -StreamingHost; the job runs with
            # ErrorActionPreference=Stop, so Completed means genuinely error-free.
            Remove-Job -Job $exportJob -Force
            $xlsxOk = $true
        } else {
            Receive-Job -Job $exportJob -ErrorAction Stop
            throw "Excel export job ended in state '$($exportJob.State)'"
        }
    } else {
        # No ThreadJob available: run inline (no timeout protection, failures still degrade gracefully)
        & $exportScript @exportArgs
        $xlsxOk = $true
    }

    if ($xlsxOk) {
        Write-Host "  Saved: $OutputXlsx ($([math]::Round((Get-Item -LiteralPath $xlsxFullPath).Length / 1KB, 0)) KB)"
    }
} catch {
    Write-Warning "  Excel export failed: $($_.Exception.Message). Continuing without XLSX; full dataset remains in brondata.csv."
}
if (-not $xlsxOk) {
    try { if (Test-Path -LiteralPath $xlsxFullPath) { Remove-Item -LiteralPath $xlsxFullPath -Force -ErrorAction Stop } } catch { }
}

# ============================================================
# BUILD SUMMARY DATA
# ============================================================
Write-Host "Building summary data..." -ForegroundColor Cyan

$totalFiles = $fileItems.Count
$totalSizeBytes = ($fileItems | Measure-Object -Property SizeBytes -Sum).Sum
$totalSizeGB = [math]::Round($totalSizeBytes / 1GB, 2)

# Primary action stats (exclusive – each file counted once, for stacked bar)
$primaryStats = @{}
foreach ($pg in ($fileItems | Group-Object PrimaryAction)) {
    $sz = ($pg.Group | Measure-Object -Property SizeBytes -Sum).Sum
    $primaryStats[$pg.Name] = @{ count = $pg.Count; sizeGB = [math]::Round($sz / 1GB, 2); sizeBytes = [long]$sz }
}

# Total action stats (inclusive – files with multiple statuses counted in each)
$actionTotals = @{}
foreach ($file in $fileItems) {
    foreach ($act in ($file.Actions -split '\s*\|\s*')) {
        if (-not $actionTotals[$act]) { $actionTotals[$act] = @{ count = 0; sizeBytes = [long]0 } }
        $actionTotals[$act].count++
        $actionTotals[$act].sizeBytes += [long]$file.SizeBytes
    }
}
foreach ($key in @($actionTotals.Keys)) { $actionTotals[$key].sizeGB = [math]::Round($actionTotals[$key].sizeBytes / 1GB, 2) }

# Age breakdown
$ageStats = foreach ($ag in ($fileItems | Group-Object AgeBucket)) {
    $sz = ($ag.Group | Measure-Object -Property SizeBytes -Sum).Sum
    @{ name = $ag.Name; count = $ag.Count; sizeGB = [math]::Round($sz / 1GB, 2) }
}

# Extension breakdown (top 20)
$extStats = foreach ($eg in ($fileItems | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 20)) {
    $sz = ($eg.Group | Measure-Object -Property SizeBytes -Sum).Sum
    @{ name = if ($eg.Name) { $eg.Name } else { "(none)" }; count = $eg.Count; sizeGB = [math]::Round($sz / 1GB, 2) }
}

# Derived counts
$dupeFiles    = $fileItems | Where-Object { [int]$_.DuplicateByNameSizeCount -gt 1 }
$dupeCount    = $dupeFiles.Count
$dupeSizeGB   = [math]::Round(($dupeFiles | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2)
$pathTooLongCount = @($fileItems | Where-Object { "$($_.RelativePath)\$($_.FileName)".Length -gt 206 }).Count

$uniquePermFiles     = $fileItems | Where-Object { $_.UniquePermissions -eq 'True' }
$uniquePermFileCount = $uniquePermFiles.Count
$uniquePermFileSizeGB = [math]::Round(($uniquePermFiles | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2)
$uniquePermFolderCount = $folderItems.Count

$macroFiles    = @($fileItems | Where-Object { $_.HasMacros -eq 'True' })
$macroFileCount = $macroFiles.Count
$macroFileSizeGB = if ($macroFiles.Count -gt 0) { [math]::Round(($macroFiles | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2) } else { 0 }
$macroExternalFiles = @($macroFiles | Where-Object { $_.MacroType -eq 'External' })
$macroExternalCount = $macroExternalFiles.Count
$macroInternalCount = @($macroFiles | Where-Object { $_.MacroType -eq 'Internal' }).Count
$macroExternalRecentCount = @($macroExternalFiles | Where-Object { [int]$_.AgeDays -lt 365 }).Count

# ============================================================
# HISTORICAL DATA (load previous runs from $outputFolder, update, save)
# ============================================================
Write-Host "Processing historical data..." -ForegroundColor Cyan

$fixCount = if ($actionTotals['Fix']) { $actionTotals['Fix'].count } else { 0 }
$historyData = @()

if (Test-Path $OutputHistory) {
    $historyData = @(Get-Content -Path $OutputHistory -Raw | ConvertFrom-Json)
    Write-Host "  Loaded historicaldata.json from previous run ($($historyData.Count) data points)" -ForegroundColor Green
} else {
    Write-Host "  No existing historicaldata.json found, creating new." -ForegroundColor Yellow
}

$currentDataPoint = [PSCustomObject]@{
    date        = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    totalSizeGB = $totalSizeGB
    totalFiles  = $totalFiles
    fixCount    = $fixCount
}
$historyData = @($historyData) + @($currentDataPoint)

$historyData | ConvertTo-Json -Depth 4 | Set-Content -Path $OutputHistory -Encoding UTF8
Write-Host "  Historical data: $($historyData.Count) data points saved to $OutputHistory"

# ============================================================
# FOLDER AGGREGATION (for tree explorer) – multi-status aware
# ============================================================
Write-Host "Building folder tree data..." -ForegroundColor Cyan

# Single pass over the file list instead of Group-Object + per-group rescans
$folderAggMap = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $fileItems) {
    $p = $f.ParentRelativePath
    $agg = $null
    if (-not $folderAggMap.TryGetValue($p, [ref]$agg)) {
        $agg = @{ p = $p; a = @{}; f = 0; sz = [long]0; u = 0; m = 0 }
        $folderAggMap[$p] = $agg
    }
    foreach ($act in ($f.Actions -split '\s*\|\s*')) {
        if (-not $agg.a[$act]) { $agg.a[$act] = @([int]0, [long]0) }
        $agg.a[$act][0]++
        $agg.a[$act][1] += [long]$f.SizeBytes
    }
    $agg.f++
    $agg.sz += [long]$f.SizeBytes
    if ($f.UniquePermissions -eq 'True') { $agg.u++ }
    if ($f.HasMacros -eq 'True') { $agg.m++ }
}

# Folders with broken inheritance count toward their own node and their parent's node
$folderPermCounts = [System.Collections.Generic.Dictionary[string,int]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($fo in $folderItems) {
    foreach ($key in @(@($fo.ParentRelativePath, $fo.RelativePath) | Select-Object -Unique)) {
        if ([string]::IsNullOrEmpty($key)) { continue }
        $folderPermCounts[$key] = ($folderPermCounts.ContainsKey($key) ? $folderPermCounts[$key] : 0) + 1
    }
}

$folderAgg = @(foreach ($agg in $folderAggMap.Values) {
    if ($folderPermCounts.ContainsKey($agg.p)) { $agg.u += $folderPermCounts[$agg.p] }
    $agg
})
Write-Host "  $($folderAgg.Count) unique folders"

# ============================================================
# NTFS PERMISSIONS TREE
# ============================================================
Write-Host "Building NTFS permissions tree data..." -ForegroundColor Cyan

# Same DACL-by-SID + Resolve-AceIdentity approach as the scan phase: Get-Acl relies on LSA
$rootDfGroups = ''
try {
    $rootSec = [System.Security.AccessControl.DirectorySecurity]::new($rootPathStr, [System.Security.AccessControl.AccessControlSections]::Access)
    $rootEntries = @(foreach ($rule in $rootSec.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
        $name = Resolve-AceIdentity $rule.IdentityReference
        "$($name):$($rule.FileSystemRights.ToString())"
    })
    if ($rootEntries.Count -gt 0) {
        $rootDfGroups = ($rootEntries | Sort-Object -Unique) -join '; '
    }
} catch { Write-Warning "Could not read ACL for root '$rootPathStr': $_" }

if ($folderItems.Count -gt 0) {
    $permFolders = @($folderItems | Where-Object { $_.UniqueACLs -and $_.UniqueACLs -ne '' } |
        ForEach-Object {
            $allAcls = @($_.UniqueACLs -split ';\s*' | Where-Object { $_ -ne '' } | Sort-Object -Unique)
            @{ p = $_.RelativePath; g = @($allAcls) }
        })
    $folderPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($pf in $permFolders) { [void]$folderPaths.Add($pf.p) }
    $filePermFolders = @($fileItems | Where-Object { $_.UniqueACLs -and $_.UniqueACLs -ne '' } |
        Group-Object ParentRelativePath | Where-Object { -not $folderPaths.Contains($_.Name) } |
        ForEach-Object {
            $allAcls = $_.Group | ForEach-Object { $_.UniqueACLs -split ';\s*' } | Where-Object { $_ -ne '' } | Sort-Object -Unique
            @{ p = $_.Name; g = @($allAcls) }
        })
    $permFolders = @($permFolders) + @($filePermFolders)
} else {
    $permFolders = @($fileItems | Where-Object { $_.UniqueACLs -and $_.UniqueACLs -ne '' } |
        Group-Object ParentRelativePath | ForEach-Object {
            $allAcls = $_.Group | ForEach-Object { $_.UniqueACLs -split ';\s*' } | Where-Object { $_ -ne '' } | Sort-Object -Unique
            @{ p = $_.Name; g = @($allAcls) }
        })
}
if ($rootDfGroups) {
    $rootAclEntries = @($rootDfGroups -split ';\s*' | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    $permFolders = @(@{ p = '\'; g = $rootAclEntries }) + $permFolders
}
Write-Host "  $($permFolders.Count) folders with unique ACLs"

# ============================================================
# NOTABLE FILES per action (top 30 largest, multi-status aware)
# ============================================================
Write-Host "Collecting notable files..." -ForegroundColor Cyan

$notableFiles = @{}
foreach ($actionName in @('Delete','Archive','Fix','Review','Migrate','Link')) {
    $items = $fileItems | Where-Object { $_.Actions -match [regex]::Escape($actionName) } |
        Sort-Object { [long]$_.SizeBytes } -Descending |
        Select-Object -First 30 |
        ForEach-Object {
            @{ n = $_.FileName; p = $_.RelativePath; s = [long]$_.SizeBytes; e = $_.Extension
               g = $_.AgeBucket; r = $_.ActionReasons; a = $_.Actions }
        }
    $notableFiles[$actionName] = @($items)
}

$topDupeGroups = $fileItems | Where-Object { [int]$_.DuplicateByNameSizeCount -gt 5 } |
    Group-Object DuplicateByNameSizeId |
    Sort-Object Count -Descending | Select-Object -First 30 |
    ForEach-Object {
        $first = $_.Group[0]
        @{ n = $first.FileName; count = $_.Count; s = [long]$first.SizeBytes
           paths = @($_.Group | Select-Object -First 5 -ExpandProperty ParentRelativePath) }
    }

# ============================================================
# BUILD JSON DATA FOR HTML
# ============================================================
Write-Host "Serializing data for HTML..." -ForegroundColor Cyan

$jsonData = @{
    generated = (Get-Item -LiteralPath $CsvPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    rootPath  = $RootPath
    summary   = @{
        totalFiles            = $totalFiles
        totalSizeGB           = $totalSizeGB
        duplicateFiles        = $dupeCount
        duplicateSizeGB       = $dupeSizeGB
        pathTooLongFiles      = $pathTooLongCount
        uniquePermFiles       = $uniquePermFileCount
        uniquePermFileSizeGB  = $uniquePermFileSizeGB
        uniquePermFolders     = $uniquePermFolderCount
        macroFiles            = $macroFileCount
        macroFileSizeGB       = $macroFileSizeGB
        macroExternal         = $macroExternalCount
        macroInternal         = $macroInternalCount
        macroExternalRecent   = $macroExternalRecentCount
    }
    actions        = $actionTotals      # inclusive (multi-counted)
    primaryActions = $primaryStats      # exclusive (each file once)
    ageBuckets     = @($ageStats)
    topExtensions  = @($extStats)
    folders        = @($folderAgg)
    permFolders    = @($permFolders)
    notable        = $notableFiles
    topDuplicates  = @($topDupeGroups)
    history        = @($historyData)
    macroList      = @($macroFiles | Sort-Object { if ($_.MacroType -eq 'External' -and [int]$_.AgeDays -lt 365) { 0 } elseif ($_.MacroType -eq 'External') { 1 } else { 2 } } |
        ForEach-Object {
            @{ n = $_.FileName; p = $_.RelativePath; s = [long]$_.SizeBytes; e = $_.Extension
               t = $_.MacroType; d = $_.MacroDetails; g = $_.AgeBucket
               pr = if ($_.MacroType -eq 'External' -and [int]$_.AgeDays -lt 365) { 1 } else { 0 } }
        })
} | ConvertTo-Json -Depth 6 -Compress

Write-Host "  JSON size: $([math]::Round($jsonData.Length / 1KB, 0)) KB"

# ============================================================
# HTML TEMPLATE
# ============================================================
Write-Host "Generating HTML report..." -ForegroundColor Cyan

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cleanup scan &mdash; $Title</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#f1f5f9;--card:#fff;--sidebar:#0f172a;--sidebar-hover:#1e293b;
  --text:#0f172a;--text-light:#64748b;--text-inv:#f8fafc;--border:#e2e8f0;
  --delete:#ef4444;--archive:#f59e0b;--fix:#a855f7;--review:#3b82f6;--migrate:#22c55e;--link:#f97316;--dupe:#14b8a6;--ref:#f97316;
  --delete-bg:#fef2f2;--archive-bg:#fffbeb;--fix-bg:#faf5ff;--review-bg:#eff6ff;--migrate-bg:#f0fdf4;--link-bg:#fff7ed;--dupe-bg:#f0fdfa;--ref-bg:#fff7ed;
  --radius:10px;--shadow:0 1px 3px rgba(0,0,0,.08),0 1px 2px rgba(0,0,0,.04);
}
html{font-size:14px}
body{font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);display:grid;grid-template-columns:250px 1fr;height:100vh;overflow:hidden}
a{color:var(--review);text-decoration:none}

/* SIDEBAR */
.sidebar{background:var(--sidebar);color:var(--text-inv);display:flex;flex-direction:column;overflow-y:auto}
.sidebar h1{font-size:1rem;padding:1.5rem 1.25rem .25rem;font-weight:700;letter-spacing:-.02em;line-height:1.3}
.sidebar .scan-date{font-size:.65rem;color:#64748b;padding:.15rem 1.25rem 0;margin:0}
.sidebar .subtitle{font-size:.75rem;color:#94a3b8;padding:0 1.25rem 1.25rem;border-bottom:1px solid #334155}
.nav{list-style:none;padding:.75rem 0;flex:1}
.nav li{cursor:pointer;padding:.6rem 1.25rem;display:flex;align-items:center;gap:.65rem;font-size:.85rem;border-left:3px solid transparent;transition:all .15s}
.nav li:hover{background:var(--sidebar-hover)}
.nav li.active{background:var(--sidebar-hover);border-left-color:#3b82f6;font-weight:600}
.nav li .badge{margin-left:auto;font-size:.7rem;background:#334155;padding:2px 8px;border-radius:99px;font-weight:600}
.nav li .dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.sidebar-footer{padding:1rem 1.25rem;border-top:1px solid #334155;font-size:.7rem;color:#64748b}

/* MAIN */
.main{overflow-y:auto;padding:2rem 2.5rem}
.main h2{font-size:1.5rem;font-weight:700;margin-bottom:.25rem}
.main .page-desc{color:var(--text-light);margin-bottom:1.5rem;font-size:.9rem}

/* CARDS */
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:1rem;margin-bottom:2rem}
.card{background:var(--card);border-radius:var(--radius);padding:1.25rem;box-shadow:var(--shadow);border:1px solid var(--border);transition:transform .15s,box-shadow .15s}
.card.clickable{cursor:pointer}
.card.clickable:hover{transform:translateY(-2px);box-shadow:0 4px 12px rgba(0,0,0,.1)}
.card .label{font-size:.75rem;color:var(--text-light);text-transform:uppercase;letter-spacing:.04em;font-weight:600}
.card .value{font-size:1.6rem;font-weight:800;margin:.25rem 0 .1rem}
.card .sub{font-size:.75rem;color:var(--text-light)}
.card.accent-red{border-top:3px solid var(--delete)}
.card.accent-orange{border-top:3px solid var(--archive)}
.card.accent-green{border-top:3px solid var(--migrate)}
.card.accent-link{border-top:3px solid var(--link)}
.card.accent-blue{border-top:3px solid var(--review)}
.card.accent-purple{border-top:3px solid var(--fix)}
.card.accent-teal{border-top:3px solid var(--dupe)}
.card.accent-ref{border-top:3px solid var(--ref)}

/* BAR CHART */
.bar-chart{margin-bottom:2rem}
.bar-row{display:flex;align-items:center;gap:.75rem;margin-bottom:.5rem}
.bar-label{width:90px;font-size:.8rem;font-weight:600;text-align:right;flex-shrink:0}
.bar-track{flex:1;height:28px;background:#e2e8f0;border-radius:6px;overflow:hidden;position:relative}
.bar-fill{height:100%;border-radius:6px;display:flex;align-items:center;padding:0 10px;font-size:.7rem;font-weight:700;color:#fff;min-width:fit-content;transition:width .5s ease}
.bar-val{font-size:.8rem;color:var(--text-light);width:120px;text-align:right;flex-shrink:0}

/* STACKED BAR */
.stacked-bar{height:36px;border-radius:8px;overflow:hidden;display:flex;margin-bottom:.5rem}
.stacked-bar .seg{display:flex;align-items:center;justify-content:center;font-size:.7rem;font-weight:700;color:#fff;cursor:pointer;transition:opacity .2s}
.stacked-bar .seg:hover{opacity:.85}
.legend{display:flex;gap:1.25rem;flex-wrap:wrap;margin-bottom:1.5rem}
.legend-item{display:flex;align-items:center;gap:.35rem;font-size:.8rem}
.legend-item .dot{width:10px;height:10px;border-radius:50%}

/* ACTION SECTIONS */
.action-section{background:var(--card);border-radius:var(--radius);padding:1.5rem;box-shadow:var(--shadow);border:1px solid var(--border);margin-bottom:1.25rem}
.action-header{display:flex;align-items:center;gap:.75rem;margin-bottom:.25rem}
.action-header h3{font-size:1.1rem;font-weight:700}

/* TABLE */
.tbl-wrap{overflow-x:auto;margin-top:.75rem}
table{width:100%;border-collapse:collapse;font-size:.8rem}
th{text-align:left;padding:.55rem .75rem;border-bottom:2px solid var(--border);font-weight:700;color:var(--text-light);text-transform:uppercase;font-size:.7rem;letter-spacing:.03em;cursor:pointer;user-select:none;white-space:nowrap;position:sticky;top:0;background:var(--card);z-index:1}
th:hover{color:var(--text)}
th.sorted-asc::after{content:' \25B2';font-size:.6rem}
th.sorted-desc::after{content:' \25BC';font-size:.6rem}
td{padding:.5rem .75rem;border-bottom:1px solid var(--border);max-width:500px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
tr:hover td{background:#f8fafc}
.r{text-align:right}

/* TREE */
.tree{font-size:.85rem}
.tree-node{border-bottom:1px solid var(--border)}
.tree-row{display:flex;align-items:center;gap:.5rem;padding:.45rem .5rem;cursor:pointer;transition:background .1s}
.tree-row:hover{background:#f1f5f9}
.tree-toggle{width:18px;text-align:center;color:var(--text-light);flex-shrink:0;font-size:.75rem;transition:transform .15s}
.tree-toggle.open{transform:rotate(90deg)}
.tree-name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:500}
.tree-pills{display:flex;gap:3px;flex-shrink:0}
.tree-pill{font-size:.65rem;padding:1px 6px;border-radius:99px;font-weight:700;color:#fff}
.tree-count{font-size:.75rem;color:var(--text-light);width:70px;text-align:right;flex-shrink:0}
.tree-size{font-size:.75rem;color:var(--text-light);width:70px;text-align:right;flex-shrink:0}
.tree-children{padding-left:1.25rem;display:none}
.tree-children.open{display:block}

/* PERMISSION TREE */
.perm-groups{display:flex;flex-wrap:wrap;gap:4px;margin-top:2px}
.perm-tag{font-size:.7rem;padding:2px 8px;border-radius:4px;font-weight:600;white-space:nowrap}
.perm-tag.read{background:#dbeafe;color:#1e40af}
.perm-tag.modify{background:#fef3c7;color:#92400e}
.perm-tag.full{background:#fce7f3;color:#9d174d}
.perm-tag.other{background:#e2e8f0;color:#334155}
.perm-node .tree-row{min-height:36px}
.perm-node .tree-name{font-weight:600}

/* SEARCH */
.search-wrap{position:relative;margin-bottom:1.5rem}
.search-wrap input{width:100%;padding:.7rem 1rem .7rem 2.5rem;border:1px solid var(--border);border-radius:var(--radius);font-size:.9rem;background:var(--card);outline:none;transition:border-color .15s}
.search-wrap input:focus{border-color:#3b82f6}
.search-wrap .icon{position:absolute;left:.85rem;top:50%;transform:translateY(-50%);color:var(--text-light);font-size:.9rem}

/* MULTI-STATUS PILLS */
.status-pills{display:inline-flex;gap:3px}
.pill{display:inline-block;font-size:.65rem;padding:2px 8px;border-radius:99px;font-weight:700;color:#fff}
.pill-multi{border:2px dashed rgba(0,0,0,.15)}

/* PRIORITY ROW */
tr.priority-row td{background:#fff7ed}
tr.priority-row:hover td{background:#ffedd5}

/* OVERLAP BARS */
.overlap-row{display:flex;align-items:center;gap:.75rem;margin-bottom:.75rem}
.overlap-label{font-size:.8rem;color:var(--text-light);white-space:nowrap;width:180px;flex-shrink:0}
.overlap-track{flex:1;height:10px;background:#e2e8f0;border-radius:5px;overflow:hidden}
.overlap-fill{height:100%;border-radius:5px}
.overlap-val{font-size:.8rem;font-weight:600;white-space:nowrap}

.hidden{display:none!important}
.mt1{margin-top:1rem}.mt2{margin-top:2rem}
.truncate{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mono{font-family:'Cascadia Code',Consolas,monospace;font-size:.8rem}
.note{background:#f0f9ff;border:1px solid #bae6fd;border-radius:var(--radius);padding:.75rem 1rem;font-size:.8rem;color:#0369a1;margin-bottom:1.5rem}
</style>
</head>
<body>

<aside class="sidebar">
  <h1>Cleanup scan</h1>
  <p class="scan-date">Scanned: <span id="gen-date"></span></p>
  <p class="subtitle">$Title &mdash; SharePoint Migration</p>
  <ul class="nav" id="nav">
    <li class="active" data-page="overview"><span>&#128202;</span> Overview</li>
    <li data-page="delete"><span class="dot" style="background:var(--delete)"></span> Delete <span class="badge" id="badge-delete"></span></li>
    <li data-page="archive"><span class="dot" style="background:var(--archive)"></span> Archive <span class="badge" id="badge-archive"></span></li>
    <li data-page="fix"><span class="dot" style="background:var(--fix)"></span> Fix <span class="badge" id="badge-fix"></span></li>
    <li data-page="link"><span class="dot" style="background:var(--link)"></span> Links <span class="badge" id="badge-link"></span></li>
    <li data-page="review"><span class="dot" style="background:var(--review)"></span> Review <span class="badge" id="badge-review"></span></li>
    <li data-page="migrate"><span class="dot" style="background:var(--migrate)"></span> Migrate <span class="badge" id="badge-migrate"></span></li>
    <li data-page="duplicates"><span class="dot" style="background:var(--dupe)"></span> Duplicates <span class="badge" id="badge-dupes"></span></li>
    <li data-page="explorer"><span>&#128193;</span> Folder Explorer</li>
    <li data-page="permissions"><span>&#128274;</span> Unique permissions <span class="badge" id="badge-perms"></span></li>
    <li data-page="history"><span>&#128200;</span> History <span class="badge" id="badge-history"></span></li>
  </ul>
  <div class="sidebar-footer">Source: sourcedata.csv</div>
</aside>

<main class="main" id="main"></main>

<script src="%%SCRIPT_SRC%%"></script>
</body>
</html>
"@

# ============================================================
# GENERATE REPORT.JS (external script to avoid CSP inline blocks)
# ============================================================
$jsCode = @'
const DATA = %%JSON_DATA%%;

// ── Utilities ──
const fmt = n => n == null ? '0' : n.toLocaleString('en-US');
const fmtGB = n => n == null ? '0' : n.toFixed(2) + ' GB';
const fmtSize = bytes => {
    if (bytes == null || bytes === 0) return '0 B';
    if (bytes >= 1073741824) return (bytes/1073741824).toFixed(2)+' GB';
    if (bytes >= 1048576) return (bytes/1048576).toFixed(1)+' MB';
    if (bytes >= 1024) return (bytes/1024).toFixed(0)+' KB';
    return bytes+' B';
};
const pct = (n,t) => t === 0 ? '0' : ((n/t)*100).toFixed(1);
const escHtml = s => s ? s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;') : '';

const actionColor = a => ({Delete:'var(--delete)',Archive:'var(--archive)',Fix:'var(--fix)',Link:'var(--link)',Review:'var(--review)',Migrate:'var(--migrate)'}[a]||'#888');
const actionBg = a => ({Delete:'var(--delete-bg)',Archive:'var(--archive-bg)',Fix:'var(--fix-bg)',Link:'var(--link-bg)',Review:'var(--review-bg)',Migrate:'var(--migrate-bg)'}[a]||'#f8fafc');
const actionIcon = a => ({Delete:'\u{1F5D1}\uFE0F',Archive:'\u{1F4E6}',Fix:'\u{1F527}',Link:'\u{1F517}',Review:'\u{1F50D}',Migrate:'\u2705'}[a]||'\u{1F4C4}');
const actionDesc = a => ({
    Delete:'Temporary files, installers, empty files, hidden/system files and .download files.',
    Archive:'Files not modified in over 10 years, or located in an archive folder.',
    Fix:'Files that cannot be migrated without correction: paths too long, illegal characters, file names too long.',
    Link:'Files with VBA macros and/or references to external sources. These often stop working after migration.',
    Review:'Media, email, very large files, or files without an extension that need manual assessment.',
    Migrate:'Files that are ready for SharePoint migration.'
}[a]||'');

function renderStatusPills(actionsStr) {
    if (!actionsStr) return '';
    const parts = actionsStr.split(/\s*\|\s*/);
    const multi = parts.length > 1;
    return parts.map(a => '<span class="pill'+(multi?' pill-multi':'')+'" style="background:'+actionColor(a)+'">'+a+'</span>').join(' ');
}

function addTableSort(tableEl) {
    if (!tableEl) return;
    const headers = tableEl.querySelectorAll('th');
    headers.forEach((th, idx) => {
        th.addEventListener('click', () => {
            const tbody = tableEl.querySelector('tbody');
            if (!tbody) return;
            const rows = [...tbody.querySelectorAll('tr')];
            const dir = th.classList.contains('sorted-asc') ? 'desc' : 'asc';
            headers.forEach(h => { h.classList.remove('sorted-asc','sorted-desc'); });
            th.classList.add('sorted-'+dir);
            rows.sort((a,b) => {
                const av = a.cells[idx]?.textContent?.trim() || '';
                const bv = b.cells[idx]?.textContent?.trim() || '';
                const an = parseFloat(av.replace(/[^0-9.\-]/g,''));
                const bn = parseFloat(bv.replace(/[^0-9.\-]/g,''));
                if (!isNaN(an) && !isNaN(bn)) return dir === 'asc' ? an-bn : bn-an;
                return dir === 'asc' ? av.localeCompare(bv,'en') : bv.localeCompare(av,'en');
            });
            rows.forEach(r => tbody.appendChild(r));
        });
    });
}

// ── Build Tree ──
function buildTree(folders) {
    const root = {name:'Root',children:{},stats:{},totalFiles:0,totalSize:0,uniquePerms:0};
    for (const f of folders) {
        const parts = f.p.split('\\').filter(Boolean);
        let node = root;
        for (const part of parts) {
            if (!node.children[part]) node.children[part]={name:part,children:{},stats:{},totalFiles:0,totalSize:0,uniquePerms:0};
            node = node.children[part];
        }
        // Use unique file count (f.f) and size (f.sz) for totals
        node.totalFiles += (f.f || 0);
        node.totalSize += (f.sz || 0);
        // Action counts are multi-counted (inclusive)
        for (const [action,[count,size]] of Object.entries(f.a)) {
            if (!node.stats[action]) node.stats[action]={count:0,size:0};
            node.stats[action].count += count;
            node.stats[action].size += size;
        }
        node.uniquePerms += (f.u||0);
    }
    function propagate(node) {
        for (const child of Object.values(node.children)) {
            propagate(child);
            node.totalFiles += child.totalFiles;
            node.totalSize += child.totalSize;
            node.uniquePerms += child.uniquePerms;
            for (const [a,s] of Object.entries(child.stats)) {
                if (!node.stats[a]) node.stats[a]={count:0,size:0};
                node.stats[a].count += s.count;
                node.stats[a].size += s.size;
            }
        }
    }
    propagate(root);
    return root;
}
const TREE = buildTree(DATA.folders);

// ── Navigation ──
const main = document.getElementById('main');
const navItems = document.querySelectorAll('.nav li');
let currentPage = 'overview';

function navigate(page) {
    currentPage = page;
    navItems.forEach(li => li.classList.toggle('active', li.dataset.page === page));
    const renderers = {
        overview: renderOverview,
        delete:   () => renderAction('Delete'),
        archive:  () => renderAction('Archive'),
        fix:      () => renderAction('Fix'),
        link:     renderReferences,
        review:   () => renderAction('Review'),
        migrate:  () => renderAction('Migrate'),
        duplicates: renderDuplicates,
        explorer: renderExplorer,
        permissions: renderPermissions,
        history: renderHistory
    };
    (renderers[page]||renderOverview)();
    main.scrollTop = 0;
}
navItems.forEach(li => li.addEventListener('click', () => navigate(li.dataset.page)));

// Delegated click handler for data-nav attributes (avoids inline onclick)
main.addEventListener('click', e => {
    const el = e.target.closest('[data-nav]');
    if (el) navigate(el.dataset.nav);
});

// ── OVERVIEW ──
function renderOverview() {
    const s = DATA.summary;
    const actions = DATA.actions;          // inclusive (multi-counted)
    const primary = DATA.primaryActions;   // exclusive (for stacked bar)
    const actionOrder = ['Delete','Archive','Fix','Link','Review','Migrate'];

    // Stacked bar uses PRIMARY actions (sums to 100%)
    let stackedSegs = '';
    for (const a of actionOrder) {
        const v = primary[a];
        if (!v) continue;
        const w = pct(v.count, s.totalFiles);
        stackedSegs += '<div class="seg" style="width:'+w+'%;background:'+actionColor(a)+'" title="'+a+': '+fmt(v.count)+' files ('+fmtGB(v.sizeGB)+')" data-nav="'+a.toLowerCase()+'">'+( parseFloat(w)>4 ? a : '' )+'</div>';
    }
    let legendItems = actionOrder.map(a => '<span class="legend-item"><span class="dot" style="background:'+actionColor(a)+'"></span>'+a+' ('+fmt(primary[a]?.count||0)+')</span>').join('');

    // Action bars use TOTAL actions (inclusive – files can be in multiple)
    const barMax = Math.max(...actionOrder.map(a=>(actions[a]?.count||0)), s.duplicateFiles||0);
    let actionBars = '';
    for (const a of actionOrder) {
        const v = actions[a];
        if (!v) continue;
        actionBars += '<div class="bar-row"><span class="bar-label" style="color:'+actionColor(a)+'">'+a+'</span><div class="bar-track"><div class="bar-fill" style="width:'+pct(v.count,barMax)+'%;background:'+actionColor(a)+'">'+fmt(v.count)+' ('+pct(v.count,s.totalFiles)+'%)</div></div><span class="bar-val">'+fmtGB(v.sizeGB)+'</span></div>';
    }
    if (s.duplicateFiles > 0) {
        actionBars += '<div class="bar-row"><span class="bar-label" style="color:var(--dupe)">Duplicates</span><div class="bar-track"><div class="bar-fill" style="width:'+pct(s.duplicateFiles,barMax)+'%;background:var(--dupe)">'+fmt(s.duplicateFiles)+' ('+pct(s.duplicateFiles,s.totalFiles)+'%)</div></div><span class="bar-val">'+fmtGB(s.duplicateSizeGB)+'</span></div>';
    }

    // Age bars
    const ageSorted = [...DATA.ageBuckets].sort((a,b)=>b.sizeGB-a.sizeGB);
    const ageMax = Math.max(...ageSorted.map(a=>a.count));
    let ageRows = '';
    for (const a of ageSorted) {
        ageRows += '<div class="bar-row"><span class="bar-label">'+a.name+'</span><div class="bar-track"><div class="bar-fill" style="width:'+pct(a.count,ageMax)+'%;background:#64748b">'+fmt(a.count)+'</div></div><span class="bar-val">'+fmtGB(a.sizeGB)+'</span></div>';
    }

    // Extension table
    let extRows = '';
    for (const e of DATA.topExtensions.slice(0,12)) {
        extRows += '<tr><td>'+e.name+'</td><td class="r">'+fmt(e.count)+'</td><td class="r">'+fmtGB(e.sizeGB)+'</td><td class="r">'+pct(e.count,s.totalFiles)+'%</td></tr>';
    }

    // Savings calculation (from primary stats)
    const deleteGB = primary.Delete?.sizeGB || 0;
    const archiveGB = primary.Archive?.sizeGB || 0;

    main.innerHTML = '<h2>Overview</h2>'
    +'<p class="page-desc">Analysis of <strong>'+fmt(s.totalFiles)+'</strong> files ('+fmtGB(s.totalSizeGB)+') in <code>'+DATA.rootPath+'</code>'
    +(s.uniquePermFolders>0?' &mdash; <strong>'+fmt(s.uniquePermFolders)+'</strong> folders with unique NTFS permissions':'')+'</p>'

    +'<div class="note">Files can have multiple statuses (e.g. Fix + Archive). All counts include each file in <em>every</em> applicable category. Only the action breakdown (stacked bar) shows the primary action per file.</div>'

    +'<div class="cards">'
    +'<div class="card accent-red clickable" data-nav="delete"><div class="label">Delete</div><div class="value" style="color:var(--delete)">'+fmt(actions.Delete?.count||0)+'</div><div class="sub">'+fmtGB(actions.Delete?.sizeGB||0)+' to reclaim</div></div>'
    +'<div class="card accent-orange clickable" data-nav="archive"><div class="label">Archive</div><div class="value" style="color:var(--archive)">'+fmt(actions.Archive?.count||0)+'</div><div class="sub">'+fmtGB(actions.Archive?.sizeGB||0)+' to cold storage</div></div>'
    +'<div class="card accent-purple clickable" data-nav="fix"><div class="label">Fix</div><div class="value" style="color:var(--fix)">'+fmt(actions.Fix?.count||0)+'</div><div class="sub">Incompatible names/paths</div></div>'
    +'<div class="card accent-link clickable" data-nav="link"><div class="label">Links</div><div class="value" style="color:var(--link)">'+fmt(actions.Link?.count||0)+'</div><div class="sub">'+fmt(s.macroExternal)+' external, '+fmt(s.macroInternal)+' internal</div></div>'
    +'<div class="card accent-blue clickable" data-nav="review"><div class="label">Review</div><div class="value" style="color:var(--review)">'+fmt(actions.Review?.count||0)+'</div><div class="sub">'+fmtGB(actions.Review?.sizeGB||0)+'</div></div>'
    +'<div class="card accent-green clickable" data-nav="migrate"><div class="label">Migrate</div><div class="value" style="color:var(--migrate)">'+fmt(actions.Migrate?.count||0)+'</div><div class="sub">'+fmtGB(actions.Migrate?.sizeGB||0)+' to SharePoint</div></div>'
    +'<div class="card accent-teal clickable" data-nav="duplicates"><div class="label">Duplicates</div><div class="value" style="color:var(--dupe)">'+fmt(s.duplicateFiles)+'</div><div class="sub">'+fmtGB(s.duplicateSizeGB)+'</div></div>'
    +'</div>'

    +'<h3>Primary action breakdown</h3>'
    +'<div class="stacked-bar">'+stackedSegs+'</div>'
    +'<div class="legend">'+legendItems+'</div>'

    // Overlap bars (inclusive counts vs total)
    +'<h3>Total per category <span style="font-size:.75rem;font-weight:400;color:var(--text-light)">(files with multiple statuses count in every category)</span></h3>'
    +'<div class="bar-chart mt1" style="max-width:900px">'+actionBars+'</div>'

    // Additional indicators
    +'<div style="margin-bottom:1.5rem">'
    +'<div class="overlap-row"><span class="overlap-label">Duplicate overlap:</span><div class="overlap-track" style="cursor:pointer" data-nav="duplicates"><div class="overlap-fill" style="width:'+pct(s.duplicateFiles,s.totalFiles)+'%;background:var(--dupe)"></div></div><span class="overlap-val" style="color:var(--dupe)">'+fmt(s.duplicateFiles)+' ('+pct(s.duplicateFiles,s.totalFiles)+'%)</span></div>'
    +'<div class="overlap-row"><span class="overlap-label">Broken inheritance (files):</span><div class="overlap-track"><div class="overlap-fill" style="width:'+pct(s.uniquePermFiles,s.totalFiles)+'%;background:#e11d48"></div></div><span class="overlap-val" style="color:#e11d48">'+fmt(s.uniquePermFiles)+' ('+pct(s.uniquePermFiles,s.totalFiles)+'%)</span></div>'
    +'<div class="overlap-row"><span class="overlap-label">Broken inheritance (folders):</span><div class="overlap-track"><div class="overlap-fill" style="width:'+(s.uniquePermFolders > 0 ? Math.min(100, s.uniquePermFolders) : 0)+'%;background:#be123c"></div></div><span class="overlap-val" style="color:#be123c">'+fmt(s.uniquePermFolders)+' folders</span></div>'
    +'</div>'

    +'<div style="display:grid;grid-template-columns:1fr 1fr;gap:2rem">'
    +'<div><h3>Files by age</h3><div class="bar-chart mt1">'+ageRows+'</div></div>'
    +'<div><h3>Top file types</h3><div class="tbl-wrap mt1"><table id="tbl-ext"><thead><tr><th>Extension</th><th class="r">Count</th><th class="r">Size</th><th class="r">%</th></tr></thead><tbody>'+extRows+'</tbody></table></div></div>'
    +'</div>';

    addTableSort(document.getElementById('tbl-ext'));
}

// ── ACTION DETAIL ──
function renderAction(action) {
    const stats = DATA.actions[action];
    if (!stats) { main.innerHTML='<h2>'+action+'</h2><p>No files in this category.</p>'; return; }

    const notable = DATA.notable[action] || [];
    let fileRows = '';
    for (const f of notable) {
        const multi = (f.a||'').includes('|');
        fileRows += '<tr'+(multi?' class="priority-row"':'')+'>'
            +'<td title="'+escHtml(f.p)+'">'+escHtml(f.n)+'</td>'
            +'<td>'+f.e+'</td>'
            +'<td class="r">'+fmtSize(f.s)+'</td>'
            +'<td>'+f.g+'</td>'
            +'<td>'+renderStatusPills(f.a)+'</td>'
            +'<td class="truncate" style="max-width:350px" title="'+escHtml(f.p)+'">'+escHtml(f.p)+'</td>'
            +'<td style="font-size:.75rem;max-width:300px;overflow:hidden;text-overflow:ellipsis" title="'+escHtml(f.r||'')+'">'+escHtml(f.r||'')+'</td>'
            +'</tr>';
    }

    const folderMap = {};
    for (const f of DATA.folders) {
        if (f.a[action]) {
            const parts = f.p.split('\\');
            const key = parts.slice(0,3).join('\\');
            if (!folderMap[key]) folderMap[key]={path:key,count:0,size:0};
            folderMap[key].count += f.a[action][0];
            folderMap[key].size += f.a[action][1];
        }
    }
    const folderList = Object.values(folderMap).sort((a,b)=>b.size-a.size);
    let folderRows = '';
    for (const fl of folderList.slice(0,40)) {
        folderRows += '<tr><td class="mono truncate" style="max-width:450px" title="'+escHtml(fl.path)+'">'+escHtml(fl.path)+'</td><td class="r">'+fmt(fl.count)+'</td><td class="r">'+fmtSize(fl.size)+'</td><td class="r">'+pct(fl.count,stats.count)+'%</td></tr>';
    }

    main.innerHTML = '<h2>'+actionIcon(action)+' '+action+'</h2>'
    +'<p class="page-desc">'+actionDesc(action)+'</p>'
    +(stats.count !== (DATA.primaryActions[action]?.count||0) ? '<div class="note">This overview shows <strong>all</strong> files with status '+action+' ('+fmt(stats.count)+'), including files that also have other statuses. Primary '+action+': '+fmt(DATA.primaryActions[action]?.count||0)+'.</div>' : '')
    +'<div class="cards">'
    +'<div class="card"><div class="label">Files (total)</div><div class="value" style="color:'+actionColor(action)+'">'+fmt(stats.count)+'</div><div class="sub">'+pct(stats.count,DATA.summary.totalFiles)+'% of total</div></div>'
    +'<div class="card"><div class="label">Size</div><div class="value">'+fmtGB(stats.sizeGB)+'</div><div class="sub">'+pct(stats.sizeGB,DATA.summary.totalSizeGB)+'% of total</div></div>'
    +'<div class="card"><div class="label">Primary '+action+'</div><div class="value">'+fmt(DATA.primaryActions[action]?.count||0)+'</div><div class="sub">Only '+action+' as main action</div></div>'
    +'</div>'
    +'<h3>Top folders</h3><div class="tbl-wrap"><table id="tbl-folders"><thead><tr><th>Folder</th><th class="r">Files</th><th class="r">Size</th><th class="r">% of action</th></tr></thead><tbody>'+folderRows+'</tbody></table></div>'
    +'<h3 class="mt2">Largest files'+(notable.length>=30?' (Top 30)':'')+'</h3>'
    +'<div class="tbl-wrap"><table id="tbl-files"><thead><tr><th>File name</th><th>Ext</th><th class="r">Size</th><th>Age</th><th>Status</th><th>Path</th><th>Reason</th></tr></thead><tbody>'+fileRows+'</tbody></table></div>';

    addTableSort(document.getElementById('tbl-folders'));
    addTableSort(document.getElementById('tbl-files'));
}

// ── DUPLICATES ──
function renderDuplicates() {
    const s = DATA.summary;
    const dupes = DATA.topDuplicates || [];
    let dupeRows = '';
    for (const d of dupes) {
        const pathsHtml = d.paths.map(p=>'<div class="truncate mono" style="max-width:500px;font-size:.75rem" title="'+escHtml(p)+'">'+escHtml(p)+'</div>').join('');
        dupeRows += '<tr><td>'+escHtml(d.n)+'</td><td class="r" style="font-weight:700;color:var(--delete)">'+d.count+'x</td><td class="r">'+fmtSize(d.s)+'</td><td class="r">'+fmtSize(d.s*(d.count-1))+'</td><td>'+pathsHtml+'</td></tr>';
    }

    main.innerHTML = '<h2>\u{1F4D1} Duplicates</h2>'
    +'<p class="page-desc">Files with the same name and size, found in multiple locations.</p>'
    +'<div class="cards">'
    +'<div class="card accent-teal"><div class="label">Duplicates</div><div class="value" style="color:var(--dupe)">'+fmt(s.duplicateFiles)+'</div></div>'
    +'<div class="card accent-red"><div class="label">Total size</div><div class="value">'+fmtGB(s.duplicateSizeGB)+'</div><div class="sub">Potential savings after deduplication</div></div>'
    +'</div>'
    +'<h3>Most duplicated files</h3>'
    +'<div class="tbl-wrap"><table id="tbl-dupes"><thead><tr><th>File name</th><th class="r">Copies</th><th class="r">Each</th><th class="r">Wasted</th><th>Locations</th></tr></thead><tbody>'+dupeRows+'</tbody></table></div>';

    addTableSort(document.getElementById('tbl-dupes'));
}

// ── LINKS (merged action + detail view) ──
function renderReferences() {
    const s = DATA.summary;
    const stats = DATA.actions.Link;
    const macros = DATA.macroList || [];
    const priorityItems = macros.filter(m => m.pr === 1);
    const extMacros = macros.filter(m => m.t === 'External');
    const intMacros = macros.filter(m => m.t === 'Internal');

    // Extension breakdown
    const extBreakdown = {};
    for (const m of macros) { extBreakdown[m.e] = (extBreakdown[m.e]||0)+1; }
    const extMax = Math.max(...Object.values(extBreakdown), 1);
    let extBars = '';
    for (const [ext, cnt] of Object.entries(extBreakdown).sort((a,b)=>b[1]-a[1])) {
        extBars += '<div class="bar-row"><span class="bar-label">'+ext+'</span><div class="bar-track"><div class="bar-fill" style="width:'+pct(cnt,extMax)+'%;background:var(--link)">'+cnt+'</div></div></div>';
    }

    // Top folders (from action data)
    const folderMap = {};
    for (const f of DATA.folders) {
        if (f.a.Link) {
            const parts = f.p.split('\\');
            const key = parts.slice(0,3).join('\\');
            if (!folderMap[key]) folderMap[key]={path:key,count:0,size:0};
            folderMap[key].count += f.a.Link[0];
            folderMap[key].size += f.a.Link[1];
        }
    }
    const folderList = Object.values(folderMap).sort((a,b)=>b.count-a.count);
    let folderRows = '';
    const totalKopCount = stats?.count || macros.length;
    for (const fl of folderList.slice(0,30)) {
        folderRows += '<tr><td class="mono truncate" style="max-width:450px" title="'+escHtml(fl.path)+'">'+escHtml(fl.path)+'</td><td class="r">'+fmt(fl.count)+'</td><td class="r">'+fmtSize(fl.size)+'</td><td class="r">'+pct(fl.count,totalKopCount)+'%</td></tr>';
    }

    // Build table rows
    function macroRow(m) {
        const isPriority = m.pr === 1;
        const typeLabel = m.t === 'External'
            ? '<span class="pill" style="background:#ea580c">External</span>'
            : '<span class="pill" style="background:#16a34a">Internal</span>';
        const priorityLabel = isPriority ? ' <span class="pill" style="background:#dc2626">Priority</span>' : '';
        return '<tr'+(isPriority?' class="priority-row"':'')+'>'
            +'<td title="'+escHtml(m.p)+'">'+escHtml(m.n)+'</td>'
            +'<td>'+m.e+'</td>'
            +'<td class="r">'+fmtSize(m.s)+'</td>'
            +'<td>'+typeLabel+priorityLabel+'</td>'
            +'<td>'+m.g+'</td>'
            +'<td class="truncate" style="max-width:300px" title="'+escHtml(m.p)+'">'+escHtml(m.p)+'</td>'
            +'<td style="font-size:.75rem;max-width:250px;overflow:hidden;text-overflow:ellipsis" title="'+escHtml(m.d||'')+'">'+escHtml(m.d||'')+'</td>'
            +'</tr>';
    }

    let allRows = macros.map(macroRow).join('');

    main.innerHTML = '<h2>\u{1F517} Links &amp; Macros</h2>'
    +'<p class="page-desc">Files with VBA macros and/or references to external sources. These may not work correctly after migration.</p>'

    // Info box
    +'<div class="action-section" style="background:var(--link-bg);border:1px solid #fed7aa">'
    +'<h3 style="color:#c2410c">\u26A0\uFE0F Important: links &amp; macros after migration</h3>'
    +'<p style="margin:.5rem 0">After migration, VBA macros and references to external sources often <strong>stop working</strong>. '
    +'Contact the migration team <strong>before migrating</strong> if any files perform essential tasks.</p>'
    +'<p style="margin:.75rem 0 .25rem"><strong>What do the types mean?</strong></p>'
    +'<ul style="margin:.25rem 0 0 1.25rem;line-height:1.8">'
    +'<li><span class="pill" style="background:#dc2626">Priority</span> &mdash; Recent file (&lt;1 year) with external links. This file is <strong>actively used</strong> and requires action before migration.</li>'
    +'<li><span class="pill" style="background:#ea580c">External</span> &mdash; References <strong>external sources</strong>: URLs, network paths, COM objects, DLLs, databases, or the file system. Often <strong>stops working</strong> after migration.</li>'
    +'<li><span class="pill" style="background:#16a34a">Internal</span> &mdash; Contains only <strong>internal logic</strong>: formatting, calculations, forms. May still work in the desktop version of Office.</li>'
    +'</ul>'
    +'<p style="margin:.75rem 0 .25rem"><strong>Note</strong></p>'
    +'<p>The scan is indicative and may contain errors. Pay particular attention to files marked <span class="pill" style="background:#dc2626">Priority</span>.</p>'
    +'</div>'

    +'<div class="cards">'
    +'<div class="card accent-link"><div class="label">Total</div><div class="value" style="color:var(--link)">'+fmt(s.macroFiles)+'</div><div class="sub">'+fmtGB(s.macroFileSizeGB)+'</div></div>'
    +(s.macroExternalRecent > 0 ? '<div class="card" style="border-top:3px solid #dc2626"><div class="label">Priority</div><div class="value" style="color:#dc2626">'+fmt(s.macroExternalRecent)+'</div><div class="sub">External + recent (&lt;1y)</div></div>' : '')
    +'<div class="card" style="border-top:3px solid #ea580c"><div class="label">External</div><div class="value" style="color:#ea580c">'+fmt(s.macroExternal)+'</div><div class="sub">External references</div></div>'
    +'<div class="card" style="border-top:3px solid #16a34a"><div class="label">Internal</div><div class="value" style="color:#16a34a">'+fmt(s.macroInternal)+'</div><div class="sub">Internal logic</div></div>'
    +'</div>'

    +'<div style="display:grid;grid-template-columns:1fr 1fr;gap:2rem;margin-bottom:2rem">'
    +'<div><h3>Top folders</h3><div class="tbl-wrap mt1"><table id="tbl-kop-folders"><thead><tr><th>Folder</th><th class="r">Files</th><th class="r">Size</th><th class="r">%</th></tr></thead><tbody>'+folderRows+'</tbody></table></div></div>'
    +'<div><h3>By file type</h3><div class="bar-chart mt1">'+extBars+'</div></div>'
    +'</div>'

    +'<h3>All links ('+fmt(macros.length)+')</h3>'
    +'<div class="tbl-wrap"><table id="tbl-refs"><thead><tr><th>File name</th><th>Ext</th><th class="r">Size</th><th>Type</th><th>Age</th><th>Path</th><th>Details</th></tr></thead><tbody>'+allRows+'</tbody></table></div>';

    addTableSort(document.getElementById('tbl-kop-folders'));
    addTableSort(document.getElementById('tbl-refs'));
}

// ── FOLDER EXPLORER ──
function renderExplorer() {
    main.innerHTML = '<h2>\u{1F4C1} Folder Explorer</h2>'
    +'<p class="page-desc">Browse the folder structure with action indicators. Click to expand. Counts are inclusive (files with multiple statuses count in every category).</p>'
    +'<div class="search-wrap"><span class="icon">\u{1F50D}</span><input type="text" id="tree-search" placeholder="Search folders..."></div>'
    +'<div class="tree" id="tree-root"></div>';

    const container = document.getElementById('tree-root');
    renderTreeLevel(container, TREE.children, 0);

    document.getElementById('tree-search').addEventListener('input', function() {
        const q = this.value.toLowerCase().trim();
        const nodes = container.querySelectorAll('.tree-node');
        if (!q) { nodes.forEach(n => {n.style.display=''; n.querySelector('.tree-children')?.classList.remove('open'); n.querySelector('.tree-toggle')?.classList.remove('open');}); return; }
        nodes.forEach(n => {
            const name = n.dataset.name?.toLowerCase()||'';
            const match = name.includes(q);
            n.style.display = match ? '' : 'none';
            if (match) {
                let p = n.parentElement;
                while (p && p.id !== 'tree-root') {
                    p.style.display = '';
                    if (p.classList.contains('tree-children')) p.classList.add('open');
                    if (p.classList.contains('tree-node')) {
                        p.style.display = '';
                        const tog = p.querySelector(':scope > .tree-row > .tree-toggle');
                        if (tog) tog.classList.add('open');
                    }
                    p = p.parentElement;
                }
            }
        });
    });
}

function renderTreeLevel(container, children, depth) {
    const sorted = Object.entries(children).sort((a,b) => b[1].totalSize - a[1].totalSize);
    const limit = depth < 2 ? sorted.length : Math.min(sorted.length, 50);

    for (let i = 0; i < limit; i++) {
        const [name, node] = sorted[i];
        const hasChildren = Object.keys(node.children).length > 0;
        const div = document.createElement('div');
        div.className = 'tree-node';
        div.dataset.name = name;

        let pills = '';
        for (const a of ['Delete','Archive','Fix','Link','Review','Migrate']) {
            if (node.stats[a]) {
                pills += '<span class="tree-pill" style="background:'+actionColor(a)+'" title="'+a+': '+fmt(node.stats[a].count)+' files">'+node.stats[a].count+'</span>';
            }
        }

        div.innerHTML = '<div class="tree-row">'
            +'<span class="tree-toggle'+(hasChildren?'':' hidden')+'">&#9654;</span>'
            +'<span class="tree-name" title="'+escHtml(name)+'">&#128193; '+escHtml(name)+'</span>'
            +'<span class="tree-pills">'+pills+'</span>'
            +'<span class="tree-count">'+fmt(node.totalFiles)+' files</span>'
            +'<span class="tree-size">'+fmtSize(node.totalSize)+'</span>'
            +'</div>';

        if (hasChildren) {
            const childContainer = document.createElement('div');
            childContainer.className = 'tree-children';
            div.appendChild(childContainer);
            let loaded = false;
            div.querySelector('.tree-row').addEventListener('click', () => {
                const tog = div.querySelector('.tree-toggle');
                const isOpen = childContainer.classList.toggle('open');
                tog.classList.toggle('open', isOpen);
                if (!loaded && isOpen) { loaded = true; renderTreeLevel(childContainer, node.children, depth+1); }
            });
        }
        container.appendChild(div);
    }

    if (sorted.length > limit) {
        const more = document.createElement('div');
        more.style.cssText = 'padding:.5rem;font-size:.8rem;color:var(--text-light);cursor:pointer';
        more.textContent = '... and '+(sorted.length-limit)+' more folders (click to load)';
        more.addEventListener('click', () => {
            more.remove();
            for (let i = limit; i < sorted.length; i++) {
                renderTreeNode(container, sorted[i][0], sorted[i][1], depth);
            }
        });
        container.appendChild(more);
    }
}

function renderTreeNode(container, name, node, depth) {
    const hasChildren = Object.keys(node.children).length > 0;
    const div = document.createElement('div');
    div.className = 'tree-node';
    div.dataset.name = name;
    let pills = '';
    for (const a of ['Delete','Archive','Fix','Link','Review','Migrate']) {
        if (node.stats[a]) pills += '<span class="tree-pill" style="background:'+actionColor(a)+'">'+node.stats[a].count+'</span>';
    }
    div.innerHTML = '<div class="tree-row"><span class="tree-toggle'+(hasChildren?'':' hidden')+'">&#9654;</span><span class="tree-name" title="'+escHtml(name)+'">'+(hasChildren?'&#128193;':'&#128196;')+' '+escHtml(name)+'</span><span class="tree-pills">'+pills+'</span><span class="tree-count">'+fmt(node.totalFiles)+' files</span><span class="tree-size">'+fmtSize(node.totalSize)+'</span></div>';
    if (hasChildren) {
        const cc = document.createElement('div');
        cc.className = 'tree-children';
        div.appendChild(cc);
        let ld = false;
        div.querySelector('.tree-row').addEventListener('click', () => {
            const t = div.querySelector('.tree-toggle');
            const o = cc.classList.toggle('open');
            t.classList.toggle('open', o);
            if (!ld && o) { ld = true; renderTreeLevel(cc, node.children, depth+1); }
        });
    }
    container.appendChild(div);
}

// ── NTFS PERMISSIONS TREE ──
function buildPermTree(permFolders) {
    const root = {name:'Root',children:{},groups:[],hasOwnAcl:false};
    for (const f of permFolders) {
        const parts = f.p.split('\\').filter(Boolean);
        let node = root;
        for (const part of parts) {
            if (!node.children[part]) node.children[part]={name:part,children:{},groups:[],hasOwnAcl:false};
            node = node.children[part];
        }
        node.groups = f.g || [];
        node.hasOwnAcl = node.groups.length > 0;
    }
    return root;
}

function permTagClass(rights) {
    const r = rights.toLowerCase();
    if (r.includes('fullcontrol') || r.includes('full control')) return 'full';
    if (r.includes('modify') || r.includes('write') || r.includes('change')) return 'modify';
    if (r.includes('read') || r.includes('listdirectory') || r.includes('traverse')) return 'read';
    return 'other';
}

function renderPermGroupTags(groups) {
    return groups.map(g => {
        const parts = g.split(':');
        const identity = parts[0] || g;
        const rights = parts.slice(1).join(':') || '';
        const shortName = identity.replace(/^[^\\]*\\/i, '');
        const cls = permTagClass(rights);
        const title = identity + (rights ? ' \u2192 ' + rights : '');
        return '<span class="perm-tag '+cls+'" title="'+escHtml(title)+'">'+escHtml(shortName)+(rights?' ('+escHtml(rights.split(',')[0].trim())+')':'')+'</span>';
    }).join('');
}

const PERM_TREE = buildPermTree(DATA.permFolders || []);

function renderPermissions() {
    const totalFolders = (DATA.permFolders||[]).length;
    const allGroups = new Set();
    for (const f of (DATA.permFolders||[])) { for (const g of (f.g||[])) { allGroups.add(g.split(':')[0]); } }

    let groupListHtml = [...allGroups].sort().map(g => '<span class="perm-tag other" style="margin:2px">'+escHtml(g.replace(/^[^\\]*\\/i,''))+'</span>').join('');

    main.innerHTML = '<h2>\u{1F512} Unique permissions</h2>'
    +'<p class="page-desc">Folders with unique NTFS permissions (broken inheritance). Only folders with explicit permissions are shown.</p>'
    +'<div class="cards">'
    +'<div class="card accent-purple"><div class="label">Folders with ACLs</div><div class="value">'+fmt(totalFolders)+'</div><div class="sub">Broken inheritance</div></div>'
    +'<div class="card accent-blue"><div class="label">Unique groups</div><div class="value">'+fmt(allGroups.size)+'</div></div>'
    +'<div class="card"><div class="label">Files with ACLs</div><div class="value">'+fmt(DATA.summary.uniquePermFiles)+'</div><div class="sub">'+fmtGB(DATA.summary.uniquePermFileSizeGB)+'</div></div>'
    +'</div>'
    +'<div style="background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:1rem;margin-bottom:1rem">'
    +'<strong style="font-size:.85rem">Groups found:</strong><div style="margin-top:.5rem;display:flex;flex-wrap:wrap;gap:4px">'+groupListHtml+'</div></div>'
    +'<div style="background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:.75rem 1rem;margin-bottom:1rem;display:flex;gap:1.5rem;flex-wrap:wrap;align-items:center;font-size:.8rem">'
    +'<strong>Legend:</strong>'
    +'<span><span class="perm-tag read">Read</span> Read</span>'
    +'<span><span class="perm-tag modify">Modify</span> Write</span>'
    +'<span><span class="perm-tag full">Full</span> Full control</span>'
    +'<span><span class="perm-tag other">Other</span> Other</span>'
    +'</div>'
    +'<div class="search-wrap"><span class="icon">\u{1F50D}</span><input type="text" id="perm-search" placeholder="Search by folder name or group name..."></div>'
    +'<div class="tree" id="perm-tree-root"></div>';

    const container = document.getElementById('perm-tree-root');

    if (PERM_TREE.hasOwnAcl) {
        renderPermRootNode(container, PERM_TREE);
    } else {
        renderPermTreeLevel(container, PERM_TREE.children, 0);
    }

    document.getElementById('perm-search').addEventListener('input', function() {
        const q = this.value.toLowerCase().trim();
        const nodes = container.querySelectorAll('.tree-node');
        if (!q) { nodes.forEach(n => {n.style.display=''; n.querySelector('.tree-children')?.classList.remove('open'); n.querySelector('.tree-toggle')?.classList.remove('open');}); return; }
        nodes.forEach(n => {
            const name = (n.dataset.name||'').toLowerCase();
            const groups = (n.dataset.groups||'').toLowerCase();
            const match = name.includes(q) || groups.includes(q);
            n.style.display = match ? '' : 'none';
            if (match) {
                let p = n.parentElement;
                while (p && p.id !== 'perm-tree-root') {
                    p.style.display = '';
                    if (p.classList.contains('tree-children')) p.classList.add('open');
                    if (p.classList.contains('tree-node')) {
                        p.style.display = '';
                        const tog = p.querySelector(':scope > .tree-row > .tree-toggle');
                        if (tog) tog.classList.add('open');
                    }
                    p = p.parentElement;
                }
            }
        });
    });
}

function renderPermRootNode(container, tree) {
    const hasChildren = Object.keys(tree.children).length > 0;
    const div = document.createElement('div');
    div.className = 'tree-node perm-node';
    div.dataset.name = DATA.rootPath;
    div.dataset.groups = (tree.groups||[]).join('; ');
    div.innerHTML = '<div class="tree-row">'
        +'<span class="tree-toggle'+(hasChildren?'':' hidden')+'">&#9654;</span>'
        +'<span class="tree-name">\u{1F512} '+escHtml(DATA.rootPath)+' (root)</span>'
        +'</div>'
        +'<div class="perm-groups">'+renderPermGroupTags(tree.groups)+'</div>';
    if (hasChildren) {
        const cc = document.createElement('div');
        cc.className = 'tree-children';
        div.appendChild(cc);
        let loaded = false;
        div.querySelector('.tree-row').addEventListener('click', () => {
            const tog = div.querySelector('.tree-toggle');
            const isOpen = cc.classList.toggle('open');
            tog.classList.toggle('open', isOpen);
            if (!loaded && isOpen) { loaded = true; renderPermTreeLevel(cc, tree.children, 0); }
        });
    }
    container.appendChild(div);
}

function renderPermTreeLevel(container, children, depth) {
    const sorted = Object.entries(children).sort((a,b) => {
        if (a[1].hasOwnAcl !== b[1].hasOwnAcl) return a[1].hasOwnAcl ? -1 : 1;
        return a[0].localeCompare(b[0]);
    });
    for (const [name, node] of sorted) {
        const hasChildren = Object.keys(node.children).length > 0;
        const div = document.createElement('div');
        div.className = 'tree-node' + (node.hasOwnAcl ? ' perm-node' : '');
        div.dataset.name = name;
        div.dataset.groups = (node.groups||[]).join('; ');
        const icon = node.hasOwnAcl ? '\u{1F512}' : '&#128193;';
        const groupsHtml = node.hasOwnAcl ? '<div class="perm-groups">'+renderPermGroupTags(node.groups)+'</div>' : '';
        div.innerHTML = '<div class="tree-row">'
            +'<span class="tree-toggle'+(hasChildren?'':' hidden')+'">&#9654;</span>'
            +'<span class="tree-name">'+icon+' '+escHtml(name)+'</span>'
            +'</div>'+groupsHtml;
        if (hasChildren) {
            const cc = document.createElement('div');
            cc.className = 'tree-children';
            div.appendChild(cc);
            let loaded = false;
            div.querySelector('.tree-row').addEventListener('click', () => {
                const tog = div.querySelector('.tree-toggle');
                const isOpen = cc.classList.toggle('open');
                tog.classList.toggle('open', isOpen);
                if (!loaded && isOpen) { loaded = true; renderPermTreeLevel(cc, node.children, depth+1); }
            });
        }
        container.appendChild(div);
    }
}

// ── HISTORY ──
function renderHistory() {
    const history = DATA.history || [];
    if (history.length === 0) {
        main.innerHTML = '<h2>&#128200; History</h2><p class="page-desc">No historical data available yet. A data point is added after each scan.</p>';
        return;
    }

    // Build data table rows
    let tableRows = '';
    for (let i = history.length - 1; i >= 0; i--) {
        const h = history[i];
        const delta = i > 0 ? h.fixCount - history[i-1].fixCount : 0;
        const deltaStr = i > 0 ? (delta > 0 ? '<span style="color:var(--delete)">+'+delta+'</span>' : delta < 0 ? '<span style="color:var(--migrate)">'+delta+'</span>' : '<span style="color:var(--text-light)">0</span>') : '&mdash;';
        tableRows += '<tr><td>'+escHtml(h.date)+'</td><td class="r">'+fmt(h.totalFiles)+'</td><td class="r">'+fmtGB(h.totalSizeGB)+'</td><td class="r" style="font-weight:700;color:var(--fix)">'+fmt(h.fixCount)+'</td><td class="r">'+deltaStr+'</td></tr>';
    }

    // SVG line chart
    const W = 800, H = 300, PAD = 50, PADR = 60;
    const n = history.length;
    const maxFix = Math.max(...history.map(h => h.fixCount), 1);
    const maxSize = Math.max(...history.map(h => h.totalSizeGB), 0.01);

    function x(i) { return PAD + (n === 1 ? (W-PAD-PADR)/2 : i * ((W - PAD - PADR) / (n - 1))); }
    function yFix(v) { return PAD + (H - 2*PAD) - (v / maxFix) * (H - 2*PAD); }
    function ySize(v) { return PAD + (H - 2*PAD) - (v / maxSize) * (H - 2*PAD); }

    // Grid lines
    let gridLines = '';
    for (let g = 0; g <= 4; g++) {
        const gy = PAD + g * (H - 2*PAD) / 4;
        const fixVal = Math.round(maxFix * (4 - g) / 4);
        const sizeVal = (maxSize * (4 - g) / 4).toFixed(1);
        gridLines += '<line x1="'+PAD+'" y1="'+gy+'" x2="'+(W-PADR)+'" y2="'+gy+'" stroke="#e2e8f0" stroke-width="1"/>';
        gridLines += '<text x="'+(PAD-8)+'" y="'+(gy+4)+'" text-anchor="end" fill="var(--fix)" font-size="11">'+fixVal+'</text>';
        gridLines += '<text x="'+(W-PADR+8)+'" y="'+(gy+4)+'" text-anchor="start" fill="var(--review)" font-size="11">'+sizeVal+'</text>';
    }

    // Fix count line
    let fixPath = '';
    let fixDots = '';
    for (let i = 0; i < n; i++) {
        const px = x(i), py = yFix(history[i].fixCount);
        fixPath += (i === 0 ? 'M' : 'L') + px + ',' + py;
        fixDots += '<circle cx="'+px+'" cy="'+py+'" r="4" fill="var(--fix)" stroke="#fff" stroke-width="2"><title>'+escHtml(history[i].date)+'\nFix: '+fmt(history[i].fixCount)+'</title></circle>';
    }

    // Size line
    let sizePath = '';
    let sizeDots = '';
    for (let i = 0; i < n; i++) {
        const px = x(i), py = ySize(history[i].totalSizeGB);
        sizePath += (i === 0 ? 'M' : 'L') + px + ',' + py;
        sizeDots += '<circle cx="'+px+'" cy="'+py+'" r="4" fill="var(--review)" stroke="#fff" stroke-width="2"><title>'+escHtml(history[i].date)+'\nSize: '+fmtGB(history[i].totalSizeGB)+'</title></circle>';
    }

    // X-axis labels
    let xLabels = '';
    const maxLabels = Math.min(n, 12);
    const step = Math.max(1, Math.floor(n / maxLabels));
    for (let i = 0; i < n; i += step) {
        const label = history[i].date.substring(0, 10);
        xLabels += '<text x="'+x(i)+'" y="'+(H-PAD+20)+'" text-anchor="middle" fill="var(--text-light)" font-size="10" transform="rotate(-30,'+x(i)+','+(H-PAD+20)+')">' + label + '</text>';
    }
    if ((n-1) % step !== 0) {
        const label = history[n-1].date.substring(0, 10);
        xLabels += '<text x="'+x(n-1)+'" y="'+(H-PAD+20)+'" text-anchor="middle" fill="var(--text-light)" font-size="10" transform="rotate(-30,'+x(n-1)+','+(H-PAD+20)+')">' + label + '</text>';
    }

    const svg = '<svg viewBox="0 0 '+W+' '+(H+20)+'" style="width:100%;max-width:'+W+'px;height:auto;background:var(--card);border:1px solid var(--border);border-radius:var(--radius);padding:8px">'
        + gridLines
        + '<path d="'+fixPath+'" fill="none" stroke="var(--fix)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>'
        + '<path d="'+sizePath+'" fill="none" stroke="var(--review)" stroke-width="2.5" stroke-dasharray="6,3" stroke-linecap="round" stroke-linejoin="round"/>'
        + fixDots + sizeDots + xLabels
        + '<text x="'+PAD+'" y="16" fill="var(--fix)" font-size="12" font-weight="700">Fix files (left)</text>'
        + '<text x="'+(W-PADR)+'" y="16" text-anchor="end" fill="var(--review)" font-size="12" font-weight="700">Total size GB (right)</text>'
        + '</svg>';

    const latest = history[history.length - 1];
    const prev = history.length > 1 ? history[history.length - 2] : null;
    const fixDelta = prev ? latest.fixCount - prev.fixCount : 0;
    const sizeDelta = prev ? (latest.totalSizeGB - prev.totalSizeGB).toFixed(2) : 0;

    main.innerHTML = '<h2>&#128200; History</h2>'
    +'<p class="page-desc">Cleanup progress across '+fmt(history.length)+' scan(s). Each scan adds a data point.</p>'
    +'<div class="cards">'
    +'<div class="card accent-purple"><div class="label">Current Fix</div><div class="value" style="color:var(--fix)">'+fmt(latest.fixCount)+'</div><div class="sub">'+(prev ? (fixDelta > 0 ? '+' : '') + fmt(fixDelta) + ' vs. previous scan' : 'First scan') +'</div></div>'
    +'<div class="card accent-blue"><div class="label">Current size</div><div class="value">'+fmtGB(latest.totalSizeGB)+'</div><div class="sub">'+(prev ? (sizeDelta > 0 ? '+' : '') + sizeDelta + ' GB vs. previous' : 'First scan')+'</div></div>'
    +'<div class="card"><div class="label">Total files</div><div class="value">'+fmt(latest.totalFiles)+'</div></div>'
    +'<div class="card"><div class="label">Data points</div><div class="value">'+fmt(history.length)+'</div><div class="sub">Since '+escHtml(history[0].date)+'</div></div>'
    +'</div>'
    +'<h3>Trend</h3>'
    +'<div class="mt1" style="margin-bottom:2rem">'+svg+'</div>'
    +'<h3>All measurements</h3>'
    +'<div class="tbl-wrap"><table id="tbl-history"><thead><tr><th>Date</th><th class="r">Files</th><th class="r">Size</th><th class="r">Fix</th><th class="r">\u0394 Fix</th></tr></thead><tbody>'+tableRows+'</tbody></table></div>';

    addTableSort(document.getElementById('tbl-history'));
}

// ── INIT ──
document.getElementById('gen-date').textContent = DATA.generated;
const badges = {
    'badge-delete':  DATA.actions.Delete?.count,
    'badge-archive': DATA.actions.Archive?.count,
    'badge-fix':     DATA.actions.Fix?.count,
    'badge-link':    DATA.actions.Link?.count,
    'badge-review':  DATA.actions.Review?.count,
    'badge-migrate': DATA.actions.Migrate?.count,
    'badge-dupes':   DATA.summary.duplicateFiles,
    'badge-perms':   (DATA.permFolders||[]).length,
    'badge-history': (DATA.history||[]).length
};
for (const [id, val] of Object.entries(badges)) {
    const el = document.getElementById(id);
    if (el && val) el.textContent = val >= 1000 ? (val/1000).toFixed(1)+'k' : val;
}

navigate('overview');
'@

# ============================================================
# POST-PROCESS & SAVE
# ============================================================

# Inject JSON data into JavaScript file
$jsContent = $jsCode.Replace('%%JSON_DATA%%', $jsonData)

# report.js sits next to report.html in $reportDir
$html = $html.Replace('%%SCRIPT_SRC%%', 'report.js')

# Save files
[System.IO.File]::WriteAllText($OutputHtml, $html, [System.Text.Encoding]::UTF8)
Write-Host "  Saved: $OutputHtml ($([math]::Round($html.Length / 1KB, 0)) KB)" -ForegroundColor Cyan

[System.IO.File]::WriteAllText($OutputJs, $jsContent, [System.Text.Encoding]::UTF8)
Write-Host "  Saved: $OutputJs ($([math]::Round($jsContent.Length / 1KB, 0)) KB)" -ForegroundColor Cyan

$sw.Stop()
Write-Host ""
Write-Host "Done in $([math]::Round($sw.Elapsed.TotalSeconds,1))s" -ForegroundColor Green
if ($xlsxOk) {
    Write-Host "  1. $OutputXlsx    (annotated, $($exportItems.Count) file rows + $($folderItems.Count) folder rows)"
} else {
    Write-Host "  1. $OutputXlsx    (NOT generated this run - see warnings above; data in sourcedata.csv)"
}
Write-Host "  2. $OutputHtml    (interactive dashboard)"
Write-Host "  3. $OutputJs      (report JavaScript)"
Write-Host "  4. $OutputHistory (historical data, $($historyData.Count) data points)"
Write-Host ""

Write-Host "Open $OutputHtml in your browser to explore the report." -ForegroundColor Yellow