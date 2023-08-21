Param(
    [String]$sourcePath,
    [String]$targetPath
)

[System.Reflection.Assembly]::UnsafeLoadFrom('https://gitlab.com/Lieben/assortedFunctions/-/raw/master/lib/AlphaFS.dll?inline=false')

$sourcePath = [Alphaleonis.Win32.Filesystem.Path]::GetLongPath($sourcePath)
$targetPath = [Alphaleonis.Win32.Filesystem.Path]::GetLongPath($targetPath)

if([Alphaleonis.Win32.Filesystem.Directory]::Exists($sourcePath)){
    Write-Verbose "Detected sourcePath as FOLDER"
    $sourceObject = New-Object Alphaleonis.Win32.Filesystem.DirectoryInfo($sourcePath)
}elseif([Alphaleonis.Win32.Filesystem.File]::Exists($sourcePath)){
    Write-Verbose "Detected sourcePath as FILE"
    $sourceObject = New-Object Alphaleonis.Win32.Filesystem.FileInfo($sourcePath)
}else{
    Throw "sourcePath not found"
}

if([Alphaleonis.Win32.Filesystem.Directory]::Exists($targetPath)){
    Write-Verbose "Detected targetPath as FOLDER"   
    $targetObject = New-Object Alphaleonis.Win32.Filesystem.DirectoryInfo($targetPath)
}elseif([Alphaleonis.Win32.Filesystem.File]::Exists($targetPath)){
    Write-Verbose "Detected targetPath as FILE"
    $targetObject = New-Object Alphaleonis.Win32.Filesystem.FileInfo($targetPath)
}else{
    Throw "targetPath not found"
}

$sourceACL = $sourceObject.GetAccessControl("Access")
$targetObject.SetAccessControl($sourceACL)