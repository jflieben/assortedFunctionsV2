#Requires -Version 7.0
<#
    Application privilege remediation: what an application or managed identity is allowed to do.

    Reasons handled:
      Privileged Graph app role          an application permission that reaches the whole tenant
      Application holds an admin role    a directory role held by an application rather than a person

    Both are reversible: the assignment is recreated from the ids in the rollback file.

    The product's own identities are never touched. Removing the scanner's Graph permission would leave
    a product that can no longer see the finding it was asked to fix, and removing the portal's would
    lock everybody out of the thing showing the advice. Those are checked by application id, by object
    id and by name, and the caller is expected to pass the deployment's own ids in as well.
#>

function Resolve-M365PServicePrincipal {
    <#
        .SYNOPSIS
        The service principal a finding is about, with the fields needed to judge whether to touch it.
    #>
    Param([Parameter(Mandatory = $true)][String]$ObjectId)

    $key = "spn:$ObjectId"
    if ($script:M365PCache.ContainsKey($key)) { return $script:M365PCache[$key] }

    $spn = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ObjectId" -NoPaging) | Select-Object -First 1
    $script:M365PCache[$key] = $spn
    return $spn
}

function Test-M365PHolderIsSafeToChange {
    <#
        .SYNOPSIS
        Whether the application in a finding may be changed, recording the reason when it may not.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Item, [Object]$Spn)

    if (Test-M365PIsProtected -AppId $Spn.appId -DisplayName $Spn.displayName -ObjectId $Spn.id) {
        Add-M365PSkip -Item $Item -Why "$($Spn.displayName) belongs to M365Permissions itself or was listed as protected, so its access is left alone"
        return $False
    }
    return $True
}

Register-M365PRemediation -Reason "Privileged Graph app role" `
    -Categories @("Entra") `
    -RequiredScopes @("AppRoleAssignment.ReadWrite.All", "Application.Read.All") `
    -RequiredFields @("principalId", "role") `
    -Description "Removes a tenant wide application permission from an application" `
    -Plan {
    Param($item, $context)

    $spn = $Null
    try { $spn = Resolve-M365PServicePrincipal -ObjectId $item.principalId }
    catch { Add-M365PSkip -Item $item -Why "Could not read the application: $($_.Exception.Message)"; return }
    if (!$spn.id) { Add-M365PSkip -Item $item -Why "No service principal with id $($item.principalId) any more"; return }
    if (!(Test-M365PHolderIsSafeToChange -Item $item -Spn $spn)) { return }

    $assignments = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments")
    if ($assignments.Count -eq 0) { Add-M365PSkip -Item $item -Why "$($spn.displayName) holds no application permissions any more"; return }

    #the finding names the permission by value (Sites.FullControl.All); the assignment carries the id of
    #the app role on the API's own service principal, so the API has to be read to map one to the other
    $matched = 0
    foreach ($resourceId in (@($assignments.resourceId) | Select-Object -Unique)) {
        $resource = $Null
        try { $resource = Resolve-M365PServicePrincipal -ObjectId $resourceId } catch { continue }

        $wanted = @($resource.appRoles | Where-Object { $_.value -eq $item.role })
        if ($wanted.Count -eq 0) { continue }

        foreach ($assignment in @($assignments | Where-Object { $_.resourceId -eq $resourceId -and $_.appRoleId -in @($wanted.id) })) {
            $matched++
            New-M365PAction -Item $item `
                -Summary "Remove $($item.role) on $($resource.displayName) from $($spn.displayName)" `
                -Target "$($spn.displayName) ($($spn.appId))" `
                -Detail @("assignment: $($assignment.id)", "this application keeps every other permission it holds") `
                -State @{ Uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments/$($assignment.id)" } `
                -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "DELETE" } `
                -Undo @{
                    type = "postJson"
                    uri  = "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments"
                    body = @{ principalId = $spn.id; resourceId = $resourceId; appRoleId = $assignment.appRoleId }
                }
        }
    }

    if ($matched -eq 0) {
        Add-M365PSkip -Item $item -Why "$($spn.displayName) no longer holds $($item.role)"
    }
}

Register-M365PRemediation -Reason "Application holds an admin role" `
    -Categories @("Admins", "Azure") `
    -RequiredScopes @("RoleManagement.ReadWrite.Directory", "Application.Read.All") `
    -RequiredFields @("principalId", "role") `
    -Description "Removes a directory role from an application" `
    -Plan {
    Param($item, $context)

    #Exchange and Intune have their own role systems, which Graph's directory role assignments do not
    #cover. Saying so is better than reporting success on a role that is still in place.
    if ("$($item.targetType)" -in @("ExchangeBuiltInRole", "IntuneBuiltInRole", "IntuneCustomRole")) {
        Add-M365PSkip -Item $item -Why "$($item.targetType) is managed by Exchange or Intune, not by Entra, so it cannot be removed here. Use the Exchange or Intune admin centre."
        return
    }
    if ("$($item.category)" -eq "Azure") {
        Add-M365PSkip -Item $item -Why "This is an Azure RBAC assignment rather than a directory role. Remove it in the Azure portal, or let a future version of this script handle it."
        return
    }

    $spn = $Null
    try { $spn = Resolve-M365PServicePrincipal -ObjectId $item.principalId }
    catch { Add-M365PSkip -Item $item -Why "Could not read the application: $($_.Exception.Message)"; return }
    if (!$spn.id) { Add-M365PSkip -Item $item -Why "No service principal with id $($item.principalId) any more"; return }
    if (!(Test-M365PHolderIsSafeToChange -Item $item -Spn $spn)) { return }

    $assignments = @()
    try {
        $assignments = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($spn.id)'&`$expand=roleDefinition")
    }catch {
        Add-M365PSkip -Item $item -Why "Could not read directory role assignments: $($_.Exception.Message)"
        return
    }

    $mine = @($assignments | Where-Object { "$($_.roleDefinition.displayName)" -eq "$($item.role)" })
    if ($mine.Count -eq 0) { Add-M365PSkip -Item $item -Why "$($spn.displayName) no longer holds the $($item.role) role"; return }

    foreach ($assignment in $mine) {
        New-M365PAction -Item $item `
            -Summary "Remove the $($item.role) role from $($spn.displayName)" `
            -Target "$($spn.displayName) ($($spn.appId))" `
            -Detail @("assignment: $($assignment.id)", "scope: $(if($assignment.directoryScopeId){ $assignment.directoryScopeId }else{ '/' })") `
            -State @{ Uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments/$($assignment.id)" } `
            -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "DELETE" } `
            -Undo @{
                type = "postJson"
                uri  = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments"
                body = @{
                    principalId      = $spn.id
                    roleDefinitionId = $assignment.roleDefinitionId
                    directoryScopeId = $(if ($assignment.directoryScopeId) { $assignment.directoryScopeId } else { "/" })
                }
            }
    }
}
