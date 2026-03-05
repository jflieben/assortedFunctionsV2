<#
    .SYNOPSIS
    Enables Secure Boot on Lenovo devices via WMI.

    .DESCRIPTION
    Uses the Lenovo WMI BIOS interface (root\wmi) to enable Secure Boot remotely.
    Supports password-protected and unprotected BIOS configurations across ThinkPad,
    ThinkCentre, ThinkStation, and IdeaPad models from 2018 onwards.

    Key capabilities:
    - Detects and adapts to the correct Secure Boot setting name per model
    - Validates WMI return codes (Lenovo methods return status strings, not exceptions)
    - Supports supervisor, system-management, and opcode password authentication
    - Rolls back uncommitted changes via Lenovo_DiscardBiosSettings on failure
    - Optionally suspends BitLocker BEFORE the BIOS change to prevent lockout
    - Verifies the setting was applied after committing
    - Supports encoding variants (ascii / utf-16) and delimiter variants (; suffix)

    Designed for use as an Intune Remediation script paired with
    detect-securebootStatus.ps1.

    .PARAMETER biosPasswords
    Array of BIOS supervisor/SMP passwords to attempt. The script stops after the
    first successful password to avoid lockout (max 2 attempts enforced).

    .PARAMETER suspendBitlocker
    When $true, suspends BitLocker on all encrypted volumes for one reboot cycle
    BEFORE writing the BIOS change. Prevents recovery-key prompts on machines
    where the TPM PCR policy seals against the Secure Boot state.

    .PARAMETER thirdPartyBios
    When $true, also enables Allow3rdPartyUEFICA (third-party UEFI Certificate
    Authority). Required for dual-boot Linux configurations.

    .NOTES
    filename: remediate-securebootStatus.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
    updated: 2026-02-17

    .NOTICE
    This script is provided "as is" without warranty of any kind. The author and Lieben Consultancy are not liable for any damage or loss resulting from its use. Always test scripts in a controlled environment before deploying widely.
#>

####BEGIN CONFIGURATION####
# Configure only if your BIOS is password protected. You may add multiple passwords
# if you use different passwords for different devices; the script tries them in order.
# !!WARNING!! Using 3 or more wrong passwords could lock you out of the BIOS!
$biosPasswords    = @() # example: $biosPasswords = @("password1","password2")
$suspendBitlocker = $false # suspend BitLocker for 1 reboot before changing BIOS
$thirdPartyBios   = $false # also enable Allow3rdPartyUEFICA for Linux dual-boot
####END CONFIGURATION####



###BEGIN SCRIPT####

# ── Helper: parse Lenovo WMI return values ──────────────────────────────────
function Test-LenovoWmiResult {
    <#
    .SYNOPSIS
    Validates the return object from a Lenovo WMI method call.
    Returns $true when the operation succeeded.
    #>
    param(
        [Parameter(Mandatory)]$Result,
        [string]$Operation = "WMI call"
    )
    # Lenovo WMI methods return an object with a .return property containing a status string.
    # Known success values: "Success", "0"
    # Known failure values: "Access Denied", "Invalid Parameter", "Not Supported", 
    #                       "System Busy", "Unknown", numeric error codes
    $returnValue = $null
    if ($null -ne $Result) {
        # CIM returns .ReturnValue; older WMI returns .return
        $returnValue = if ($null -ne $Result.return) { $Result.return } 
                       elseif ($null -ne $Result.ReturnValue) { $Result.ReturnValue }
    }
    if ($null -eq $returnValue) {
        Write-Output "Warning - $Operation returned no status"
        return $true  # assume success when no return value (some very old firmware)
    }
    $rv = "$returnValue".Trim()
    if ($rv -eq "Success" -or $rv -eq "0") {
        return $true
    }
    Write-Output "Failed  - $Operation returned: $rv"
    return $false
}

