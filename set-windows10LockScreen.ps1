<#
    .SYNOPSIS
    Sets custom lock screen based on file in an Azure Storage Blob container
    See blob template to automatically configure a blob container: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/ARM%20templates/blob%20storage%20with%20container%20for%20Teams%20Backgrounds%20and%20public%20access.json
   
    .NOTES
    filename: set-windows10LockScreen.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 13/05/2021
#>

$changedDate = "2021-05-13"
$lockscreenFileURL = "https://tasdsadgsadsad.blob.core.windows.net/teamsbackgrounds/figure-a.jpg" #this is the full URL to the desired lock screen image

Start-Transcript -Path (Join-Path -Path $Env:TEMP -ChildPath "set-windows10LockScreen.log")

$tempFile = (Join-Path $Env:TEMP -ChildPath "img100.jpg")

try{
    Write-Output "downloading lock screen file from $lockscreenFileURL"
    Invoke-WebRequest -Uri $lockscreenFileURL -UseBasicParsing -Method GET -OutFile $tempFile
    Write-Output "file downloaded to $tempFile"
}catch{
    Write-Output "Failed to download file, aborting"
    Write-Error $_ -ErrorAction SilentlyContinue
    Exit
}

[Windows.System.UserProfile.LockScreen,Windows.System.UserProfile,ContentType=WindowsRuntime] | Out-Null
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | ? { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
Function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

Function AwaitAction($WinRtAction) {
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | ? { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and !$_.IsGenericMethod })[0]
    $netTask = $asTask.Invoke($null, @($WinRtAction))
    $netTask.Wait(-1) | Out-Null
}

[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
		
try{
	$image = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tempFile)) ([Windows.Storage.StorageFile])
    Write-Output "Image loaded from $tempFile"
}catch {
    Write-Output "Failed to load image from $tempFile"
    Write-Error $_ -ErrorAction SilentlyContinue
    Exit
} 
       
try{ 
    Write-Output "Setting image as lock screen image"
    AwaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($image))
    Write-Output "$tempFile configured as lock screen image"
    Remove-Item -Path $tempFile -Force -Confirm:$False
}catch{
    Write-Output "Failed to set lock screen image"
    Write-Error $_ -ErrorAction SilentlyContinue
} 

Write-Output "Script complete"
Stop-Transcript