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

####BEGIN CONFIGURATION####
#configure only if your bios is password protected, you may add multiple passwords if you use different passwords for different devices, the script will try them all
#!!WARNING!! using 3 or more 'bad' passwords could lock you out of the bios, use at your own risk!
$biosPasswords = @() #example: $biosPasswords = @("password1","password2")
$suspendBitlocker = $false #set to $true if your implementation of bitlocker requires suspend before enabling secureboot to avoid bugging users with locked machines until they unlock. This is normally not needed! (Tested on multiple Lenovo devices)
$thirdPartyBios = $False #set to $true if you want to use third party config (e.g. when using Linux), only works if your bios is password protected
####END CONFIGURATION####



###BEGIN SCRIPT####
try{
    $isInSetupMode = (Get-SecureBootUEFI -Name SetupMode).Bytes[0] -eq 1
}catch{
    $isInSetupMode = $false
}

if($isInSetupMode){
    Write-Output "Bios is in Setup Mode, cannot activate secureboot until this is manually resolved"
    Exit 1
}

try{
    $supervisorPwdSet = (Get-WmiObject -Class Lenovo_BiosPasswordSettings -Namespace root\wmi).PasswordState -notin @(0,4)
}catch{
    $supervisorPwdSet = $false
}

$setBios = (gwmi -class Lenovo_SetBiosSetting -namespace root\wmi)
$commitBios = (gwmi -class Lenovo_SaveBiosSettings -namespace root\wmi)
if(!$biosPasswords -or !$supervisorPwdSet){
    if($supervisorPwdSet){
        Write-Output "Bios is password protected, but no passwords configured, cannot enable secureboot"
        Exit 1
    }
    try{
        $setBios.SetBiosSetting("SecureBoot,Enable")
        $commitBios.SaveBiosSettings()
        Write-Output "Secureboot enabled without bios password"
    }catch{
        Write-Output $_.Exception.Message
        Exit 1
    }
}else{
    $passwordWorked = $false
    try{$opcodeInterface = (gwmi -class Lenovo_WmiOpcodeInterface -namespace root\wmi)}catch{}
    $count =  0
    foreach($biosPassword in $biosPasswords){
        $count++
        if($count -gt 2){
            Write-Output "Tried $count passwords, none worked, cannot enable secureboot and will not continue to avoid locking the device"
            Exit 1
        }
        try{
            $setBios.SetBiosSetting("SecureBoot,Enable,$biosPassword,ascii,us,$biosPassword")
            try{
                $opcodeInterface.WmiOpcodeInterface("WmiOpcodePasswordAdmin:$biosPassword")
            }catch{}
            if($thirdPartyBios){
                $setBios.SetBiosSetting("Allow3rdPartyUEFICA,Enable")
            }
            $commitBios.SaveBiosSettings("$biosPassword,ascii,us")
            $passwordWorked = $true
            Write-Output "Secureboot enabled with bios password"
            break
        }catch{}   
    }
    if($passwordWorked -eq $false){
        Write-Output "None of the configured bios passwords worked, cannot enable secureboot"
        Exit 1
    }
}


if($suspendBitlocker){
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