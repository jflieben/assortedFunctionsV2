<#
    .SYNOPSIS
    Sets MS Teams AVD mode, uninstalls existing teams and installs the latest including required web rtc redir

    .NOTES
    author: Jos Lieben / jos@lieben.nu
    url: https://www.lieben.nu
    copyright: Lieben Consultancy, unlimited free use for anyone
    Created: 02/02/2023
#>

#teams download url
$teamsDownloadUrl = "https://teams.microsoft.com/downloads/desktopurl?env=production&plat=windows&arch=x64&managedInstaller=true&download=true"

#redirector download Url
$redirectorDownloadUrl = "https://aka.ms/msrdcwebrtcsvc/msi"

$workingDir = Join-Path $Env:TEMP -ChildPath "TeamsInstall" 
if(!(Test-Path -Path $workingDir)){
  New-Item $workingDir -ItemType Directory -Force > $null
}

$teamsInstaller = Join-Path -Path $workingDir -ChildPath "teamsinstaller.msi"
$redirInstaller = Join-Path -Path $workingDir -ChildPath "redirInstaller.msi"
$logfile        = "$env:windir\logs\teamsandwebrtcinstall.log"

#download both installers
Invoke-WebRequest -UseBasicParsing -Uri $teamsDownloadUrl -OutFile $teamsInstaller
Invoke-WebRequest -UseBasicParsing -Uri $redirectorDownloadUrl -OutFile $redirInstaller

#uninstall existing teams versions if found
wmic product where "name like 'Teams Machine-wide Installer'" call uninstall /nointeractive

Start-Sleep -Seconds 20

# Stop msiexec.exe if process is running before installation
foreach ($_ in (Get-Process | Where-Object { $_.Name -like "*msiexec*" })) {
  $ProcessID = $_.Id
  Stop-Process -Id $ProcessID -Force
}

#set AVD regkey for media optimization
if(!(Test-Path "HKLM:\SOFTWARE\Microsoft\Teams")){
    New-Item -Path "HKLM:\Software\Microsoft" -Name "Teams" -Force
}
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Teams" -Name "IsWVDEnvironment" -Value 1 -Force


Start-Process `
    -FilePath "$redirInstaller" `
    -ArgumentList "/quiet /qn" `
    -Wait `
    -Passthru

Start-Process `
    -FilePath "$teamsInstaller" `
    -ArgumentList "/quiet /qn /L*v! $logfile ALLUSER=1 ALLUSERS=1" `
    -Wait `
    -Passthru

Remove-Item $workingDir -Force -Recurse -Confirm:$False