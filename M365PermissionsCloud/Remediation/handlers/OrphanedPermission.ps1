#Requires -Version 7.0
<#
    Orphaned permissions: access still granted to a principal that no longer exists in Entra.

    Three shapes, because the permission lives wherever it was granted:
      Azure        a role assignment whose principal is gone, which the portal shows as "Identity not found"
      SharePoint   a permission on a file or folder for a user who has been deleted
      Entra        a directory role or an application permission held by a deleted service principal

    Every one of them is re-checked against Entra before it is planned. The scan can be hours old and a
    deleted principal can be restored within thirty days, in which case the permission is live again and
    removing it would be a change nobody asked for.
#>

function Resolve-M365PAzureScope {
    <#
        .SYNOPSIS
        The ARM scope a scan targetPath refers to.

        .DESCRIPTION
        The scanner records Azure targets as /{subscription}/{resourceGroup}/{provider}/{type}/{name},
        dropping the ARM keywords. This puts them back, because ARM needs the full resource id to list
        or delete a role assignment at that scope.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Item)

    $segments = @("$($Item.targetPath)".Trim("/") -split "/" | Where-Object { $_ })
    if ($segments.Count -eq 0) { Throw "Empty Azure targetPath" }

    $scope = "/subscriptions/$($segments[0])"
    if ($segments.Count -ge 2) { $scope = "$scope/resourceGroups/$($segments[1])" }
    if ($segments.Count -ge 3) { $scope = "$scope/providers/$(($segments | Select-Object -Skip 2) -join '/')" }

    return $scope
}

