#Module name:       Invoke-redirectToO4B
#Author:            Jos Lieben
#Author Blog:       https://www.lieben.nu
#Created:           31-08-2021
#Updated:           15-10-2021
#Copyright/License: https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
#Purpose:           Redirect any folder to any location on a users (mounted) Onedrive for Business
#Requirements:      Windows 10 build 1803, Onedrive preinstalled / configured (see my blog for instructions on fully automating that)

$LogPath = $($env:temp) + "\Invoke-redirectToO4B.log"
Start-Transcript $LogPath -Append

#redirection information is read from the registry. Each desired redirection should be a Key under HKLM:\SOFTWARE\Lieben Consultancy\O4BAM\Redirections
#each key should have the following values
#source                           ==> Custom path (you can use PS Env vars or other code here) or choose from: 'AdminTools','ApplicationData','CommonApplicationData','CommonDesktopDirectory','CommonDocuments','CommonMusic','CommonPictures','CommonProgramFiles','CommonProgramFilesX86','CommonPrograms','CommonStartMenu','CommonStartup','CommonVideos','Cookies','Downloads','Desktop','Favorites','Fonts','History','InternetCache','LocalApplicationData','LocalizedResources','MyComputer','MyDocuments','MyMusic','MyPictures','MyVideos','NetworkShortcuts','PrinterShortcuts','ProgramFiles','ProgramFilesX86','Programs','Recent','Resources','SendTo','StartMenu','Startup','System','SystemX86','UserProfile','Windows'
#target                           ==> you can choose a subfolder (or subfolder path) to redirect to in the targetted location, you can also use PS code here to e.g. make user specific folders
#existingDataAction               ==> Allowed values: copy, move, delete, migrate
#setEnvironmentVariable           ==> Set to 1 if you want the script to register a %ENV% type variable with Windows to point to the new location. Only works for well known folders in the list above
#hideSource                       ==> Set to 1 to hide the source folder after redirection succeeds, 0 to do nothing. Only works for standard folders.

<#existingDataAction explanation:

When a known system folder such as My Documents, Desktop etc is redirected, existing data can be copied, moved or deleted. When this is done, the folder is redirected using the OS API's just like a Group Policy would do. This is reversible.

When a custom folder (appdata, other filesharing tools) is redirected, existing data can be moved, migrated or deleted. Copying is not possible and will automatically default to move because hard or soft links are used and these can only be created as empty folders. Thus existing data
needs to be moved first. Specify move to move data and create a hard link (leave existing folder), specify migrate to move data and create a soft link (shortcut), select delete to create a hard link and delete all existing data in the folder.
When redirecting appdata folders or any other folders that are accessed by applications, it is recommend to use move. When migrating from e.g. Box to Onedrive, it is recommended to use migrate.

#>
#retrieve desired redirections from the registry
$listOfFoldersToRedirect = @()
$rootPath = "HKLM:\SOFTWARE\Lieben Consultancy\O4BAM\Redirections"
if(!(Test-Path $rootPath)){
    Throw "No redirections have been configured in the registry at $rootPath"
}

foreach($key in Get-ChildItem -Path $rootPath){
    $regData = Get-ItemProperty -Path $key.PSPath
    $folder = [PSCustomObject]@{
        "source" = $regData.source
        "target" = $regData.target
        "existingDataAction" = $regData.existingDataAction
        "setEnvironmentVariable" = $regData.setEnvironmentVariable
        "hideSource" = $regData.hideSource
    }
    if(@("copy","move","delete","migrate","none") -notcontains $folder.existingDataAction){
        Write-Error "Folder redirection from $($regData.source) to $($regData.target) will not be processed because existingDataAction was not specified (copy, move, migrate, none or delete)" -ErrorAction Continue
        Continue
    }
    if($folder.source.Length -le 2){
        Write-Error "Folder redirection from $($regData.source) to $($regData.target) will not be processed because the source is too short or not specified" -ErrorAction Continue
        Continue
    }
    if($folder.target.Length -le 2){
        Write-Error "Folder redirection from $($regData.source) to $($regData.target) will not be processed because the target is too short or not specified" -ErrorAction Continue
        Continue
    }
    $listOfFoldersToRedirect += $folder
}

$overallStatus = $True
$statusRootPath = "HKCU:\SOFTWARE\Lieben Consultancy\O4BAM\Status"
#ensure a status registry key exists to nest results under for each user
if(!(Test-Path $statusRootPath)){
    New-Item $statusRootPath -Force | Out-Null
    New-ItemProperty -Path $statusRootPath -Name "Overall" -Value "Started" -Force | Out-Null
}