# ── Helper: attempt a BIOS setting with optional password ───────────────────
function Set-LenovoBiosSetting {
    param(
        [Parameter(Mandatory)][CimInstance]$SetBiosInstance,
        [Parameter(Mandatory)][string]$Setting,
        [string]$Value,
        [string]$Password,
        [string]$Encoding = "ascii",
        [string]$KbdLang  = "us"
    )
    if ($Password) {
        $arg = "$Setting,$Value,$Password,$Encoding,$KbdLang;"
    } else {
        $arg = "$Setting,$Value;"
    }
    # Try with semicolon first (newer firmware), then without (older firmware)
    $result = Invoke-CimMethod -InputObject $SetBiosInstance -MethodName SetBiosSetting -Arguments @{ parameter = $arg } -ErrorAction Stop
    if (-not (Test-LenovoWmiResult -Result $result -Operation "SetBiosSetting($Setting)")) {
        # Retry without trailing semicolon for older models
        $argNoSemicolon = $arg.TrimEnd(";")
        $result = Invoke-CimMethod -InputObject $SetBiosInstance -MethodName SetBiosSetting -Arguments @{ parameter = $argNoSemicolon } -ErrorAction Stop
        if (-not (Test-LenovoWmiResult -Result $result -Operation "SetBiosSetting($Setting) [no-semicolon]")) {
            return $false
        }
    }
    return $true
}

# ── Helper: save BIOS settings with optional password ───────────────────────
function Save-LenovoBiosSettings {
    param(
        [Parameter(Mandatory)][CimInstance]$SaveBiosInstance,
        [string]$Password,
        [string]$Encoding = "ascii",
        [string]$KbdLang  = "us"
    )
    if ($Password) {
        $arg = "$Password,$Encoding,$KbdLang;"
    } else {
        $arg = ""
    }
    $result = Invoke-CimMethod -InputObject $SaveBiosInstance -MethodName SaveBiosSettings -Arguments @{ parameter = $arg } -ErrorAction Stop
    if (-not (Test-LenovoWmiResult -Result $result -Operation "SaveBiosSettings")) {
        # Retry without trailing semicolon
        if ($arg) {
            $argNoSemicolon = $arg.TrimEnd(";")
            $result = Invoke-CimMethod -InputObject $SaveBiosInstance -MethodName SaveBiosSettings -Arguments @{ parameter = $argNoSemicolon } -ErrorAction Stop
            if (-not (Test-LenovoWmiResult -Result $result -Operation "SaveBiosSettings [no-semicolon]")) {
                return $false
            }
        } else {
            return $false
        }
    }
    return $true
}

# ── Helper: discard uncommitted BIOS changes ────────────────────────────────
function Undo-LenovoBiosChanges {
    try {
        $discard = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_DiscardBiosSettings -ErrorAction Stop
        $result = Invoke-CimMethod -InputObject $discard -MethodName DiscardBiosSettings -Arguments @{ parameter = "" } -ErrorAction SilentlyContinue
        Write-Output "Info    - Discarded uncommitted BIOS changes"
    } catch {
        # DiscardBiosSettings is not available on all models; safe to ignore
    }
}

# ── Pre-flight: verify this is a Lenovo device ──────────────────────────────
try {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
} catch {
    Write-Output "Failed  - Unable to query system manufacturer: $_"
    Exit 1
}
if ($manufacturer -notmatch "Lenovo") {
    Write-Output "Failed  - Not a Lenovo device (manufacturer: $manufacturer)"
    Exit 1
}

# ── Check UEFI Setup Mode ───────────────────────────────────────────────────
try {
    $isInSetupMode = (Get-SecureBootUEFI -Name SetupMode -ErrorAction Stop).Bytes[0] -eq 1
} catch {
    $isInSetupMode = $false
}
if ($isInSetupMode) {
    Write-Output "Failed  - UEFI is in Setup Mode, cannot activate Secure Boot until manually resolved"
    Exit 1
}

