Function New-ExOPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    

    Param(
        [Parameter(Mandatory=$true)]$path,
        [Parameter(Mandatory=$true)]$type,
        [Parameter(Mandatory=$false)]$principalEntraId="",
        [Parameter(Mandatory=$false)]$principalUpn="",
        [Parameter(Mandatory=$false)]$principalName="",
        [Parameter(Mandatory=$false)]$principalType="",
        [Parameter(Mandatory=$true)]$role,
        [Parameter(Mandatory=$true)]$through,
        [Parameter(Mandatory=$true)]$kind
    )

    if($global:octo.currentUser.userPrincipalName -eq $principalUpn -and !$global:octo.includeCurrentUser){
        Write-Verbose "Skipping permission $($role) scoped at $path for $($principalUpn) as it is the auditor account"
        return $Null
    }

    $Permission = [PSCustomObject]@{
        "Path" = $path
        "Type" = $type
        "PrincipalEntraId" = $principalEntraId
        "PrincipalUpn" = $principalUpn
        "PrincipalName" = $principalName
        "PrincipalType" = $principalType
        "Role" = $role
        "Through" = $through
        "Kind" = $kind      
    }

    if($global:ExOPermissions){
        #loop over entries
        foreach($exoPath in $global:ExOPermissions.GetEnumerator()){
            #entry starts with intended entry
            if($path -contains $exoPath){
                if($global:ExOPermissions.$exoPath -contains $Permission){
                    Write-Verbose "Skipping permission $($role) scoped at $path for $($principalName) as it is already present"
                    return $Null
                }
                foreach($ExistingPermission in $global:ExOPermissions.$exoPath){
                    if($ExistingPermission.Kind -eq $kind -and $ExistingPermission.Through -eq $through -and $ExistingPermission.Type -eq $type){
                        if($ExistingPermission.Role -eq "FullAccess"){
                            Write-Verbose "Skipping permission $($role) scoped at $path for $($principalName) as FullAccess already present"
                            return $Null
                        }
                        if($ExistingPermission.Role -eq $role){
                            if($principalUpn -and $ExistingPermission.PrincipalUpn -eq $principalUpn){
                                Write-Verbose "Skipping permission $($role) scoped at $path for $($principalUpn) as it is already present"
                                return $Null
                            }
                            if($principalEntraId -and $ExistingPermission.PrincipalEntraId -eq $principalEntraId){
                                Write-Verbose "Skipping permission $($role) scoped at $path for $($principalEntraId) as it is already present"
                                return $Null
                            }
                            if($principalName -and $ExistingPermission.PrincipalName -eq $principalName){
                                Write-Verbose "Skipping permission $($role) scoped at $path for $($principalName) as it is already present"
                                return $Null
                            }
                        }
                    }
                }
            }
        }
    }
    Write-Verbose "Adding permission $($role) scoped at $path for $($principalName)"
    if(!$global:ExOPermissions.$path){
        $global:ExOPermissions.$path = @()
    }
    $global:ExOPermissions.$path += $Permission
}
