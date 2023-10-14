#Module name:       convert-FsLogixProfileToLocalProfile.ps1
#Author:            Jos Lieben
#Author Blog:       https://www.lieben.nu
#Created:           30-11-2021
#Updated:           see Git
#Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
#Purpose:           Convert a user profile on a given FSLogix share to a local profile on the device and prevent FSLogix from using the remote profile on that device going forward
#Requirements:      Run on user's AVD. User should NOT be logged in anywhere (or profile won't be mountable). AVD should be domain joined
#How to use:        Run as admin on the user's VM, or run using Run Command (make sure the user's computer account has sufficient permissions on the share in this case)

$user = "samaccountname of user" #e.g. jflieben
$FlipFlopProfileDirectoryName = $True #set to $True if the share has SAMACCOUNT_SID format, otherwise set to $False. See https://docs.microsoft.com/en-us/fslogix/profile-container-configuration-reference#flipflopprofiledirectoryname
$filesharePath = "\\accountname.file.core.windows.net\user-profiles"
$userName = "AZURE\accountname" #use AZURE\StorageAccountName when mapping an Azure File Share. Use UPN for other share types
$password = "StorageAccountKey" #https://docs.microsoft.com/en-us/azure/storage/common/storage-account-keys-manage?tabs=azure-portal#view-account-access-keys
$domainNetbiosName = "EMEA"
$createBackupOfProfile = $True
$resetOnedrive = $False

try{
    Write-Output "Mounting profile share"
    $LASTEXITCODE = 0 
    $out = NET USE $filesharePath /USER:$($userName) $($password) /PERSISTENT:YES 2>&1
    if($LASTEXITCODE -ne 0){
        Throw "Failed to mount share because of $out"
    }
    Write-Output "Mounted $filesharePath succesfully"
}catch{
    Write-Output $_
    Exit 1
}    

try{
    Write-Output "Detecting profile path for $user"
    if($FlipFlopProfileDirectoryName){
        $profileRemotePath = (Get-ChildItem $filesharePath | where{$_.Name.StartsWith($user)}).FullName
    }else{
        $profileRemotePath = (Get-ChildItem $filesharePath | where{$_.Name.EndsWith($user)}).FullName
    }
    Write-Output "Checking for VHD(X) in $profileRemotePath"
    $profileRemotePath = (Get-ChildItem $profileRemotePath | where{$_.Name.StartsWith("Profile") -and ($_.Name.EndsWith(".vhd","CurrentCultureIgnoreCase") -or $_.Name.EndsWith(".vhdx","CurrentCultureIgnoreCase"))}).FullName
    if(!(Test-Path $profileRemotePath)){
        Throw "Failed to find a profile directory for $user in $filesharePath"
    }
    Write-Output "profile path $profileRemotePath detected"
    $Extension = $profileRemotePath.Split(".")[-1]
}catch{
    Write-Output $_
    Exit 1
}

if($profileRemotePath.Count -gt 1){
    Write-Output "Multiple profile containers found for $user, please remove old ones first"
    Exit 1
}

if($createBackupOfProfile){
    Copy-Item $profileRemotePath $profileRemotePath.Replace($Extension,"bck")
}

try{
    Write-Output "Mounting profile disk of $user"
    $profileMountResult = Mount-DiskImage -ImagePath $profileRemotePath -StorageType $Extension -Access ReadWrite
    Start-Sleep -Seconds 20
    $vol = Get-CimInstance -ClassName Win32_Volume | Where{$_.Label -and $_.Label.StartsWith("Profile")}
    if(!$vol.DriveLetter){
        $vol | Set-CimInstance -Property @{DriveLetter = "G:"}
        $driveLetter = "G:"
    }else{
        $driveLetter = $vol.DriveLetter
    }
    $profileSourcePath = Join-Path $driveLetter -ChildPath "Profile"
    if(!(Test-Path $profileSourcePath)){
        Throw "Could not access $profileSourcePath after mounting the profile disk"
    }
}catch{
    Write-Output $_
    Exit 1
}