# ── Discover the exact Secure Boot setting name on this model ────────────────
try {
    $allSettings = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosSetting -ErrorAction Stop
} catch {
    Write-Output "Failed  - Lenovo WMI namespace not available: $_"
    Exit 1
}

# Some models use "SecureBoot", others "Secure Boot"
$secureBootEntry = $allSettings | Where-Object { $_.CurrentSetting -match "^Secure\s?Boot," } | Select-Object -First 1
if (-not $secureBootEntry) {
    Write-Output "Failed  - Could not find a Secure Boot setting in Lenovo WMI"
    Exit 1
}
$secureBootSettingName = ($secureBootEntry.CurrentSetting -split ",")[0]
$secureBootCurrentVal  = ($secureBootEntry.CurrentSetting -split ",")[1].Trim()
Write-Output "Info    - Found setting '$secureBootSettingName' = '$secureBootCurrentVal'"

if ($secureBootCurrentVal -in @("Enable", "Enabled")) {
    Write-Output "Success - Secure Boot is already enabled, no action needed"
    Exit 0
}

# ── Determine password protection state ──────────────────────────────────────
# PasswordState bitmask: bit 0 = POP, bit 1 = SVP (supervisor), bit 2 = SMP
# We need SVP or SMP to be set if the BIOS enforces password-protected changes.
$supervisorPwdSet = $false
$smpPwdSet        = $false
try {
    $pwdState = (Get-CimInstance -ClassName Lenovo_BiosPasswordSettings -Namespace root\wmi -ErrorAction Stop).PasswordState
    $supervisorPwdSet = ($pwdState -band 2) -eq 2  # bit 1 = Supervisor
    $smpPwdSet        = ($pwdState -band 4) -eq 4  # bit 2 = System Management Password
    Write-Output "Info    - PasswordState = $pwdState (SVP=$supervisorPwdSet, SMP=$smpPwdSet)"
} catch {
    Write-Output "Info    - Could not query PasswordState, assuming no password: $_"
}

$passwordRequired = $supervisorPwdSet -or $smpPwdSet

# ── Acquire WMI interface instances ──────────────────────────────────────────
try {
    $setBios    = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SetBiosSetting   -ErrorAction Stop
    $commitBios = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SaveBiosSettings -ErrorAction Stop
} catch {
    Write-Output "Failed  - Cannot acquire Lenovo WMI set/save interfaces: $_"
    Exit 1
}

# ── Suspend BitLocker BEFORE touching the BIOS ──────────────────────────────
if ($suspendBitlocker) {
    try {
        $blVolumes = Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.ProtectionStatus -eq "On" }
        foreach ($vol in $blVolumes) {
            Suspend-BitLocker -MountPoint $vol.MountPoint -RebootCount 1 -ErrorAction Stop
            Write-Output "Info    - Suspended BitLocker on $($vol.MountPoint)"
        }
    } catch {
        Write-Output "Failed  - Could not suspend BitLocker: $_"
        Exit 1
    }
}

# ── Apply the BIOS change ───────────────────────────────────────────────────
$changeApplied = $false

