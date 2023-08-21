#Author: Jos Lieben
#Original idea: Jan Van Meirvenne
#Additional credit: Pieter Wigleven
#Date: 03-01-2020
#Script home: http://www.lieben.nu
#Copyright: MIT
#Purpose: ensure Bitlocker is running on Windows 10 Azure AD Joined machines, and key is written to AzureAD and Onedrive
#Requires –Version 5
#Name: Enable-BitlockerAndEscrowKeyToAAD.ps1

$logFile = Join-Path $Env:Temp -ChildPath "enable-Bitlocker.log"
$tenant = "tenantname.onmicrosoft.com"
$ErrorActionPreference = "stop"
$version = "0.02"
$scriptName = "enableBitlocker"
$scriptPath = $MyInvocation.MyCommand.Definition

ac $logFile "$(Get-Date): $scriptName $version  starting on $($Env:computername)"

try{
    $createTask = "schtasks /Create /SC ONLOGON /TN EnableBitlocker /IT /RL HIGHEST /F /TR `"Powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy ByPass -File '$scriptPath'`""    
    ac $logFile "Scheduled EnableBitlocker task to run at logon and call $scriptPath"
}catch{
    ac $logFile "Failed to schedule task! $_"
}

ac $logFile "Current sysvol status: $((Get-BitLockerVolume $env:SystemDrive -ErrorAction Stop).VolumeStatus)"

while ((Get-BitLockerVolume $env:SystemDrive -ErrorAction Stop).VolumeStatus -eq "FullyDecrypted"){
    ac $logFile "$($env:SystemDrive) system volume not yet encrypted, ejecting media and attempting to encrypt"
    try{
        # Automatically unmount any iso/dvd's
        $Diskmaster = New-Object -ComObject IMAPI2.MsftDiscMaster2 
        $DiskRecorder = New-Object -ComObject IMAPI2.MsftDiscRecorder2 
        $DiskRecorder.InitializeDiscRecorder($DiskMaster) 
        $DiskRecorder.EjectMedia() 
    }catch{
        ac $logFile "Failed to unmount DVD $_"
    }

    try{
        # Automatically unmount any USB sticks
        $volumes = get-wmiobject -Class Win32_Volume | Where-Object {$_.drivetype -eq '2'}  
        foreach($volume in $volumes){
            $ejectCmd = New-Object -comObject Shell.Application
            $ejectCmd.NameSpace(17).ParseName($volume.driveletter).InvokeVerb("Eject")
        }
    }catch{
        ac $logFile "Failed to unmount USB device $_"
    }

    try{
        #Enable bitlocker with a normal password protector
        Enable-BitLocker -MountPoint $env:SystemDrive -UsedSpaceOnly -RecoveryPasswordProtector -ErrorAction Stop -SkipHardwareTest -Confirm:$False
        ac $logFile "Bitlocker recovery password set"
    }catch{
        ac $logFile "Error while setting up AAD Bitlocker password: $_"
    } 

    try{
        # Enable Bitlocker using TPM
        Enable-BitLocker -MountPoint $env:SystemDrive -UsedSpaceOnly -TpmProtector -ErrorAction Stop -SkipHardwareTest -Confirm:$False
        ac $logFile "Bitlocker enabled using TPM"
    }catch{
        ac $logFile "Failed to enable Bitlocker using TPM: $_"
    }
}

ac $logFile "Will attempt to update your recovery key in AAD"
try{
    $cert = dir Cert:\LocalMachine\My\ | Where-Object { $_.Issuer -match "CN=MS-Organization-Access" }
    $id = $cert.Subject.Replace("CN=","")
    ac $logFile "using certificate $id"
    try{
        # Set TLS v1.2
        $res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        ac $logFile "TLS set to v1.2"
    }catch{
        ac $logFile "could not set TLS to v1.2"
    }
    (Get-BitLockerVolume -MountPoint $env:SystemDrive).KeyProtector | ForEach-Object {$_.KeyProtectorType -eq 'RecoveryPassword'} | ForEach-Object {
        $key = $_
        ac $logFile "kid : $($key.KeyProtectorId) key: $($key.RecoveryPassword)"
        $body = "{""key"":""$($key.RecoveryPassword)"",""kid"":""$($key.KeyProtectorId.replace('{','').Replace('}',''))"",""vol"":""OSV""}"
        $url = "https://enterpriseregistration.windows.net/manage/$tenant/device/$($id)?api-version=1.0"
        $req = Invoke-WebRequest -Uri $url -Body $body -UseBasicParsing -Method Post -UseDefaultCredentials -Certificate $cert
        ac $logFile "Key updated in AAD"
    }
} catch {
    ac $logFile "Failed to update key in AAD: $_"
    Throw "Failed to update key in AAD: $_"
}
