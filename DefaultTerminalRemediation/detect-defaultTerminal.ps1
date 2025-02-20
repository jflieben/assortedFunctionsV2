<#
    .SYNOPSIS
    This script detects if the default terminal for the current user is set to the delegation one, to ensure that PowerShell scheduled tasks respect the -WindowStyle Hidden command
    To be used in Intune Remediations together with remediation-defaultTerminal.ps1

    .NOTES
    filename: detect-defaultTerminal.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
#>
$delegationConsole = Get-ItemProperty -Path 'HKCU:\\Console\\%%Startup' -Name 'DelegationConsole' -ErrorAction SilentlyContinue
$delegationTerminal = Get-ItemProperty -Path 'HKCU:\\Console\\%%Startup' -Name 'DelegationTerminal' -ErrorAction SilentlyContinue

if ($delegationConsole.DelegationConsole -eq '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' -and $delegationTerminal.DelegationTerminal -eq '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}') {
    Write-Verbose "Compliant"
    Exit 0
} else {
    Write-Verbose "NonCompliant"
    Exit 1
}