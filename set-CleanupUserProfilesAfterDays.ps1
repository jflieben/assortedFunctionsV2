<#
    .SYNOPSIS
    Sets the number of days after which Windows should clean up an inactive profile.
    Deploy through Intune and target SYSTEM (this script will not work under user context)
    .NOTES
    filename: set-CleanupUserProfilesAfterDays.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 22/10/2019
#>

$maxProfileAgeInDays = 30

try{
    If(!(Test-Path "HKLM:\Software\Policies\Microsoft\Windows\System")){
        New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows" -Name "System" -Force -ErrorAction SilentlyContinue | Out-Null 
        Write-Output "System key was created"
    }
    Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows\System" -Name 'CleanupProfiles' -Value $maxProfileAgeInDays -Type 'Dword' -Force 
}catch{
    Throw "Failed to set registry key!"
}