if (-not $passwordRequired) {
    # ── No password required ─────────────────────────────────────────────────
    if ($biosPasswords.Count -gt 0) {
        Write-Output "Info    - BIOS has no password set; ignoring configured passwords"
    }
    try {
        $ok = Set-LenovoBiosSetting -SetBiosInstance $setBios -Setting $secureBootSettingName -Value "Enable"
        if (-not $ok) { throw "SetBiosSetting returned failure" }

        if ($thirdPartyBios) {
            $ok3p = Set-LenovoBiosSetting -SetBiosInstance $setBios -Setting "Allow3rdPartyUEFICA" -Value "Enable"
            if (-not $ok3p) { Write-Output "Warning - Could not enable Allow3rdPartyUEFICA" }
        }

        $okSave = Save-LenovoBiosSettings -SaveBiosInstance $commitBios
        if (-not $okSave) { throw "SaveBiosSettings returned failure" }

        $changeApplied = $true
        Write-Output "Success - Secure Boot enabled without BIOS password"
    } catch {
        Undo-LenovoBiosChanges
        Write-Output "Failed  - Could not enable Secure Boot without password: $_"
        Exit 1
    }
} else {
    # ── Password required ────────────────────────────────────────────────────
    if ($biosPasswords.Count -eq 0) {
        Write-Output "Failed  - BIOS is password protected but no passwords configured"
        Exit 1
    }

    # Acquire opcode interface for ThinkCentre/ThinkStation desktops
    $opcodeInterface = $null
    try {
        $opcodeInterface = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_WmiOpcodeInterface -ErrorAction Stop
    } catch {
        # Not available on ThinkPads — expected and harmless
    }

    $attempt = 0
    foreach ($biosPassword in $biosPasswords) {
        $attempt++
        if ($attempt -gt 2) {
            Write-Output "Failed  - Stopping after $($attempt - 1) password attempts to avoid BIOS lockout"
            Exit 1
        }

        # Try both ascii and utf-16 encodings (some newer models require utf-16)
        $encodings = @("ascii", "utf-16")
        $passwordSucceeded = $false

        foreach ($encoding in $encodings) {
            try {
                $ok = Set-LenovoBiosSetting -SetBiosInstance $setBios `
                    -Setting $secureBootSettingName -Value "Enable" `
                    -Password $biosPassword -Encoding $encoding
                if (-not $ok) { continue }

                # Desktop opcode authentication (ThinkCentre/ThinkStation)
                if ($opcodeInterface) {
                    try {
                        Invoke-CimMethod -InputObject $opcodeInterface -MethodName WmiOpcodeInterface `
                            -Arguments @{ parameter = "WmiOpcodePasswordAdmin:$biosPassword" } -ErrorAction SilentlyContinue | Out-Null
                    } catch { }
                }

                if ($thirdPartyBios) {
                    $ok3p = Set-LenovoBiosSetting -SetBiosInstance $setBios `
                        -Setting "Allow3rdPartyUEFICA" -Value "Enable" `
                        -Password $biosPassword -Encoding $encoding
                    if (-not $ok3p) { Write-Output "Warning - Could not enable Allow3rdPartyUEFICA" }
                }

                $okSave = Save-LenovoBiosSettings -SaveBiosInstance $commitBios `
                    -Password $biosPassword -Encoding $encoding
                if (-not $okSave) {
                    Undo-LenovoBiosChanges
                    continue
                }

                $passwordSucceeded = $true
                $changeApplied = $true
                Write-Output "Success - Secure Boot enabled with BIOS password (encoding=$encoding, attempt=$attempt)"
                break
            } catch {
                Undo-LenovoBiosChanges
                Write-Output "Info    - Attempt $attempt ($encoding) failed: $_"
            }
        }
        if ($passwordSucceeded) { break }
    }

    if (-not $changeApplied) {
        Write-Output "Failed  - None of the configured BIOS passwords worked"
        Exit 1
    }
}

# ── Post-change verification ────────────────────────────────────────────────
try {
    $verifySettings = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosSetting -ErrorAction Stop
    $verifyEntry = $verifySettings | Where-Object { $_.CurrentSetting -match "^Secure\s?Boot," } | Select-Object -First 1
    if ($verifyEntry) {
        $verifyVal = ($verifyEntry.CurrentSetting -split ",")[1].Trim()
        if ($verifyVal -in @("Enable", "Enabled")) {
            Write-Output "Verified- Secure Boot setting confirmed as '$verifyVal'"
        } else {
            Write-Output "Warning - Secure Boot reads as '$verifyVal' after change; may require reboot to take effect"
        }
    }
} catch {
    Write-Output "Warning - Could not verify Secure Boot setting after change"
}

Exit 0