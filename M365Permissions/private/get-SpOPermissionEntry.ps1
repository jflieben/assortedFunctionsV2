function get-SpOPermissionEntry{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$entity,
        [Parameter(Mandatory=$true)]$object,
        [Parameter(Mandatory=$true)]$permission,
        $through,
        $parent,
        $linkCreationDate,
        $linkExpirationDate
    )
    
    $name = $entity.Title
    $type = $entity.PrincipalType 
    $objectType = $object.Type ? $object.Type : "root"
    
    if([string]::IsNullOrEmpty($parent)){
        $parent = ""
    }

    if([string]::IsNullOrEmpty($linkCreationDate)){
        $linkCreationDate = ""
    }

    if([string]::IsNullOrEmpty($linkExpirationDate)){
        $linkExpirationDate = ""
    }    

    return [PSCustomObject]@{
        "Object" = $objectType
        "Name" = $name
        "Identity" = $entity.LoginName
        "Email" = $entity.Email
        "Type" = $type
        "Permission" = $permission
        "Through" = $through
        "Parent" = $parent
        "LinkCreationDate" = $linkCreationDate
        "LinkExpirationDate" = $linkExpirationDate
    }
}