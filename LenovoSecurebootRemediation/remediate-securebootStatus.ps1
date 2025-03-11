<#
    .SYNOPSIS
    This script ensures secureboot is enabled (ONLY on Lenovo devices later than 2018)
    To be used in Intune Remediations together with detect-securebootStatus.ps1

    .NOTES
    filename: remediate-securebootStatus.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
#>

$biosPassword = $Null #configure only if your bios is password protected

$setBios = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi)
$commitBios = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi)

if($Null -ne $biosPassword){
    Write-Host "Enabling secureboot using bios password"
    $setBios.SetBiosSetting("SecureBoot,Enable,$biosPassword,ascii,us,$biosPassword")
    $commitBios.SaveBiosSettings("$biosPassword,ascii,us")
}else{
    Write-Host "Enabling secureboot without bios password"
    $setBios.SetBiosSetting("SecureBoot,Enable")
    $commitBios.SaveBiosSettings()
}