Register-M365PRemediation -Reason "Orphaned permission" `
    -Categories @("Azure", "Sharepoint", "Onedrive", "Teams", "O365Group", "Entra", "Admins") `
    -RequiredScopes @("Directory.Read.All", "RoleManagement.ReadWrite.Directory", "AppRoleAssignment.ReadWrite.All", "Files.ReadWrite.All") `
    -RequiredFields @("targetPath", "principalId") `
    -Description "Removes access that is still granted to a deleted principal" `
    -Plan {
    Param($item, $context)

    #the scan said this principal is gone. Confirm it, because a restore inside the thirty day window
    #makes the permission live again and this would then be removing working access.
    if ("$($item.principalId)" -notmatch "^[0-9a-fA-F-]{36}$") {
        Add-M365PSkip -Item $item -Why "principalId is not an object id, so whether the principal still exists cannot be confirmed"
        return
    }
    if (Test-M365PDirectoryObjectExists -ObjectId $item.principalId) {
        Add-M365PSkip -Item $item -Why "$($item.principalName ?? $item.principalId) exists in Entra again, so this is no longer an orphan. Re-scan to clear the finding."
        return
    }

    switch ($item.category) {
        "Azure" {
            $scope = Resolve-M365PAzureScope -Item $item
            $assignments = @(Invoke-M365PCall -Audience "arm" -Uri "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()")
            $mine = @($assignments | Where-Object { $_.properties.principalId -eq $item.principalId })
            if ($mine.Count -eq 0) { Add-M365PSkip -Item $item -Why "No role assignment for that principal at $scope any more"; return }

            foreach ($assignment in $mine) {
                $roleName = "$($assignment.properties.roleDefinitionId)".Split("/")[-1]
                #a role assignment for a principal that no longer exists cannot be put back: ARM refuses
                #to create one for an unknown object id, so this is recorded rather than offered as undo
                New-M365PAction -Item $item `
                    -Summary "Delete the orphaned Azure role assignment at $scope" `
                    -Target $scope `
                    -Detail @("principal: $($item.principalName ?? $item.principalId) (deleted)", "role definition: $roleName", "assignment: $($assignment.name)") `
                    -State @{ Uri = "https://management.azure.com$($assignment.id)?api-version=2022-04-01" } `
                    -Apply { Param($action, $context) $Null = Invoke-M365PCall -Audience "arm" -Uri $action.State.Uri -Method "DELETE" }
            }
        }
        { $_ -in @("Sharepoint", "Onedrive", "Teams", "O365Group") } {
            #same two routes as the sharing handlers, for the same reason: a borrowed session can reach
            #SharePoint but not Graph's sharing endpoints
            if ($context.UseGraphSharing) {
                $resolved = Resolve-M365PDriveItem -Item $item
                if (!$resolved) { Add-M365PSkip -Item $item -Why "This is a site level finding, which needs the SharePoint site handler"; return }

                $mine = @($resolved.Permissions | Where-Object { Test-M365PPermissionMatchesPrincipal -Permission $_ -Item $item })
                if ($mine.Count -eq 0) { Add-M365PSkip -Item $item -Why "No permission for that principal on this item any more"; return }

                foreach ($permission in $mine) {
                    New-M365PAction -Item $item `
                        -Summary "Remove the deleted user's permission from $($resolved.Name)" `
                        -Target $resolved.WebUrl `
                        -Detail @("removing: $(Get-M365PPermissionDescription -Permission $permission)", "principal: $($item.principalName ?? $item.principalId) (deleted)") `
                        -State @{ Uri = "https://graph.microsoft.com/v1.0/drives/$($resolved.DriveId)/items/$($resolved.ItemId)/permissions/$($permission.id)" } `
                        -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "DELETE" }
                }
                return
            }

            $resolved = Resolve-M365PSharePointItem -Item $item
            if (!$resolved) { Add-M365PSkip -Item $item -Why "This is a site level finding, which needs the SharePoint site handler"; return }

            $sharing = Get-M365PSharingInformation -Resolved $resolved
            $mine = @($sharing.Principals | Where-Object { Test-M365PPrincipalMatchesFinding -Principal $_ -Item $item })
            if ($mine.Count -eq 0) { Add-M365PSkip -Item $item -Why "No permission for that principal on this item any more"; return }

            foreach ($principal in $mine) {
                New-M365PRemoveRoleAssignmentAction -Item $item -Resolved $resolved -Principal $principal `
                    -Detail @("principal: $($item.principalName ?? $item.principalId) (deleted from Entra)") `
                    -Summary "Remove the deleted principal's grant from $($resolved.Name)"
            }
        }
        default {
            #Entra and Admins: a deleted service principal can still hold a directory role and application
            #permissions. Both are addressed by the principal, so neither needs the target path.
            $acted = $False

            $roleAssignments = @()
            try {
                $roleAssignments = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($item.principalId)'&`$expand=roleDefinition")
            }catch {
                Add-M365PSkip -Item $item -Why "Could not read directory role assignments: $($_.Exception.Message)"
            }
            foreach ($assignment in $roleAssignments) {
                $acted = $True
                New-M365PAction -Item $item `
                    -Summary "Remove the directory role $($assignment.roleDefinition.displayName) from the deleted principal" `
                    -Target "$($item.principalName ?? $item.principalId)" `
                    -Detail @("assignment: $($assignment.id)") `
                    -State @{ Uri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments/$($assignment.id)" } `
                    -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "DELETE" }
            }

            $appRoleAssignments = @()
            try {
                $appRoleAssignments = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($item.principalId)/appRoleAssignments")
            }catch {
                #a hard deleted service principal has no object to read assignments from, which is fine:
                #its assignments went with it and the finding clears on the next scan
                Write-M365PDetail "No application permissions readable for $($item.principalId), it may already be fully deleted"
            }
            foreach ($assignment in $appRoleAssignments) {
                $acted = $True
                New-M365PAction -Item $item `
                    -Summary "Remove an application permission on $($assignment.resourceDisplayName) from the deleted principal" `
                    -Target "$($item.principalName ?? $item.principalId)" `
                    -Detail @("assignment: $($assignment.id)") `
                    -State @{ Uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($item.principalId)/appRoleAssignments/$($assignment.id)" } `
                    -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "DELETE" }
            }

            if (!$acted) {
                Add-M365PSkip -Item $item -Why "Nothing left to remove for that principal. It is fully deleted, so the finding clears on the next scan."
            }
        }
    }
}
