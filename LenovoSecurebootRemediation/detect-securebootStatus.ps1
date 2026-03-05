<#
    .SYNOPSIS
    Detects if Secure Boot is enabled on Lenovo devices via WMI.

    .DESCRIPTION
    Queries the Lenovo WMI BIOS interface (root\wmi) to determine whether Secure Boot
    is currently enabled. Falls back to the built-in Confirm-SecureBootUEFI cmdlet when
    the Lenovo WMI namespace is unavailable.

    Supports ThinkPad, ThinkCentre, ThinkStation, and IdeaPad models from 2018 onwards. 
    Handles variant BIOS setting names across generations (e.g. "SecureBoot" vs "Secure Boot").

    Designed for use as an Intune Remediation detection script paired with
    remediate-securebootStatus.ps1.

    .NOTES
    filename: detect-securebootStatus.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
    updated: 2026-02-17
    
    .NOTICE
    This script is provided "as is" without warranty of any kind. The author and Lieben Consultancy are not liable for any damage or loss resulting from its use. Always test scripts in a controlled environment before deploying widely.
#>

# ── Pre-flight: verify this is a Lenovo device ──────────────────────────────
try {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
} catch {
    Write-Output "NonCompliant - Unable to query system manufacturer: $_"
    Exit 1
}

if ($manufacturer -notmatch "Lenovo") {
    Write-Output "NonCompliant - Not a Lenovo device (manufacturer: $manufacturer)"
    Exit 1
}

# ── Check UEFI Setup Mode ───────────────────────────────────────────────────
try {
    $isInSetupMode = (Get-SecureBootUEFI -Name SetupMode -ErrorAction Stop).Bytes[0] -eq 1
} catch {
    $isInSetupMode = $false
}

if ($isInSetupMode) {
    Write-Output "NonCompliant - UEFI is in Setup Mode, cannot remediate until manually resolved"
    Exit 1
}

# ── Query Lenovo WMI for the Secure Boot setting ────────────────────────────
$secureBootValue = $null
try {
    $allSettings = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosSetting -ErrorAction Stop

    # Handle variant names: "SecureBoot" (most ThinkPads) and "Secure Boot" (some IdeaPad/ThinkCentre)
    $secureBootEntry = $allSettings | Where-Object {
        $_.CurrentSetting -match "^Secure\s?Boot,"
    } | Select-Object -First 1

    if ($secureBootEntry) {
        # CurrentSetting format is "SettingName,Value" (e.g. "SecureBoot,Enable")
        $parts = $secureBootEntry.CurrentSetting -split ","
        if ($parts.Count -ge 2) {
            $secureBootValue = $parts[1].Trim()
        }
    }
} catch {
    # Lenovo WMI not available — fall back to Confirm-SecureBootUEFI
    Write-Output "Info - Lenovo WMI unavailable ($($_.Exception.Message)), falling back to Confirm-SecureBootUEFI"
}

# ── Fallback: use built-in Confirm-SecureBootUEFI ────────────────────────────
if (-not $secureBootValue) {
    try {
        $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
        $secureBootValue = if ($secureBootEnabled) { "Enable" } else { "Disable" }
    } catch {
        Write-Output "NonCompliant - Unable to determine Secure Boot status: $_"
        Exit 1
    }
}

# ── Evaluate compliance ─────────────────────────────────────────────────────
if ($secureBootValue -eq "Enable" -or $secureBootValue -eq "Enabled") {
    Write-Output "Compliant - Secure Boot is enabled"
    Exit 0
} else {
    Write-Output "NonCompliant - Secure Boot is '$secureBootValue'"
    Exit 1
}