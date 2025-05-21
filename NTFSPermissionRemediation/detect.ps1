<#
    .SYNOPSIS
    This script detects if NTFS permissions match the desired settings as defined on line 21

    .NOTES
    filename: detect.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
#>

$FolderPath = "c:\HP\SYSTEM"

# Check folder
if (!(Test-Path -Path $FolderPath)) {
    Write-Error "The path '$FolderPath' does not exist."
    exit 1
}

# Define the NTFS permissions you want on the folder above
$desiredPermissions = @(
    @{ Identity = "BUILTIN\Administrators"; Rights = [System.Security.AccessControl.FileSystemRights]::FullControl },
    @{ Identity = "NT AUTHORITY\SYSTEM";     Rights = [System.Security.AccessControl.FileSystemRights]::FullControl },
    @{ Identity = "BUILTIN\Users";           Rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute }
)

$inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit, [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
$allow = [System.Security.AccessControl.AccessControlType]::Allow

$acl = Get-Acl -Path $FolderPath

# Check if SYSTEM is the owner
$currentOwner = $acl.Owner
if ($currentOwner -ne "NT AUTHORITY\SYSTEM") {
    Write-Host "Owner should be NT AUTHORITY\SYSTEM"
    Exit 1
}

# Check if inheritance is enabled
if ($acl.AreAccessRulesProtected -eq $false) {
    Write-Host "Inheritance is enabled"
    Exit 1
}

# Check if the ACL matches the desired rules
$currentAllowed = $acl.Access | Where-Object { $_.AccessControlType -eq $allow }
foreach ($permission in $currentAllowed) {
    $match = $desiredPermissions | Where-Object { 
        $_.Identity -eq $permission.IdentityReference -and 
        ($permission.FileSystemRights -band $_.Rights) -eq $_.Rights
    }

    if (-not $match) {
        Write-Host "Detect unwanted permission: $($permission.IdentityReference)"
        Exit 1
    }
}

# Check if the desired permissions are missing
foreach ($desired in $desiredPermissions) {
    $exists = $false
    foreach ($permission in $acl.Access) {
        if ($permission.IdentityReference -eq $desired.Identity -and 
            ($permission.FileSystemRights -band $desired.Rights) -eq $desired.Rights -and 
            $permission.AccessControlType -eq $allow) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        Write-Host "Missing permission for: $($desired.Identity)"
        Exit 1
    }
}

Exit 0