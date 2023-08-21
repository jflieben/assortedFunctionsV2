#Module name:           migrate-modifiedSpOSyncedFilesToUserDesktop
#Author:                Jos Lieben
#Author Blog:           http://www.lieben.nu
#Date:                  29-09-2022
#Copyright/License:     https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
#Purpose:               Removes Sharepoint Online sync relationships for a given tenant ID and copies all data from after a given date to a given folder in the user's desktop

###CONFIG
$oldTenantId = "ab713612-c917-4bf5-8b91-4a5212340705"
$oldTenantName = "XXXCOMPANYXXX"
$desktopTargetFolderName = "XXXCOMPANY?XXX Old Files"
$afterYear = 2022
$afterMonth = 6
$afterDay = 24
$afterHour = 23
$timeZone = 'South Africa Standard Time'
$removeSyncRelationship = $False

###SCRIPT START
$LogPath = $($env:temp) + "\migrate-modifiedSpOSyncedFilesToUserDesktop.log"
Start-Transcript $LogPath

if($Env:USERPROFILE.EndsWith("system32\config\systemprofile")){
    Write-Error "Running as SYSTEM"
    Exit
}

$mountPaths = @()
$syncRelationshipsToDelete = @()

try{
    if((Test-Path HKCU:\Software\Microsoft\OneDrive\Accounts)){
        #look for a Business key with our configured tenant ID that is properly filled out
        foreach($account in @(Get-ChildItem HKCU:\Software\Microsoft\OneDrive\Accounts)){
            if($account.GetValue("Business") -eq 1 -and $account.GetValue("ConfiguredTenantId") -eq $oldTenantId){
                Write-Output "Detected $($account.GetValue("UserName")) linked to tenant $($account.GetValue("DisplayName")) ($($oldTenantId))"
                $mountPathsLocal = Get-ItemProperty -Path (Join-Path $account.Name.Replace("HKEY_CURRENT_USER","HKCU:") -ChildPath "ScopeIdToMountPointPathCache")
                $mountPaths += ($mountPathsLocal.PSObject.Properties | where{$_.Name -notlike "PS*"} | select Value).Value
                $syncRelationshipsToDelete += @{
                    "Path" = $account.Name.Replace("HKEY_CURRENT_USER","HKCU:")
                    "Name" = $account.GetValue("DisplayName")
                }
            }
        }             
    }
}catch{$Null}

if($mountPaths.Count -eq 0 -or $syncRelationshipsToDelete -eq 0){
    $mountPaths += (Join-Path $Env:userprofile -ChildPath $oldTenantName)
    $syncRelationshipsToDelete += @{
        "Name" = $oldTenantName
    }
}

$targetPath = (Join-Path ([Environment]::GetFolderPath("Desktop")) -ChildPath $desktopTargetFolderName)
$breakOffDateTime = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((New-Object DateTime $afterYear, $afterMonth, $afterDay, $afterHour, 0, 0, ([DateTimeKind]::Local)), [System.TimeZoneInfo]::Local.Id, $timeZone)

if($mountPaths.count -gt 0){
    foreach($mountPath in $mountPaths){
        Write-Output "Processing $mountPath"
        if(!(Test-Path $targetPath)){
            New-Item $targetPath -ItemType Directory -Force
            Write-Output "Created $targetPath as it didn't exist yet"
        }
        Write-Output "Counting all items in $mountpath"
        $items = Get-ChildItem -Path $mountPath -Recurse -Force
        Write-Output "Copying files from after $breakOffDateTime out of total $($items.Count) items from $mountpath to $targetPath"
        foreach($item in $items) {
            if([DateTime]$item.LastWriteTime -gt $breakOffDateTime -and !$item.PSIsContainer){
                $num=1
                $nextName = Join-Path -Path $targetPath -ChildPath $item.name

                while(Test-Path -Path $nextName){
                   $nextName = Join-Path $targetPath ($item.BaseName + "_$num" + $item.Extension)    
                   $num++   
                }

                try{
                    Write-Output "copying $($item.FullName) to $nextName"
                    $item | Copy-Item -Destination $nextName -ErrorAction Continue -Force
                }catch{
                    Write-Output "Failed to copy $($_)"
                }
            } 
        }
        Write-Output "Setting read-only on $mountpath"
        attrib +r "$($mountPath)\*.*" /s /d
    }
}

if($removeSyncRelationship){
    if($syncRelationshipsToDelete.Count -gt 0){
        New-PSDrive -PSProvider registry -Root HKEY_CLASSES_ROOT -Name HKCR
        Start-Process "C:\Program Files\Microsoft OneDrive\OneDrive.exe" /shutdown
        Start-Sleep -Milliseconds 500

        foreach($relationship in $syncRelationshipsToDelete){
            if($relationship.Path) {
                Write-Output "Removing sync relationship $($relationship.Name) reg key $($relationship.Path)"
                Remove-Item -Path $relationship.Path -Recurse -Force -Confirm:$False
                Write-Output "Removing sync relationship $($relationship.Name) removing local appdata folder"
                Remove-Item -Path "$($env:LOCALAPPDATA)\Microsoft\Onedrive\settings\$($relationship.Path.Split("\")[-1])" -Recurse -Force -Confirm:$False
            }
            foreach($clsid in (get-childitem "HKCR:\CLSID")){
                if((get-itemproperty $clsid.Name.Replace("HKEY_CLASSES_ROOT","HKCR:"))."(default)" -like "*$($relationship.Name)*"){
                    Write-Output "Removing sync relationship $($relationship.Name) updating CLSID"
                    Set-ItemProperty -Path "$($clsid.Name.Replace("HKEY_CLASSES_ROOT","HKCR:"))" -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type "Dword" -Force
                    break
                }
            }

            
        }
        Start-Process "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
    }
}

Stop-Transcript

