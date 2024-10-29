Function New-PermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$Permission,
        [Parameter(Mandatory=$true)]$Path
    )

    if($Permission.Identity -in ("SHAREPOINT\system")){
        Write-Verbose "Skipping permission $($Permission.Identity) as it is a system account"
        return $Null
    }

    if($global:ignoreCurrentUser -and $Permission.Email -eq $global:currentUser.userPrincipalName){
        Write-Verbose "Skipping permission $($Permission.Email) as it is the auditor account"
        return $Null
    }

    foreach($folder in $global:permissions.Keys){
        if($Path.Contains($folder)){
            if($global:permissions.$folder.Identity -Contains $Permission.Identity){
                #Identity known, check if existing known permission are different
                if($Permission.Permission -in $($global:permissions.$folder | Where-Object { $_.Identity -eq $Permission.Identity }).Permission){
                    Write-Verbose "Not adding permission $($Permission.Identity) to $Path as it is already present with the same permission"
                    return $Null
                }
            }
        }
    }

    if(!($global:permissions.Keys -Contains $Path)){
        $global:permissions.$($Path) = @()
    }

    Write-Verbose "Adding permission $($Permission.Permission) for $($Permission.Identity) to $Path"
    $global:permissions.$($Path) += $Permission    
}
