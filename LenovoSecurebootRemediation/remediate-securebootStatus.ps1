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

#configure only if your bios is password protected, you may add multiple passwords if you use different passwords for different devices, the script will try them all
#       !!WARNING!! using 3 or more 'bad' passwords could lock you out of the bios, use at your own risk!
#       example config:
#       $biosPasswords = @("password1","password2")
$biosPasswords = @() 

#set to $true if your implementation of bitlocker requires suspend before enabling secureboot to avoid bugging users with locked machines until they unlock. This is normally not needed! (Tested on multiple Lenovo devices)
$suspendBitlocker = $false

$setBios = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi)
$commitBios = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi)

if(!$biosPasswords){
    Write-Host "Enabling secureboot without bios password"
    try{
        $setBios.SetBiosSetting("SecureBoot,Enable")
        $commitBios.SaveBiosSettings()
    }catch{
        Write-Error $_ -ErrorAction Continue
        Exit 1
    }
}else{
    $passwordWorked = $false
    if($biosPasswords.Count -gt 2){
        Write-Host "WARNING: Using 3 or more passwords could lock you out of the bios, use at your own risk!"
    }
    foreach($biosPassword in $biosPasswords){
        try{
            Write-Host "Enabling secureboot using bios password"
            $setBios.SetBiosSetting("SecureBoot,Enable,$biosPassword,ascii,us,$biosPassword")
            $commitBios.SaveBiosSettings("$biosPassword,ascii,us")
            $passwordWorked = $true
            break
        }catch{
            Write-Host "Bios password <redacted> did not work, trying next password $($_.Exception.Message)"
        }   
    }
    if($passwordWorked -eq $false){
        Write-Error "None of the configured bios passwords worked, aborting" -ErrorAction Continue
        Exit 1
    }
}

Write-Host "Secureboot enabled"

if($suspendBitlocker){
    Write-Host "Suspending bitlocker"
    try{
        Get-BitLockerVolume | Where-Object {$_.MountPoint -ne $Null} | Foreach-Object {
            Suspend-BitLocker -MountPoint $_.MountPoint -RebootCount 1
        }
    }catch{
        Write-Error $_ -ErrorAction Continue
        Exit 1
    }
}
Exit 0