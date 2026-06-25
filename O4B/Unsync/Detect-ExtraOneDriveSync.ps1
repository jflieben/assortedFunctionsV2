<#
    .SYNOPSIS
    Intune Remediation DETECTION script (detection-only, NOTHING is remediated).
    Author: Jos Lieben (Lieben Consultancy)
    Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)

    Detects whether the logged-on user is synchronizing SharePoint / Teams document
    libraries with the OneDrive for Business client, i.e. MORE than just their own
    personal OneDrive for Business library.

    .DESCRIPTION
    The set of libraries the OneDrive client is syncing is stored per-user in the
    registry under HKCU:\Software\SyncEngines\Providers\OneDrive\<ScopeId>. Each scope
    has:
        UrlNamespace  - the full SharePoint/OneDrive URL of the synced library
        MountPoint    - the local folder the library is synced to
        LibraryType   - 'mysite'/'personal' for the personal OneDrive for Business
                        library, 'teamsite' (etc.) for SharePoint document libraries.

    A SharePoint library can appear in the registry for two reasons, and
    we only want to flag the second one:
      1. "Add shortcut to OneDrive" - the library shows up as a shortcut INSIDE the
         user's personal OneDrive folder. Its MountPoint is a descendant of the personal
         OneDrive MountPoint, e.g.
             C:\Users\me\OneDrive - Contoso\Marketing - Documents
      2. "Sync" (the separate sync root) - the library gets its own top-level folder
         next to the OneDrive folder, e.g.
             C:\Users\me\Contoso\Marketing - Documents

    Because HKCU is per-user, this MUST run in the logged-on user's context.

    Deploy as an Intune Remediation with:
        Run this script using the logged-on credentials : Yes   (required - HKCU)
        Run script in 64-bit PowerShell                 : Yes
        Enforce script signature check                  : No (unless you sign it)

    Exit 0 = only the personal OneDrive for Business library is synced (nothing flagged)
    Exit 1 = one or more SharePoint/Teams libraries are synced (flagged)

    The flagged site URLs are written as output so Intune stores them as the
    "Pre-remediation detection output"
#>

$ErrorActionPreference = 'Stop'
$providersRoot = 'HKCU:\Software\SyncEngines\Providers\OneDrive'

# Normalise a path for prefix comparison: trim trailing separators, lower-case.
function Get-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return $Path.TrimEnd('\', '/').ToLowerInvariant()
}

try {
    if (-not (Test-Path -LiteralPath $providersRoot)) {
        Write-Output "OneDrive Business sync not configured for this user."
        exit 0
    }

    # Read every sync scope once.
    $scopes = foreach ($scope in (Get-ChildItem -LiteralPath $providersRoot -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty -LiteralPath $scope.PSPath -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($props.UrlNamespace)) { continue }
        [PSCustomObject]@{
            Url         = $props.UrlNamespace.TrimEnd('/')
            MountPoint  = "$($props.MountPoint)"
            LibraryType = "$($props.LibraryType)"
        }
    }

    # Pass 1: collect the personal OneDrive folder root(s) - shortcuts live underneath these.
    $personalRoots = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($s in $scopes) {
        $isPersonal = ($s.LibraryType -in 'mysite', 'personal') -or ($s.Url -match '(?i)-my\.sharepoint\.com/personal/')
        if ($isPersonal) {
            $n = Get-NormalizedPath $s.MountPoint
            if ($n) { [void]$personalRoots.Add($n) }
        }
    }
    # Fallback roots from the user's environment in case the personal scope is shaped oddly.
    foreach ($envRoot in @($env:OneDriveCommercial, $env:OneDrive)) {
        $n = Get-NormalizedPath $envRoot
        if ($n) { [void]$personalRoots.Add($n) }
    }

    # Pass 2: a non-personal scope is a SEPARATE sync only if its MountPoint is NOT under a personal root.
    $extra = foreach ($s in $scopes) {
        $isPersonal = ($s.LibraryType -in 'mysite', 'personal') -or ($s.Url -match '(?i)-my\.sharepoint\.com/personal/')
        if ($isPersonal) { continue }

        $mp = Get-NormalizedPath $s.MountPoint
        $isShortcut = $false
        if ($mp) {
            foreach ($root in $personalRoots) {
                if ($mp -eq $root -or $mp.StartsWith($root + '\')) { $isShortcut = $true; break }
            }
        }
        if ($isShortcut) { continue }   # "Add shortcut to OneDrive" link - not a separate sync

        $s
    }

    $extra = @($extra | Sort-Object Url -Unique)

    if ($extra.Count -eq 0) {
        Write-Output "OK: only personal OneDrive for Business is synced."
        exit 0
    }

    # Compact, Intune-friendly output. Intune only stores the first ~2KB of detection
    # output, so cap the string and append a marker if we had to truncate.
    $joined = ($extra.Url -join ' | ')
    $maxLen = 1800
    if ($joined.Length -gt $maxLen) {
        $joined = $joined.Substring(0, $maxLen) + ' ...[truncated]'
    }
    Write-Output ("EXTRASYNC ({0}): {1}" -f $extra.Count, $joined)
    exit 1
}catch {
    # Surface the error in the output but stay 'compliant' so we never trigger remediation.
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 0
}
