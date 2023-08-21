Function invoke-installOrUpdatePSModule{
    [CmdletBinding()]
    Param(
        [String][Parameter(Mandatory=$true)]$moduleName,
        [String]$minVersion
    )
    $nuGet = get-packageprovider -Name NuGet
    if($nuGet.Version -lt 2.8.5.201){
        Install-PackageProvider -Name NuGet -Force -Confirm:$False
    }
    $curVer = Get-Module -ListAvailable -Name $moduleName | sort-object Version -Descending | select-object -First 1

    if (-not($curVer)) {
        Write-Verbose "$moduleName not installed, installing latest version..."
        Install-Module $moduleName -SkipPublisherCheck -Force -AllowClobber -Confirm:$False
    }else{
        if($minVersion -and $curVer.Version -lt $minVersion){
            Write-Verbose "$moduleName found but needs to be updated"
            Update-Module -Name $moduleName -Force -Confirm:$False
        }else{
            Write-Verbose "$moduleName found and update is not needed"
        }
    }

    Import-Module $moduleName
}