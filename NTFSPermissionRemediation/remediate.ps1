<#
    .SYNOPSIS
    This script sets NTFS permissions to match the desired settings as defined on line 20

    .NOTES
    filename: detect-securebootStatus.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
#>

$FolderPath = "c:\HP\SYSTEM"

# Check folder
if (!(Test-Path -Path $FolderPath)) {
    New-Item -Path $FolderPath -ItemType Directory -Force | Out-Null
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

$needsUpdate = $false
$acl = Get-Acl -Path $FolderPath

# Check if SYSTEM is the owner
$currentOwner = $acl.Owner
if ($currentOwner -ne "NT AUTHORITY\SYSTEM") {
    Write-Host "Changing owner to NT AUTHORITY\SYSTEM"
    $acl.SetOwner([System.Security.Principal.NTAccount]"NT AUTHORITY\SYSTEM")
    $needsUpdate = $true
}

# Check if inheritance is enabled
if ($acl.AreAccessRulesProtected -eq $false) {
    Write-Host "Disabling inheritance and removing inherited permissions"
    $acl.SetAccessRuleProtection($true, $false)
    $needsUpdate = $true
}

# Check if the ACL matches the desired rules
$currentAllowed = $acl.Access | Where-Object { $_.AccessControlType -eq $allow }
foreach ($permission in $currentAllowed) {
    $match = $desiredPermissions | Where-Object { 
        $_.Identity -eq $permission.IdentityReference -and 
        ($permission.FileSystemRights -band $_.Rights) -eq $_.Rights
    }

    if (-not $match) {
        Write-Host "Removing unwanted permission: $($permission.IdentityReference)"
        $acl.RemoveAccessRule($permission)
        $needsUpdate = $true
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
        Write-Host "Adding missing permission for: $($desired.Identity)"
        $newRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $desired.Identity, $desired.Rights, $inheritanceFlags, $propagationFlags, $allow)
        $acl.AddAccessRule($newRule)
        $needsUpdate = $true
    }
}

# Apply if needed
if ($needsUpdate) {
    Write-Host "Applying updated permissions to $FolderPath"
    Set-Acl -Path $FolderPath -AclObject $acl
} else {
    Write-Host "No changes needed. Permissions are already correct."
}

Exit 0