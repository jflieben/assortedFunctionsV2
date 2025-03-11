<#
    .SYNOPSIS
    This script detects if secureboot is enabled (ONLY on Lenovo devices later than 2018)
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
    Write-Host $_
    Write-Host "NonCompliant"
    Exit 1
}

if ($securebootSetting -eq "SecureBoot,Enable"){
    Write-Host "Compliant"
    Exit 0
} else {
    Write-Host "NonCompliant"
    Exit 1
}