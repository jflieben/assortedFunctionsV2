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
        [Parameter(Mandatory=$false)]$principalUpn="Unknown",
        [Parameter(Mandatory=$false)]$principalName="Unknown",
        [Parameter(Mandatory=$false)]$principalType="Unknown",
        [Parameter(Mandatory=$false)]$roleDefinitionName="Legacy Role",
        [Parameter(Mandatory=$false)]$startDateTime,
        [Parameter(Mandatory=$false)]$endDateTime
    )

    if($currentUser.userPrincipalName -eq $principalUpn){
        Write-Verbose "Skipping permission $($roleDefinitionName) scoped at $path for $($principalUpn) as it is the auditor account"
        return $Null
    }
    Write-Verbose "Adding permission $($roleDefinitionName) scoped at $path for $($principalUpn)"
    if(!$global:EntraPermissions.$path){
        $global:EntraPermissions.$path = @()
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
        startDateTime = $startDateTime
        endDateTime = $endDateTime
    }
}
