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

Write-Host "Enumerating all files under '$rootPathStr'..." -ForegroundColor Cyan
try {
    $files = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "_Verwijderen" }
}
catch {
    Write-Error "Failed to enumerate files: $_"
    exit 1
}

$rows = [System.Collections.Generic.List[object]]::new()
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

        $hasUniquePermissions = $null
        try {
            $acl = Get-Acl -LiteralPath $file.FullName -ErrorAction Stop
            $hasUniquePermissions = ($acl.Access | Where-Object { -not $_.IsInherited }) -ne $null
        } catch {
            $hasUniquePermissions = "Error"
        }

        $row = [PSCustomObject]@{
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
            IsLikelyTemporary         = $tempExtensions.Contains($file.Extension)
            IsLargeFile               = ($file.Length -ge 100MB)
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

$sizeGroups = $rows | Group-Object -Property SizeBytes | Where-Object { $_.Count -gt 1 }
$groupId = 0
foreach ($g in $sizeGroups) {
    $groupId++
    $id = ("S{0:D6}" -f $groupId)
    foreach ($r in $g.Group) {
        $r.DuplicateBySizeCount = $g.Count
        $r.DuplicateBySizeId = $id
    }
}

$nameSizeGroups = $rows | Group-Object { "$($_.SizeBytes)|$($_.FileName.ToLowerInvariant())" } | Where-Object { $_.Count -gt 1 }
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

$totalSizeBytes = ($rows | Measure-Object -Property SizeBytes -Sum).Sum
$totalSizeGB = [math]::Round(($totalSizeBytes / 1GB), 2)

Write-Host "Report generated successfully." -ForegroundColor Green
Write-Host "Files: $($rows.Count) | Total Size (GB): $totalSizeGB" -ForegroundColor Green