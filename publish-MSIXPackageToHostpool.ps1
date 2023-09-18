<#
    .SYNOPSIS
    Publishes an MSIX package to a hostpool

    .NOTES
    filename: Publish-MSIXPackageToHostpool
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use/modify as long as headers are kept intact
    site: https://www.lieben.nu
    Created: 18/09/2023
#>

Param(
    [String][Parameter(Mandatory=$true)]$environment, #e.g. dev, prd
    [String][Parameter(Mandatory=$true)]$packageName #e.g. "NotePadPlusPlus_1.0.0.0_x64__bn7xwmddcff80"
)

# Define the path of the source files
$sourceFilesPath = $Env:BUILD_SOURCESDIRECTORY

# Define the path of the parameter file, using the $environment and $packageName variables
$paramFilePath = "$($sourceFilesPath)\components\remoteApps\$($packageName).$($environment).json"

# Add the cimfs class to be able to use the CimMountImage and CimDismountImage methods
Add-Type -ErrorAction Stop -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;
    public static class cimfs
    {
        [DllImport( "cimfs.dll" , CallingConvention = CallingConvention.StdCall , ExactSpelling=true, PreserveSig=false , SetLastError = true , CharSet = CharSet.Auto )]
        public static extern long CimMountImage(
            [MarshalAs(UnmanagedType.LPWStr)]
            String imageContainingPath ,
            [MarshalAs(UnmanagedType.LPWStr)]
            String imageName ,
            int mountImageFlags , 
            ref Guid volumeId );
        [DllImport( "cimfs.dll" , CallingConvention = CallingConvention.StdCall , ExactSpelling=true, PreserveSig=false , SetLastError = true , CharSet = CharSet.Auto )]
        public static extern long CimDismountImage(
            Guid volumeId );
    }
'@


# Define the path where the MSIX package will be mounted
$mountPath = "c:\temp\msix"

# Remove the mount path if it already exists, easier than cleaning the folder
if((Test-Path -Path $mountPath)){
    Remove-Item -Path $mountPath -Force -Recurse -Confirm:$False
}

# Create the mount path
if(!(Test-Path (Split-Path $mountPath -Parent))){
    New-Item -Path (Split-Path $mountPath -Parent) -Force -ItemType Directory -Confirm:$False
}

#mount the azure fileshare with MSIX files
Write-Output "Request acknowledged to publish $packageName to $environment"
Write-Output "Getting SA key"
$saName = "samsix$($environment)01"
$saKey = (Get-AzStorageAccountKey -ResourceGroupName "rg-storage-$($environment)-weeu-01" -AccountName $saName)[0].Value
$AzureFilesLoc = "\\$($saName).file.core.windows.net\msix"
$saUser = "AZURE\$saName"
Write-Output "Will connect as $saUser to $AzureFilesLoc"

try{
    Write-Output "Mounting $AzureFilesLoc"
    $LASTEXITCODE = 0 
    $out = NET USE $AzureFilesLoc /USER:$($saUser) $($saKey) /PERSISTENT:NO 2>&1
    if($LASTEXITCODE -ne 0){
        Throw "Failed to mount share because of $out"
    }
    Write-Output "Mounted $AzureFilesLoc succesfully"
}catch{
    Write-Output $_
    Throw
}

#find CIM file containing MSIX data
$cimFileName = "$($packageName).cim"
$imagePath = (Join-Path $AzureFilesLoc -ChildPath "$packageName\$($cimFileName)")
if(!(Test-Path $imagePath)){
    Write-Output "$imagePath does not exist!"
    Throw
}

Write-Output "Mounting CIM $($imagePath)"

#mount the CIM file
$guid = (New-Guid).Guid
$result = [cimfs]::CimMountImage( (Split-Path $imagePath -Parent)  , $cimFileName , 1 , [ref]$guid )
$lastError = [ComponentModel.Win32Exception][Runtime.InteropServices.Marshal]::GetLastWin32Error()

function closeCIMSession{
    [io.directory]::Delete( $mountPath)
    [cimfs]::CimDismountImage($guid)
}

#find the volume that was created while mounting the CIM file
if(!$result){
    $volume = Get-CimInstance -ClassName win32_volume | Where-Object { $_.filesystem -eq 'cimfs' -and $_.Name -match $guid.Guid }
    Write-Output "Mounted $imagePath with guid $($guid.Guid)"
}else{
    Throw "Failed to mount file - $lastError"
    closeCIMSession
    Throw
}

#create a hard link instead of a driveletter to the volume
cmd.exe /c mklink /j $mountPath $volume.Name

#find the target MSIX package in the MSIXPackages folder on the new volume
$packages = Get-ChildItem (Join-Path $mountPath -ChildPath "MSIXPackages")
if($packages.Name -notcontains $packageName){
    Write-Output "$packageName was not found in the MSIX CIM. Please ensure the packageName supplied matches an existing package"
    Throw
}else{
    $packageFolder = $packages | Where-Object{$_.Name -eq $packageName}
    Write-Output "Found package"
}

try{
    $packageMeta = Get-Content -Path (Join-Path $packageFolder.FullName -ChildPath "AppxManifest.xml") -Raw
    Write-Output "Found manifest, parsing..."
}catch{
    Write-Output "No appx manifest file found in $($packageFolder.FullName)"
    closeCIMSession
    Throw
}

#read the AppxManifest and parse relevant data from it that we'll need to pass to MS's API's
$packageShortName = $packageFolder.Name.Split("_")[0]
$packageFamily = $packageFolder.Name.Split("_")[-1]
$packageVersion = $packageFolder.Name.Split("_")[1]

