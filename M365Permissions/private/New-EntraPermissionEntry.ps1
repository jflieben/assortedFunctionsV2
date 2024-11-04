Function New-EntraPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$path,
        [Parameter(Mandatory=$true)]$type,
        [Parameter(Mandatory=$true)]$principalId,
        [Parameter(Mandatory=$true)]$roleDefinitionId,
        [Parameter(Mandatory=$false)]$principalUpn,
        [Parameter(Mandatory=$true)]$principalName,
        [Parameter(Mandatory=$true)]$principalType,
        [Parameter(Mandatory=$false)]$roleDefinitionName
    )

    if($currentUser.userPrincipalName -eq $principalUpn){
        Write-Verbose "Skipping permission $($roleDefinitionName) scoped at $path for $($principalUpn) as it is the auditor account"
        return $Null
    }
    Write-Verbose "Adding permission $($roleDefinitionName) scoped at $path for $($principalUpn)"
    if(!$global:EntraPermissions.$path){
        $global:EntraPermissions.$path = @()
    }

    if($roleDefinitionName -eq $null){
        $roleDefinitionName = "Legacy Role"
    }

    $global:EntraPermissions.$path += [PSCustomObject]@{
        scope = $path
        type = $type
        principalId = $principalId
        roleDefinitionId = $roleDefinitionId
        principalUpn = $principalUpn
        principalName = $principalName
        principalType = $principalType
        roleDefinitionName = $roleDefinitionName
    }
}