#write initial status (started) to registry keys under each user
foreach($folderToRedirect in $listOfFoldersToRedirect){
    if(!(Test-Path (Join-Path $statusRootPath -ChildPath $folderToRedirect.source))){
        New-ItemProperty -Path $statusRootPath -Name $folderToRedirect.source -Value "Started" -Force | Out-Null
    }
}

if($Env:USERPROFILE.EndsWith("system32\config\systemprofile")){
    Write-Output "Running as SYSTEM, this script should run in user context!"
    Exit
}else{
    Write-Output "Running as $($env:USERNAME)"
}

try{
    $tenantIdKeyPath = "HKLM:\System\CurrentControlSet\Control\CloudDomainJoin\TenantInfo"
    $tenantId = @(Get-ChildItem -Path $tenantIdKeyPath)[0].Name.Split("\")[-1]
    if(!$tenantId -or $tenantId.Length -lt 10){
        Throw "No valid tenant ID returned from $tenantIdKeyPath"
    }
    Write-Output "Tenant ID $tenantId detected in $tenantIdKeyPath"
}catch{
    Throw $_
}

$KnownFolders = @{
    'AdminTools' = '724EF170-A42D-4FEF-9F26-B60E846FBA4F';'ApplicationData'='3EB685DB-65F9-4CF6-A03A-E3EF65729F3D';'CommonApplicationData'='62AB5D82-FDC1-4DC3-A9DD-070D1D495D97';
    'CommonDesktopDirectory' = 'C4AA340D-F20F-4863-AFEF-F87EF2E6BA25';'CommonDocuments' = 'ED4824AF-DCE4-45A8-81E2-FC7965083634';'CommonMusic'='3214FAB5-9757-4298-BB61-92A9DEAA44FF';
    'CommonPictures' = 'B6EBFB86-6907-413C-9AF7-4FC2ABF07CC5'; 'CommonProgramFiles' = 'F7F1ED05-9F6D-47A2-AAAE-29D317C6F066'; 'CommonProgramFilesX86' = 'DE974D24-D9C6-4D3E-BF91-F4455120B917';
    'CommonPrograms'='0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8';'CommonStartMenu'='A4115719-D62E-491D-AA7C-E74B8BE3B067';'CommonStartup'='82A5EA35-D9CD-47C5-9629-E15D2F714E6E';
    'CommonVideos'='2400183A-6185-49FB-A2D8-4A392A602BA3'; 'Cookies'='2B0F765D-C0E9-4171-908E-08A611B84FF6';'Downloads'=@('374DE290-123F-4565-9164-39C4925E467B','7d83ee9b-2244-4e70-b1f5-5393042af1e4');
    'Desktop'='B4BFCC3A-DB2C-424C-B029-7FE99A87C641';'Favorites'='1777F761-68AD-4D8A-87BD-30B759FA33DD';'Fonts'='FD228CB7-AE11-4AE3-864C-16F3910AB8FE';'History'='D9DC8A3B-B784-432E-A781-5A1130A75963';
    'InternetCache'='352481E8-33BE-4251-BA85-6007CAEDCF9D';'LocalApplicationData'='F1B32785-6FBA-4FCF-9D55-7B8E7F157091';'LocalizedResources'='2A00375E-224C-49DE-B8D1-440DF7EF3DDC';
    'MyComputer'='0AC0837C-BBF8-452A-850D-79D08E667CA7';'MyDocuments'=@('FDD39AD0-238F-46AF-ADB4-6C85480369C7','f42ee2d3-909f-4907-8871-4c22fc0bf756');'MyMusic'=@('4BD8D571-6D19-48D3-BE97-422220080E43','a0c69a99-21c8-4671-8703-7934162fcf1d');
    'MyPictures'=@('33E28130-4E1E-4676-835A-98395C3BC3BB','0ddd015d-b06c-45d5-8c4c-f59713854639');'MyVideos'=@('18989B1D-99B5-455B-841C-AB7C74E4DDFC','35286a68-3c57-41a1-bbb1-0eae73d76c95');
    'NetworkShortcuts'='C5ABBF53-E17F-4121-8900-86626FC2C973';'PrinterShortcuts'='9274BD8D-CFD1-41C3-B35E-B13F55A758F4';'ProgramFiles'='905e63b6-c1bf-494e-b29c-65b732d3d21a';
    'ProgramFilesX86'='7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E';'Programs'='A77F5D77-2E2B-44C3-A6A2-ABA601054A51';'Recent'='AE50C081-EBD2-438A-8655-8A092E34987A';
    'Resources'='8AD10C31-2ADB-4296-A8F7-E4701232C972';'SendTo'='8983036C-27C0-404B-8F08-102D10DCFD74';'StartMenu'='625B53C3-AB48-4EC1-BA1F-A1EF4146FC19';
    'Startup'='B97D20BB-F46A-4C97-BA10-5E3608430854';'System'='1AC14E77-02E7-4E5D-B744-2EB1AE5198B7';'SystemX86'='D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27';
    'UserProfile'='5E6C858F-0E22-4760-9AFE-EA3317B67173';'Windows'='F38BF404-1D43-42F2-9305-67DE0B28FC23'
}

Function Set-KnownFolderPath {
    Param (
            [Parameter(Mandatory = $true)][string]$KnownFolder,
            [Parameter(Mandatory = $true)][string]$Path
    )
    $Type = ([System.Management.Automation.PSTypeName]'KnownFolders').Type
    If (-not $Type) {
        $Signature = @'
[DllImport("shell32.dll")]
public extern static int SHSetKnownFolderPath(ref Guid folderId, uint flags, IntPtr token, [MarshalAs(UnmanagedType.LPWStr)] string path);
'@
        $Type = Add-Type -MemberDefinition $Signature -Name 'KnownFolders' -Namespace 'SHSetKnownFolderPath' -PassThru
    }

	If (!(Test-Path $Path -PathType Container)) {
		New-Item -Path $Path -Type Directory -Force -Verbose
    }

    If (Test-Path $Path -PathType Container) {
        ForEach ($guid in $KnownFolders[$KnownFolder]) {
            $result = $Type::SHSetKnownFolderPath([ref]$guid, 0, 0, $Path)
            If ($result -ne 0) {
                Throw "Error redirecting $($KnownFolder). Return code $($result) = $((New-Object System.ComponentModel.Win32Exception($result)).message)"
            }
        }
    } Else {
        Throw (New-Object System.IO.DirectoryNotFoundException "Could not find part of the path $Path.")
    }
    Return $Path
}

Function Get-KnownFolderPath {
    Param (
            [Parameter(Mandatory = $true)][string]$KnownFolder
    )
    if($KnownFolder -eq "Downloads"){
        Return (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
    }else{
        Return [Environment]::GetFolderPath($KnownFolder)
    }
}

Function Redirect-Folder {
    Param (
        [Parameter(Mandatory = $true)]$source,
        [Parameter(Mandatory = $true)]$target,
        [Int]$hideSource,
		[String]$existingDataAction,
        [Int]$setEnvironmentVariable
    )

    $Folder = Get-KnownFolderPath -KnownFolder $source
    If ($Folder -ne $target) {
	    If (!(Test-Path $target -PathType Container)) {
		    New-Item -Path $target -Type Directory -Force -Verbose
        }
        if($Folder -and (Test-Path $Folder -PathType Container) -and (Test-Path $target -PathType Container)){
            if($existingDataAction -eq "migrate"){
                $existingDataAction = "move"
                Write-Output "unsupported method (migrate) specified for known folder redirection, switching to move mode"
            }
            try{
                if($existingDataAction -eq "copy"){
                    Write-Output "Copying original files from source to destination"
                    Get-ChildItem -Path $Folder -ErrorAction Stop | % {
                        Copy-Item -Path $_.FullName -Destination $target -Recurse -Container -Force -Confirm:$False -ErrorAction Stop
                        Write-Output "Copied $($_.FullName) to $target"
                    }
                }
                if($existingDataAction -eq "move"){
                    Write-Output "Moving original files from source to destination"
                    Get-ChildItem -Path $Folder -ErrorAction Stop | %{
                        Move-Item -Path $_.FullName -Destination $target -Force -Confirm:$False -ErrorAction Stop
                        Write-Output "Moved $($_.FullName) to $target"
                    }
                }
                if($existingDataAction -eq "delete"){
                    Write-Output "Deleting original files in source"
                    Get-ChildItem -Path $Folder -ErrorAction Stop | % {
                        Remove-Item -Path $_.FullName -Recurse -Force -Confirm:$False -ErrorAction Stop
                        Write-Output "Removed $($_.FullName)"
                    }
                }
                Write-Output "Operation succeeded"
            }catch{
                Throw $_
            }
        }

        Set-KnownFolderPath -KnownFolder $source -Path $target

        if($hideSource -eq 1 -and $Folder){
            Attrib +h $Folder
        }
    }
    if($setEnvironmentVariable -eq 1){
        [Environment]::SetEnvironmentVariable($source, $target, "User")
    }
}

Function Redirect-SpecialFolder {
    Param(
        [Parameter(Mandatory = $true)]$source,
        [Parameter(Mandatory = $true)]$target,
        [Int]$hideSource,
        [String]$existingDataAction
    )
    if($existingDataAction -eq "copy"){
        $existingDataAction = "move"
        Write-Output "unsupported method (copy) specified for special folder redirection, switching to move mode"
    }

    $shortcutPath = "$(Split-Path $source -parent)\$(Split-Path $source -leaf).lnk"

    #create source location folder if needed
    if(!(Test-Path (Split-Path $source -parent))){
        $existingDataAction = "none"
        Write-Output "created folder structure $source"
        try{New-Item (Split-Path -Path $source -Parent) -ItemType Directory -Force | Out-Null}catch{$Null}
    }else{
        if($existingDataAction -ne "migrate"){
            if((Get-Item $source).Target -eq $target){
                Write-Output "Hard link already pointing to correct location, nothing to do here"
                return $True
            }elseif((Get-Item $source).Target -and (Get-Item $source).Target -ne $target){
                Write-Output "Hard link exists, but is poiting to the wrong target, will update"
                rmdir $source -force -confirm:$false
            }else{
                Write-Output "Hard link does not exist yet"
            }
        }else{
            if((Test-Path $shortcutPath)){
                $sh = New-Object -ComObject WScript.Shell
                if($sh.CreateShortcut($shortcutPath).TargetPath -eq $target){
                    Write-Output "Soft link is already point to correct location, nothing to do here"
                    return $True
                }else{
                    Write-Output "Soft link exists but is pointing to wrong target, will update"
                    Remove-Item -Path $shortcutPath -Force -Confirm:$False
                }
            }else{
                Write-Output "Soft link does not exist yet"
            }
        }
    }

    #create target location if needed
    if(!(Test-Path $target)){
        Write-Output "created folder $target"
        New-Item $target -ItemType Directory -Force | Out-Null
    }
    
    #Check if the location we're redirecting from exists and if we need to copy anything. To create a hardlink, the source folder must be empty
    if((Test-Path $source)){
        if($existingDataAction -eq "move" -or $existingDataAction -eq "migrate"){
            Write-Output "Moving original files from source to destination"
            Try{
                Get-ChildItem -Path $source -ErrorAction Stop | % {
                    Move-Item -Path $_.FullName -Destination $target -Force -Confirm:$False -ErrorAction Stop
                    Write-Output "Moved $($_.FullName) to $target"
                }
            }Catch{
                Throw $_
            }
            Write-Output "Original files moved"
        }
        Remove-Item $source -Recurse -Force -Confirm:$False
    }

    #create a hard link or soft link
    if($existingDataAction -eq "migrate"){
        Set-Variable -Name desktopIniContent -value ([string]"[.ShellClassInfo]`r`nCLSID2={0AFACED1-E828-11D1-9187-B532F1E9575D}`r`nFlags=2")
        Set-Content -Path "$(Split-Path $source -parent)\desktop.ini" -Value $desktopIniContent -Force
        $WshShell = New-Object -ComObject WScript.Shell   
        $Shortcut = $WshShell.CreateShortcut($shortcutPath)
        $Shortcut.TargetPath = $target         
        $Shortcut.Description = "Created $(Get-Date -Format s) by O4BAM Lieben Consultancy"
        $Shortcut.Save()
        write-output "soft link created or updated"
    }else{
        invoke-expression "cmd /c mklink /J `"$source`" `"$target`""
        Write-Output "hard link created or updated"
    }
}

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")

#Wait until Onedrive client is running, and has been running for at least 3 seconds
while($true){
    try{
        $o4bProcessInfo = @(get-process -name "onedrive" -ErrorAction SilentlyContinue)[0]
        if($o4bProcessInfo -and (New-TimeSpan -Start $o4bProcessInfo.StartTime -End (Get-Date)).TotalSeconds -gt 3){
            Write-Output "Detected a running instance of Onedrive"
            break
        }else{
            Write-Output "Onedrive client not yet running..."
            Sleep -s 3
        }
    }catch{
        Write-Output "Onedrive client not yet running..."
    }
}

#wait until Onedrive has been configured properly (ie: linked to user's account)
$odAccount = $Null
$companyName = $Null
$userEmail = $Null
:accounts while($true){
    #check if the Accounts key exists (Onedrive creates this)
    try{
        if(Test-Path HKCU:\Software\Microsoft\OneDrive\Accounts){
            #look for a Business key with our configured tenant ID that is properly filled out
            foreach($account in @(Get-ChildItem HKCU:\Software\Microsoft\OneDrive\Accounts)){
                if($account.GetValue("Business") -eq 1 -and $account.GetValue("ConfiguredTenantId") -eq $tenantId){
                    Write-Output "Detected $($account.GetValue("UserName")), linked to tenant $($account.GetValue("DisplayName")) ($($tenantId))"
                    if(Test-Path $account.GetValue("UserFolder")){
                        $odAccount = $account
                        Write-Output "Folder located in $($odAccount.GetValue("UserFolder"))"
                        $companyName = $account.GetValue("DisplayName").Replace("/"," ")
                        $userEmail = $account.GetValue("UserEmail")
                        break accounts
                    }else{
                        Write-Output "But no user folder detected yet (UserFolder key is empty)"
                    }
                }
            }             
        }
    }catch{$Null}
    Write-Output "Onedrive not yet fully configured for this user..."
    Sleep -s 2
}

#time to process Folder Redirections
foreach($redirection in $listOfFoldersToRedirect){
    $parsedTarget = Invoke-Expression "`"$($redirection.target)`"" -ErrorAction Stop
    $targetPath = Join-Path -Path $odAccount.GetValue("UserFolder") -ChildPath $parsedTarget
    $failed = $False
    Write-Output "redirecting $($redirection.source) to $($redirection.target) (under onedrive)"
    if($KnownFolders.$($redirection.source)){
        try{
            Redirect-Folder -source $redirection.source -target $targetPath -hideSource $redirection.hideSource -existingDataAction $redirection.existingDataAction -setEnvironmentVariable $redirection.setEnvironmentVariable
            Write-Output "Redirected special folder $($redirection.source) to $targetPath"
        }catch{
            Write-Output "Failed to redirect special folder $($redirection.source) to $targetPath"
            $_
            $failed = $True
        }
    }else{
        try{
            $parsedSource = Invoke-Expression "`"$($redirection.source)`"" -ErrorAction Stop
            Redirect-SpecialFolder -source $parsedSource -target $targetPath -hideSource $redirection.hideSource -existingDataAction $redirection.existingDataAction
            Write-Output "Redirected custom path $($redirection.source) to $targetPath"
        }catch{
            Write-Output "Failed to redirect custom path $($redirection.source) to $targetPath"
            $_
            $failed = $True
        }
    }
    if($failed){
        $overallStatus = $False
        New-ItemProperty -Path $statusRootPath -Name $redirection.source -Value "Failed" -Force | Out-Null
    }else{
        New-ItemProperty -Path $statusRootPath -Name $redirection.source -Value "Completed" -Force | Out-Null
    }
}