$packageApplications = @()
$sIndex = $packageMeta.IndexOf("<Applications>")
$endOfAppsIndex = $packageMeta.IndexOf("</Applications>")
if(!$sIndex){Write-Output "No applications list found in AppManifest";Exit 1}
while($true){
    try{
        $sIndex = $packageMeta.IndexOf("<Application Id=",$sIndex)
        if($sIndex -gt $endOfAppsIndex -or $sIndex -eq -1){
            throw #reached the end of all configured applications in the manifest
        }
        $sIndex += 17 #move pointer to start of app ID
        $eIndex = $packageMeta.IndexOf("`" Executable",$sIndex)
        $appId = $packageMeta.Substring($sIndex,$eIndex-$sIndex)
        $sIndex = $packageMeta.IndexOf("DisplayName",$eIndex)
        $sIndex += 13 #move pointer to start of app displayName
        $eIndex = $packageMeta.IndexOf("`"",$sIndex)
        $displayName = $packageMeta.Substring($sIndex,$eIndex-$sIndex)
        if(!$displayName -or !$appId){
            Throw #no proper displayname and/or appid for this application entry
        }
    }catch{break}
    $packageApplications += [PSCustomObject]@{
        "appUserModelID"="$($packageShortName)_$($packageFamily)!$($appId)"
        "appId"=$appId
        "description"=$displayName
        "friendlyName"=$displayName
        "iconImageName"="$($appId)-Square44x44Logo.scale-100.png"
        "rawIcon"=[convert]::ToBase64String((get-content (Join-Path $packageFolder.FullName -ChildPath "Assets\$($appId)-Square44x44Logo.scale-100.png") -encoding byte))
        "rawPng"=[convert]::ToBase64String((get-content (Join-Path $packageFolder.FullName -ChildPath "Assets\$($appId)-Square44x44Logo.scale-100.png") -encoding byte))
    }
}

if($packageApplications.count -eq 0){
    Write-Output "No applications found in AppManifest of this MSIX";Exit 1
}

#create the MSIX package object in the hostpool. Ensure the lastUpdated value is always unique otherwise it will fail to overwrite an existing package with the same value
try{
    $apiPostData = @{
        "properties" = @{
            "displayName" = if($packageMeta -match "(?<=<DisplayName>)(.*?)(?=<\/DisplayName>)"){$matches[1]}else{Throw "No display name found in AppManifest"}
            "imagePath" = $imagePath
            "isActive" = $True
            "isRegularRegistration" = $False
            "lastUpdated" = (get-itemproperty $packageFolder.FullName).LastWriteTimeUtc.AddSeconds((Get-Random -Minimum "-150" -Maximum 150)).ToString("yyyy-MM-ddThh:mm:ss")
            "packageApplications" = $packageApplications
            "packageDependencies" = @()
            "packageFamilyName" = "$($packageShortName)_$($packageFamily)"
            "packageName" = $packageShortName
            "packageRelativePath" = "\MSIXPackages\$($packageFolder.Name)"
            "version" = $packageVersion
        }
    }
}catch{
    Write-Output $_
    closeCIMSession
    Throw
}

Write-Output "Manifest parsed, sending API PUT to V1 Hostpool:"
Write-Output $apiPostData

#send the actual API request to register the package in the hostpool using the pipeline serviceprincipal
try{
    $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
    $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://management.azure.com")          
    Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$((get-azcontext).Subscription.id)/resourcegroups/rg-common-$($environment)-weeu-01/providers/Microsoft.DesktopVirtualization/hostPools/vdhp-common-$($environment)-weeu-01/msixPackages/$($packageFolder.Name)?api-version=2021-07-12" -Method PUT -UseBasicParsing -ContentType "application/json" -Body ($apiPostData | convertto-json -Depth 15) -Headers @{"Authorization"="Bearer $($token.AccessToken)"} -ErrorAction Stop
}catch{
    Write-Output $_
    closeCIMSession
    Throw
}

closeCIMSession

Write-Output "Parsing descriptions and friendlynames from param file as available"

#grab the param file for the remoteapp and overwrite all relevant fields based on the metadata of the appxpackage
$json = Get-Content $paramFilePath | convertfrom-json
$preMappedApps = $json.parameters.apps.value
$json.parameters.apps.value = @()
Write-Output "Overwriting parameters in this remoteapps' param file $paramFilePath"

foreach($app in $packageApplications){
    $matchedApp = $Null
    $matchedApp = $preMappedApps | where{$_.appName.value -eq $app.appId}
    $json.parameters.apps.value += [PSCustomObject]@{
        "appName" = $app.appId
        "appDescription" = if($matchedApp -and $matchedApp.appDescription.value){$matchedApp.appDescription.value}else{$app.description}
        "appFriendlyName" = if($matchedApp -and $matchedApp.appFriendlyName.value){$matchedApp.appFriendlyName.value}else{$app.friendlyName}
        "showInPortal" = if($matchedApp -and $matchedApp.showInPortal.value){$matchedApp.showInPortal.value}else{$True}
        "iconIndex" = if($matchedApp){$matchedApp.iconIndex.value}else{0}
        "msixPackageFamilyName" = "$($packageShortName)_$($packageFamily)"
        "msixPackageApplicationId" = $app.appId
    }
}

$json | ConvertTo-json -Depth 20 | Set-Content $paramFilePath

Write-Output "Param file updated and ready for deployment autopickup: $paramFilePath"

Write-Output "Script completed"