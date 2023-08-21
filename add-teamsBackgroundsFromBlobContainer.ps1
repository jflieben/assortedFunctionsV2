<#
    .SYNOPSIS
    Sets custom backgrounds based on files in an Azure Storage Blob container
    See blob template to automatically configure a blob container: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/ARM%20templates/blob%20storage%20with%20container%20for%20Teams%20Backgrounds%20and%20public%20access.json
   
    .NOTES
    filename: add-teamsBackgroundsFromBlobContainer.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 13/05/2021
#>

Start-Transcript -Path (Join-Path -Path $Env:TEMP -ChildPath "add-teamsBackgroundsFromBlobContainer.log")

$changedDate = "2021-05-13"

$containerName = "tasdsadgsadsad" #this is the name of your storage account in Azure 

$source = "https://$($containerName).blob.core.windows.net/teamsbackgrounds?restype=container&comp=list"
Write-Output "Running version $changedDate"

Write-Output "Retrieving Blob container index..."
try{
    $blobs = Invoke-RestMethod -Method GET -Uri $source -UseBasicParsing
    Write-Output "Container index retrieved, parsing..."
}catch{
    Write-Output "Failed to retrieve container index, aborting"
    Write-Error $_ -ErrorAction SilentlyContinue
    Exit
}

$index = 0
$start = 0
$images = @()

while($true){
    $index = $blobs.IndexOf("<Url>",$index)
    if($index -eq -1){
        break
    }
    $index += 5
    $start = $index
    $index = $blobs.IndexOf("</Url>",$index)
    $images += $blobs.Substring($start,$index-$start)
}

Write-Output "$($images.count) blobs indexed"

if($images.count -eq 0){
    Write-Output "No images detected, aborting"
    Exit
}

$targetPath = (Join-Path $Env:APPDATA -ChildPath "\Microsoft\Teams\Backgrounds\Uploads")

#create Uploads folder if it doesn't exist
if(![System.IO.Directory]::Exists($targetPath)){
    try{
        New-Item -Path $targetPath -ItemType Directory -Force | out-null
    }catch{
        Write-Output "Failed to create path for teams backgrounds"
        Write-Error $_ -ErrorAction SilentlyContinue
        Exit
    }
}

Write-Output "Downloading images to $targetPath"

foreach($image in $images){
    try{
        Start-BitsTransfer -Source $image -Destination $targetPath -Confirm:$False
        Write-Output "$image completed"
    }catch{
        Write-Output "$image failed"
        Write-Error $_ -ErrorAction SilentlyContinue
    }
}

Write-Output "Script complete"
Stop-Transcript