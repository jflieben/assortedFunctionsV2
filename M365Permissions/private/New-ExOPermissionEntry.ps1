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

    if($global:currentUser.userPrincipalName -eq $principalUpn -and !$global:includeCurrentUser){
        Write-Verbose "Skipping permission $($roleDefinitionName) scoped at $path for $($principalUpn) as it is the auditor account"
        return $Null
    }

    Write-Verbose "Adding permission $($role) scoped at $path for $($principalUpn)"
    if(!$global:ExOPermissions.$path){
        $global:ExOPermissions.$path = @()
    }
    $global:ExOPermissions.$path += [PSCustomObject]@{
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
}