if($overallStatus){
    New-ItemProperty -Path $statusRootPath -Name "Overall" -Value "Completed" -Force | Out-Null
}else{
    New-ItemProperty -Path $statusRootPath -Name "Overall" -Value "Failed" -Force | Out-Null
}

Write-Output "Creating / checking existence of hidden log folder in user Onedrive"
$targetPath = Join-Path -Path $odAccount.GetValue("UserFolder") -ChildPath "OnedriveFolderRedirect (do not delete)"

if(!(Test-Path -Path $targetPath)){
    New-Item -Path $targetPath -Force -ItemType Directory -Confirm:$False | Out-Null
    Attrib +h $targetPath 
}

Write-Output "Main script completed, stopping log stream before moving log file to $targetPath"

Stop-Transcript

Move-Item -Path $LogPath -Destination (Join-Path -Path $targetPath -ChildPath "$(Get-Date -format "dd-MM-yyyy-HH-mm")-Invoke-redirectToO4B.log") -Force -Confirm:$False
New-ItemProperty -Path (Split-Path $statusRootPath -parent) -Name "Logpath" -Value (Join-Path -Path $targetPath -ChildPath "$(Get-Date -format "dd-MM-yyyy-HH-mm")-Invoke-redirectToO4B.log") -Force | Out-Null
Write-Output "Finished"