try{
    Write-Output "Preparing regkeys"
    $profileTargetPath = Join-Path "c:\users\" -ChildPath $user
    $profileRegDataFilePath = Join-Path $Env:TEMP -ChildPath "profile.reg"
    if($FlipFlopProfileDirectoryName){
        $SID = $profileRemotePath.Split('\')[-2].Split("_")[1]
    }else{
        $SID = $profileRemotePath.Split('\')[-2].Split("_")[0]
    }
    ([string]$SID).ToCharArray() | % { $sidToHex += ("{0:x} " -f [int]$_) } 
	
"Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SID]
`"ProfileImagePath`"=`"$($profileTargetPath.Replace('\','\\'))`"
`"Guid`"=`"{$([guid]::New(([adsisearcher]"SamAccountName=$user").FindOne().Properties.objectguid[0]).Guid)}`"
`"Flags`"=dword:00000000
`"FullProfile`"=dword:00000001
`"Sid`"=hex:$($sidToHex.replace(" ",",").TrimEnd(','))
`"State`"=dword:00000000
`"LocalProfileLoadTimeLow`"=dword:409f513d
`"LocalProfileLoadTimeHigh`"=dword:01d7e5b8
`"ProfileAttemptedProfileDownloadTimeLow`"=dword:00000000
`"ProfileAttemptedProfileDownloadTimeHigh`"=dword:00000000
`"ProfileLoadTimeLow`"=dword:00000000
`"ProfileLoadTimeHigh`"=dword:00000000
`"RunLogonScriptSync`"=dword:00000000
`"LocalProfileUnloadTimeLow`"=dword:2c3ee568
`"LocalProfileUnloadTimeHigh`"=dword:01d7e5c2" | Out-File $profileRegDataFilePath
    Write-Output "Determined profile target path: $profileTargetPath"
}catch{
    Write-Output "Failed to compose regkeys"
    Write-Output $_
    Exit 1
}

try{
    Write-Output "Copying profile from $profileSourcePath to $profileTargetPath"
    Remove-Item $profileTargetPath -Force -Confirm:$False -ErrorAction SilentlyContinue -Recurse
    robocopy $profileSourcePath $profileTargetPath /MIR /XJ *>&1 | Out-Null
    Write-Output "Copied profile from $profileSourcePath to $profileTargetPath"
}catch{
    Write-Output $_
}

try{
    Write-Output "Dismounting remote profile disk"
    Dismount-DiskImage -ImagePath $profileRemotePath -StorageType $Extension -Confirm:$False
    Write-Output "Dismounted $profileRemotePath"
}catch{
    Write-Output $_
}

try{
    Invoke-Command {reg import $profileRegDataFilePath *>&1 | Out-Null}
    Remove-Item $profileRegDataFilePath -Force -Confirm:$False -Recurse -ErrorAction SilentlyContinue
}catch{
    Write-Output $_
}

try{
    Write-Output "Disabling FSLogix on $($env:COMPUTERNAME)"
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey("LocalMachine",[Microsoft.Win32.RegistryView]::Registry64)
    $key = $baseKey.OpenSubKey('SOFTWARE\FSlogix\Profiles\', $true)
    $key.SetValue('Enabled', 0, 'DWORD')
    $fslogixgroups = Get-LocalGroup | where {$_.Name -like "*Exclude List*"}
    $fslogixgroups | % {
        Add-LocalGroupMember -Group $_ -Member $user -ErrorAction SilentlyContinue
    }
    Write-Output "Disabled FSLogix on $($env:COMPUTERNAME)"
}catch{
    Write-Output $_
    Exit 1
}

Write-Output "Setting permissions on $profileTargetPath folder"
takeown /r /f $profileTargetPath /d Y /a | Out-Null
icacls $profileTargetPath /inheritance:r | Out-Null
icacls $profileTargetPath /grant Administrators:`(OI`)`(CI`)F /t /c /q | Out-Null
icacls $profileTargetPath /grant $($domainNetbiosName)\$($user):`(OI`)`(CI`)F /t /c /q | Out-Null
icacls $profileTargetPath /grant SYSTEM:`(OI`)`(CI`)F /t /c /q | Out-Null

Write-Output "Cleaning up"
Remove-Item -Path (Join-Path $profileTargetPath -ChildPath "AppData\Local\FSLogix") -Force -Confirm:$False -ErrorAction SilentlyContinue -Recurse
get-childitem -path "c:\users" | %{
    if($_.Name -like "local*"){
        Remove-Item -Path $_.FullName -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
        Write-Output "Removed $($_.FullName)"
    }
}

Remove-Item "C:\Users\$user\AppData\Local\OneDrive\cache" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
if($resetOnedrive ) {
    Remove-Item "C:\Users\$user\AppData\Local\Microsoft\OneDrive" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
}
Remove-Item "C:\Users\$user\AppData\Local\Microsoft\Office\16.0\Wef" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item "C:\Users\$user\AppData\Local\Packages\Microsoft.Win32WebViewHost_cw5n1h2txyewy\AC\#!123\INetCache" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue


& REG LOAD HKLM\temp "C:\Users\$user\NTUSER.DAT"
$baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey("LocalMachine",[Microsoft.Win32.RegistryView]::Registry64)
$key = $baseKey.OpenSubKey('temp\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders\', $true)
$key.SetValue('Cache', "%SystemDrive%\Users\$($user)\INetCache", 'ExpandString')
$key = $baseKey.OpenSubKey('temp\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders\', $true)
$key.SetValue('Cache', "C:\Users\$($user)\INetCache", 'ExpandString')
$key = $baseKey.OpenSubKey('temp\Environment\', $true)
$key.SetValue('TEMP', "C:\Users\$($user)\Temp", 'ExpandString')
$key.SetValue('TMP', "C:\Users\$($user)\Temp", 'ExpandString')
if($resetOnedrive){
    $baseKey.DeleteSubKeyTree('temp\SOFTWARE\Microsoft\OneDrive\Accounts\Business1', $true)
}
$baseKey.Close()

Write-Output "Script completed, VM is rebooting and will be ready for logon soon"
Restart-Computer -Force -Confirm:$False