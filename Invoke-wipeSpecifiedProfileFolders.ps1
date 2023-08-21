#Module name:      Invoke-wipeSpecifiedProfileFolders
#Author:           Jos Lieben
#Author Blog:      https://www.lieben.nu
#Date:             18-12-2020
#License:          Free to use and modify non-commercially, leave headers intact. For commercial use, contact me
#Purpose:          Delete all files in the specified folder names in all user profiles on the machine, self-installs as a scheduled task
#Setup:            Deploy to machines, in system context
#Requirements:     Windows 10 build 1803 or higher

$folderWipeList = "Downloads,Network Shortcuts,Temp,Documents" #comma seperated list of folders to wipe

$desiredScriptFolder = Join-Path $env:ProgramData -ChildPath "Lieben.nu"
$desiredScriptPath = Join-Path $desiredScriptFolder -ChildPath "Invoke-wipeSpecifiedProfileFolders.ps1"
if(![System.IO.Directory]::($desiredScriptFolder)){
    New-Item -Path $desiredScriptFolder -Type Directory -Force
}
Start-Transcript -Path (Join-Path $desiredScriptFolder -ChildPath "\folderWiperInstaller.log")

Write-Output "Configuring scheduled task..."

$taskname = "Invoke-wipeSpecifiedProfileFolders"
$taskdescription = "Delete all files in the specified folder names in all user profiles on the machine"
$action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy ByPass -File `"$desiredScriptPath`""
$triggers =  @()
$triggers += (New-ScheduledTaskTrigger -AtStartup)
$triggers += (New-ScheduledTaskTrigger -Daily -At 23:00)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$task = Register-ScheduledTask -Action $action -Trigger $triggers -TaskName $taskname -Description $taskdescription -Settings $settings -User "System" -Force -RunLevel Highest

Write-Output "task info: "
Write-Output $task

Write-Output "Writing script file to local disk..."

$scriptContent = "
Start-Transcript -Path (Join-Path $desiredScriptFolder -ChildPath `"\folderWiper.log`")
`$folderWipeList = `"$folderwipeList`"
`$folderWipeList = `$folderwipeList.Split(`",`")
Get-ChildItem 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\ProfileList' | ForEach-Object {
    `$rootPath =  `$_.GetValue('ProfileImagePath') 
    Write-Output `"Parsing folders in `$rootPath`"
    `$childItems = `$Null
    `$childItems = Get-ChildItem -Path `$rootPath -Directory -ErrorAction SilentlyContinue -Recurse -Force | where{`$folderWipeList -contains `$_.BaseName}
    if(`$childItems){
    	foreach(`$folder in `$childItems){
    		Write-Output `"Wiping matched folder: `$(`$folder.FullName)`"
    		Get-ChildItem -Path `$folder.FullName -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue -Recurse -Confirm:`$False
    	}
    }
}

Stop-Transcript"

Set-Content -Value $scriptContent -Path $desiredScriptPath -Force -Confirm:$False

Write-Output "Starting script as task for the first time..."

Start-ScheduledTask -InputObject $task

Write-Output "Install script has finished running"

Stop-Transcript
