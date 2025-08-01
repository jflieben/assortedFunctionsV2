<#
    .SYNOPSIS
    This script detects if secureboot is enabled (ONLY on Lenovo devices later than 2018)
    Tested on multiple ThinkPad models between 2018 and 2025
    To be used in Intune Remediations together with remediate-securebootStatus.ps1

    .NOTES
    filename: detect-securebootStatus.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
#>

try{
    $securebootSetting = ((gwmi -class Lenovo_BiosSetting -namespace root\wmi) | Where{$_.CurrentSetting.StartsWith("SecureBoot")}).CurrentSetting
}catch{
    Write-Output "NonCompliant - Unable to Read Bios"
    Exit 1
}

try{
    $isInSetupMode = (Get-SecureBootUEFI -Name SetupMode).Bytes[0] -eq 1
}catch{
    $isInSetupMode = $false
}

if($isInSetupMode){
    Write-Output "NonCompliant - Cannot remediate SetupMode"
    Exit 1
}

if ($securebootSetting -eq "SecureBoot,Enable"){
    Write-Host "Compliant"
    Exit 0
} else {
    Write-Host "NonCompliant"
    Exit 1
}