<#
    .SYNOPSIS
    This script ensures the default terminal for the current user is set to the delegation one, to ensure that PowerShell scheduled tasks respect the -WindowStyle Hidden command
    To be used in Intune Remediations together with detect-defaultTerminal.ps1

    .NOTES
    filename: remediate-defaultTerminal.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
#>
Set-ItemProperty -Path 'HKCU:\\Console\\%%Startup' -Name 'DelegationConsole' -Value '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' -Force -Confirm:$False
Set-ItemProperty -Path 'HKCU:\\Console\\%%Startup' -Name 'DelegationTerminal' -Value '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' -Force -Confirm:$False