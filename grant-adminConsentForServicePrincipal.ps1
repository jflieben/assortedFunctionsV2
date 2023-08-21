<#
    .SYNOPSIS
    Enforces / syncs all permissions from a given multi-tenant application in a given tenant into it's representation (service principal) in another tenant.
    Useful for MSP's / CSP's / App Publishers. 
    Requires DelegatedPermissionGrant.ReadWrite.All and AppRoleAssignment.ReadWrite.All Graph Permissions.
    New-GraphGetRequest and New-GraphPostRequest functions not included.

    .NOTES
    author:     Jos Lieben / jos@lieben.nu
    copyright:  Lieben Consultancy, free to (re)use, keep headers intact
    disclaimer: https://www.lieben.nu/liebensraum/contact/#disclaimer-and-copyright
    site:       https://www.lieben.nu
    Created:    29/05/2023
    Updated:    See Gitlab
#>

$sourceTenantId = "GUID-OR-DOMAIN"
$targetTenantId = "GUID-OR-DOMAIN"
$sourceSpnId = "GUID"
$sourceSpnAppId = "GUID"
$requiredResourceAccess = (New-GraphGetRequest -tenantid $sourceTenantId -uri "https://graph.microsoft.com/v1.0/applications/$($sourceSpnId)").requiredResourceAccess

$oauth2Perms = (New-GraphGetRequest -tenantid $targetTenantId -uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($sourceSpnAppId)')/oauth2PermissionGrants")
$spn = (New-GraphGetRequest -tenantid $targetTenantId -uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($sourceSpnAppId)')")
$appRoles = (New-GraphGetRequest -tenantid $targetTenantId -uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($sourceSpnAppId)')/appRoleAssignments")

foreach($resource in $requiredResourceAccess){
    $scopes = $Null; $scopes = $resource.resourceAccess | where{$_.type -eq "Scope"}
    $roles = $Null; $roles = $resource.resourceAccess | where{$_.type -eq "Role"}
    $targetSpn = (New-GraphGetRequest -tenantid $targetTenantId -uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($resource.resourceAppId)')")

    #OAUTH2 (delegated) permissions
    if($scopes){
        $scopeArray = $Null;
        foreach($scope in $scopes){
            $scopeArray += "$(($targetSpn.oauth2PermissionScopes | Where-Object {$_.id -eq $scope.id}).value) "
        }

        $existingPermission = $oauth2Perms | Where-Object {$_.resourceId -eq $targetSpn.id -and $_.clientId -eq $spn.id}

        $body = @{
            "clientId"= $spn.id
            "consentType"= "AllPrincipals"
            "resourceId" = $targetSpn.id
            "scope" = $scopeArray.Trim()
        }

        if($existingPermission){
            $method = "PATCH"
            $uri = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existingPermission.id)"
        }else{
            $method = "POST"
            $uri = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants"
        }

        New-GraphPOSTRequest -type $method -tenantid $targetTenantId -uri $uri -body ($body | convertto-json -depth 15)
    }

    #Roles
    if($roles){
        foreach($role in $roles){
            $existingPermission = $Null; $existingPermission = $appRoles | Where-Object {$_.appRoleId -eq $role.id -and $_.principalId -eq $spn.id -and $_.resourceId -eq $targetSpn.id}
            if(!$existingPermission){
                $body = @{
                    "principalId" = $spn.id
                    "resourceId" = $targetSpn.id
                    "appRoleId"= $role.id                 
                }
                New-GraphPOSTRequest -tenantid $targetTenantId -uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($resource.resourceAppId)')/appRoleAssignments" -body ($body | convertto-json -depth 15)    
            }
        }
    }
}