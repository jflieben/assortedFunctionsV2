<#
    Produces a CSV inventory of ALL files under a given UNC path, with metadata useful for cleanup analysis before migration.
#>

param (
    [Parameter(Mandatory = $true, HelpMessage = "The root UNC path to scan (e.g. \\server\share\folder)")]
    [string]$Path,

    [Parameter(Mandatory = $true, HelpMessage = "Full path to the output CSV file")]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Error "Path '$Path' does not exist or is not a directory."
    exit 1
}

if ([System.IO.Path]::GetExtension($OutputPath) -ne ".csv") {
    Write-Warning "OutputPath does not end with .csv. Continuing anyway."
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$rootItem = Get-Item -LiteralPath $Path
$rootPathStr = $rootItem.FullName.TrimEnd('\')
$nowUtc = (Get-Date).ToUniversalTime()

$tempExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@('.tmp', '.temp', '.bak', '.old', '.log', '.dmp', '.cache', '.chk', '.etl') | ForEach-Object { [void]$tempExtensions.Add($_) }

# ── Macro detection setup ──
# Extensions that CAN contain macros (OOXML macro-enabled + legacy OLE formats)
$macroCapableExts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
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
$externalRegex = ($externalPatterns -join '|')

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
            try {
                # Read file bytes and look for actual VBA project stream markers
                $fileBytes = [System.IO.File]::ReadAllBytes($File.FullName)
                $fileStr = [System.Text.Encoding]::ASCII.GetString($fileBytes)

                # Look for definitive VBA project markers (not just metadata)
                # _VBA_PROJECT_CUR is the OLE stream name for VBA projects
                # 'Attribute VB_Name' is the VBA module header
                # 'ThisWorkbook' + 'VBProject' together indicate VBA presence
                if ($fileStr -match '_VBA_PROJECT|Attribute VB_Name|Attribute VB_Base|Attribute VB_GlobalNameSpace|VBAProject|\x00VBA\x00') {
                    $result.HasMacros = $true
                    $vbaBytes = $fileBytes
                } else {
                    return $result
                }
            } catch {
                $result.MacroDetails = "Could not read file: $($_.Exception.Message)"
                return $result
            }
        }
        else {
            return $result
        }

        # --- Classify macro content ---
        if ($result.HasMacros -and $vbaBytes) {
            # Extract only printable string runs (min 8 chars) from binary to avoid
            # matching random binary data as external references
            $printableRuns = [System.Collections.Generic.List[string]]::new()
            $asciiStr = [System.Text.Encoding]::ASCII.GetString($vbaBytes)
            $runMatches = [regex]::Matches($asciiStr, '[\x20-\x7E]{8,}')
            foreach ($rm in $runMatches) { $printableRuns.Add($rm.Value) }
            # Also extract UTF-16LE printable runs (VBA stores some strings as UTF-16)
            $utf16Str = [System.Text.Encoding]::Unicode.GetString($vbaBytes)
            $runMatchesUtf16 = [regex]::Matches($utf16Str, '[\x20-\x7E]{8,}')
            foreach ($rm in $runMatchesUtf16) { $printableRuns.Add($rm.Value) }
            $combinedText = $printableRuns -join "`n"

            # Check for external access patterns
            $externalMatches = [System.Collections.Generic.List[string]]::new()
            foreach ($pattern in $externalPatterns) {
                $matches = [regex]::Matches($combinedText, $pattern)
                foreach ($m in $matches) {
                    $matchVal = $m.Value.Trim()
                    if ($matchVal -and -not $externalMatches.Contains($matchVal)) {
                        $externalMatches.Add($matchVal)
                    }
                }
            }

            if ($externalMatches.Count -gt 0) {
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
        elseif ($result.HasMacros) {
            $result.MacroType = 'Internal'
            $result.MacroDetails = 'VBA project present but could not extract content'
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

Write-Host "Enumerating all files and folders under '$rootPathStr'..." -ForegroundColor Cyan
try {
    $allItems = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "_Verwijderen" }
    $files = $allItems | Where-Object { -not $_.PSIsContainer }
    $folders = $allItems | Where-Object { $_.PSIsContainer }
}
catch {
    Write-Error "Failed to enumerate items: $_"
    exit 1
}

$rows = [System.Collections.Generic.List[object]]::new()

# ── Process folders first (inheritance is usually broken at folder level) ──
Write-Host "Checking folder permissions ($($folders.Count) folders)..." -ForegroundColor Cyan
$folderCount = 0
$folderTotal = $folders.Count

foreach ($folder in $folders) {
    $folderCount++
    $percent = if ($folderTotal -gt 0) { [math]::Round(($folderCount / $folderTotal) * 100) } else { 100 }
    Write-Progress -Activity "Checking folder permissions" -Status "Processing: $($folder.Name)" -PercentComplete $percent

    try {
        $relativePath = [System.IO.Path]::GetRelativePath($rootPathStr, $folder.FullName)
        $parentRelativePath = [System.IO.Path]::GetRelativePath($rootPathStr, $folder.Parent.FullName)
        if ($parentRelativePath -eq ".") { $parentRelativePath = "\" }

        $hasUniquePermissions = $False
        $dfGroups = ''
        try {
            $acl = Get-Acl -LiteralPath $folder.FullName -ErrorAction Stop
            $nonInherited = $acl.Access | Where-Object { -not $_.IsInherited }
            if ($nonInherited) {
                $dfEntries = $nonInherited | Where-Object { $_.IdentityReference.Value -like 'NMLAN\DF*' }
                if ($dfEntries) {
                    Write-Host "[Folder] $relativePath has unique permissions" -ForegroundColor Yellow
                    $dfGroups = ($dfEntries | ForEach-Object { "$($_.IdentityReference.Value):$($_.FileSystemRights.ToString())" } | Sort-Object -Unique) -join '; '
                    $hasUniquePermissions = $True
                }
            }
        } catch {
            $hasUniquePermissions = "Error"
        }

        # Only include folders that have unique permissions (broken inheritance)
        if ($hasUniquePermissions -eq $True -or $hasUniquePermissions -eq "Error") {
            $ageDays = [int][math]::Floor(($nowUtc - $folder.LastWriteTimeUtc).TotalDays)
            $ageBucket = if ($ageDays -le 30) { "0-30d" }
                elseif ($ageDays -le 90) { "30-90d" }
                elseif ($ageDays -le 365) { "90-365d" }
                elseif ($ageDays -le 1095) { "1-3y" }
                elseif ($ageDays -le 1825) { "3-5y" }
                elseif ($ageDays -le 2555) { "5-7y" }
                elseif ($ageDays -le 3650) { "7-10y" }
                else { "10y+" }

            $row = [PSCustomObject]@{
                ItemType                  = "Folder"
                FileName                  = $folder.Name
                Extension                 = ""
                RelativePath              = $relativePath
                ParentRelativePath        = $parentRelativePath
                FullPath                  = $folder.FullName
                SizeBytes                 = 0
                SizeMB                    = 0
                CreatedUtc                = $folder.CreationTimeUtc
                LastWriteUtc              = $folder.LastWriteTimeUtc
                LastAccessUtc             = $folder.LastAccessTimeUtc
                AgeDays                   = $ageDays
                AgeBucket                 = $ageBucket
                IsReadOnly                = $false
                IsHidden                  = (($folder.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
                UniquePermissions         = $hasUniquePermissions
                DFGroupACLs               = $dfGroups
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

            $rows.Add($row)
        }
    }
    catch {
        Write-Warning "Skipped folder '$($folder.FullName)' due to error: $_"
    }
}

Write-Progress -Activity "Checking folder permissions" -Completed
Write-Host "Found $($rows.Count) folders with unique permissions." -ForegroundColor Cyan

# ── Process files ──
Write-Host "Processing files ($($files.Count) files)..." -ForegroundColor Cyan
$total = $files.Count
$count = 0

foreach ($file in $files) {
    $count++
    $percent = if ($total -gt 0) { [math]::Round(($count / $total) * 100) } else { 100 }
    Write-Progress -Activity "Collecting file metadata" -Status "Processing: $($file.Name)" -PercentComplete $percent

    try {
        $relativePath = [System.IO.Path]::GetRelativePath($rootPathStr, $file.FullName)
        $parentRelativePath = [System.IO.Path]::GetRelativePath($rootPathStr, $file.DirectoryName)
        if ($parentRelativePath -eq ".") { $parentRelativePath = "\" }

        $ageDays = [int][math]::Floor(($nowUtc - $file.LastWriteTimeUtc).TotalDays)
        $ageBucket = if ($ageDays -le 30) { "0-30d" }
            elseif ($ageDays -le 90) { "30-90d" }
            elseif ($ageDays -le 365) { "90-365d" }
            elseif ($ageDays -le 1095) { "1-3y" }
            elseif ($ageDays -le 1825) { "3-5y" }
            elseif ($ageDays -le 2555) { "5-7y" }
            elseif ($ageDays -le 3650) { "7-10y" }
            else { "10y+" }

        $isReadOnly = (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
        $isHidden = (($file.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)

        $hasUniquePermissions = $False
        $dfGroups = ''
        try {
            $acl = Get-Acl -LiteralPath $file.FullName -ErrorAction Stop
            $nonInherited = $acl.Access | Where-Object { -not $_.IsInherited }
            if ($nonInherited) {
                Write-Host "$relativePath has unique permissions 1" -ForegroundColor Yellow
                $dfEntries = $nonInherited | Where-Object { $_.IdentityReference.Value -like 'NMLAN\DF*' }
                if ($dfEntries) {
                    Write-Host "$relativePath has unique permissions 2" -ForegroundColor Yellow
                    $dfGroups = ($dfEntries | ForEach-Object { "$($_.IdentityReference.Value):$($_.FileSystemRights.ToString())" } | Sort-Object -Unique) -join '; '
                    $hasUniquePermissions = $True
                }
            }
        } catch {
            $hasUniquePermissions = "Error"
        }

        if($dfGroups){
            Write-Host "$relativePath has unique permissions 3" -ForegroundColor Yellow
        }

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

        $row = [PSCustomObject]@{
            ItemType                  = "File"
            FileName                  = $file.Name
            Extension                 = $file.Extension
            RelativePath              = $relativePath
            ParentRelativePath        = $parentRelativePath
            FullPath                  = $file.FullName
            SizeBytes                 = [int64]$file.Length
            SizeMB                    = [math]::Round(($file.Length / 1MB), 3)
            CreatedUtc                = $file.CreationTimeUtc
            LastWriteUtc              = $file.LastWriteTimeUtc
            LastAccessUtc             = $file.LastAccessTimeUtc
            AgeDays                   = $ageDays
            AgeBucket                 = $ageBucket
            IsReadOnly                = $isReadOnly
            IsHidden                  = $isHidden
            UniquePermissions         = $hasUniquePermissions
            DFGroupACLs               = $dfGroups
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

        $rows.Add($row)
    }
    catch {
        Write-Warning "Skipped file '$($file.FullName)' due to error: $_"
    }
}

Write-Progress -Activity "Collecting file metadata" -Completed

Write-Host "Analyzing duplicate candidates..." -ForegroundColor Cyan

$fileRows = $rows | Where-Object { $_.ItemType -eq "File" }
$sizeGroups = $fileRows | Group-Object -Property SizeBytes | Where-Object { $_.Count -gt 1 }
$groupId = 0
foreach ($g in $sizeGroups) {
    $groupId++
    $id = ("S{0:D6}" -f $groupId)
    foreach ($r in $g.Group) {
        $r.DuplicateBySizeCount = $g.Count
        $r.DuplicateBySizeId = $id
    }
}

$nameSizeGroups = $fileRows | Group-Object { "$($_.SizeBytes)|$($_.FileName.ToLowerInvariant())" } | Where-Object { $_.Count -gt 1 }
$groupId = 0
foreach ($g in $nameSizeGroups) {
    $groupId++
    $id = ("N{0:D6}" -f $groupId)
    foreach ($r in $g.Group) {
        $r.DuplicateByNameSizeCount = $g.Count
        $r.DuplicateByNameSizeId = $id
    }
}

Write-Host "Exporting $($rows.Count) file rows to '$OutputPath'..." -ForegroundColor Cyan
$rows |
    Sort-Object -Property `
        @{ Expression = "DuplicateByNameSizeCount"; Descending = $true }, `
        @{ Expression = "DuplicateBySizeCount"; Descending = $true }, `
        @{ Expression = "AgeDays"; Descending = $true }, `
        @{ Expression = "SizeBytes"; Descending = $true } |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$folderRows = $rows | Where-Object { $_.ItemType -eq "Folder" }
$totalSizeBytes = ($fileRows | Measure-Object -Property SizeBytes -Sum).Sum
$totalSizeGB = [math]::Round(($totalSizeBytes / 1GB), 2)
$macroFiles = @($fileRows | Where-Object { $_.HasMacros -eq $true })
$macroExternal = @($macroFiles | Where-Object { $_.MacroType -eq 'External' })
$macroInternal = @($macroFiles | Where-Object { $_.MacroType -eq 'Internal' })

Write-Host "Report generated successfully." -ForegroundColor Green
Write-Host "Files: $($fileRows.Count) | Folders with unique permissions: $($folderRows.Count) | Total Size (GB): $totalSizeGB" -ForegroundColor Green
Write-Host "Macros: $($macroFiles.Count) total ($($macroExternal.Count) external, $($macroInternal.Count) internal)" -ForegroundColor Yellow