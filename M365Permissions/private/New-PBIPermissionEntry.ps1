Function New-PBIPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>    
    Param(
        [Parameter(Mandatory=$true)]$path,
        [Parameter(Mandatory=$true)]$type,
        [Parameter(Mandatory=$true)]$principalId,
        [Parameter(Mandatory=$false)]$principalUpn="Unknown",
        [Parameter(Mandatory=$false)]$principalName="Unknown",
        [Parameter(Mandatory=$false)]$principalType="Unknown",
        [Parameter(Mandatory=$false)]$through="Direct",
        [Parameter(Mandatory=$false)]$parent = "N/A",
        [Parameter(Mandatory=$false)]$roleDefinitionName="Unknown",
        [Parameter(Mandatory=$false)]$created="Unknown",
        [Parameter(Mandatory=$false)]$modified="Unknown"
    )

    if($global:octo.currentUser.userPrincipalName -eq $principalUpn -and !$global:octo.includeCurrentUser){
        Write-Verbose "Skipping permission $($roleDefinitionName) scoped at $path for $($principalUpn) as it is the auditor account"
        return $Null
    }

    $principalType = $principalType.Replace("User (Member)","Internal User").Replace("User (Guest)","External User")

    Write-Verbose "Adding permission $($roleDefinitionName) scoped at $path for $($principalUpn)"
    if(!$global:PBIPermissions.$path){
        $global:PBIPermissions.$path = @()
    }
    
    $global:PBIPermissions.$path += [PSCustomObject]@{
        scope = $path
        type = $type
        principalUpn = $principalUpn
        roleDefinitionName = $roleDefinitionName
        principalName = $principalName
        principalType = $principalType        
        principalId = $principalId
        through = $through
        parent = $parent      
        created = $created
        modified = $modified  
    }
}
