#Requires -Version 7.0
<#
    Sharing related remediation: everything the scanner reports about who can reach a file, folder or
    list item in SharePoint, OneDrive, Teams or a Microsoft 365 group.

    Two routes, picked per run by what the sign in can actually do, and always stated in the plan:

      SharePoint   the default. A borrowed Azure CLI or Azure PowerShell session can get a SharePoint
                   token with user_impersonation, so no interactive sign in is needed at all. SharePoint
                   removes a sharing link rather than adjusting it, so these actions delete.

      Graph        used when the Graph token carries Sites or Files write scopes, which only happens
                   after an interactive sign in or with a consented application. Graph can expire a link
                   or downgrade it in place, which is gentler and reversible.

    Reasons handled:
      Anonymous link with write access    Graph: downgrade to view. SharePoint: delete the edit link
      Anonymous link never expires        Graph: set an expiry.     SharePoint: delete the link
      Internal oversharing                Graph: downgrade to view. SharePoint: delete the link or grant
      Sharing link older than two years   delete, on either route, since age is the whole finding
      External oversharing                delete the link or the grant, on either route

    A finding on a site or site collection itself has no list item, so it is reported as needing the
    site level handler rather than acted on here.
#>

$script:M365PWriteRoles = @("write", "owner", "sp.full control", "fullcontrol", "edit", "manage")

function Get-M365PSharingTarget {
    <#
        .SYNOPSIS
        The item a finding points at, resolved on whichever route this run is using.

        .DESCRIPTION
        Returns $null for a site level finding, which is the signal to skip with an explanation.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][Object]$Context
    )

    if ($Context.UseGraphSharing) {
        $resolved = Resolve-M365PDriveItem -Item $Item
        if (!$resolved) { return $Null }
        return [PSCustomObject]@{ Route = "graph"; Resolved = $resolved; Permissions = @($resolved.Permissions) }
    }

    $resolved = Resolve-M365PSharePointItem -Item $Item
    if (!$resolved) { return $Null }
    $sharing = Get-M365PSharingInformation -Resolved $resolved
    return [PSCustomObject]@{ Route = "sharepoint"; Resolved = $resolved; Links = @($sharing.Links); Principals = @($sharing.Principals) }
}

function Test-M365PPrincipalMatchesFinding {
    <#
        .SYNOPSIS
        Whether a SharePoint principal from GetSharingInformation is the one a finding is about.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Principal, [Parameter(Mandatory = $true)][Object]$Item)

    $wanted = @($Item.principalId, $Item.principalName, $Item.principalUpn, $Item.principalSysId | Where-Object { $_ })
    $candidates = @($Principal.principal.id, $Principal.principal.loginName, $Principal.principal.email,
        $Principal.principal.userPrincipalName, $Principal.principal.name, $Principal.id) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        foreach ($target in $wanted) {
            if ("$candidate" -eq "$target" -or "$candidate" -like "*$target*") { return $True }
        }
    }
    return $False
}

function New-M365PGraphPermissionPatch {
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][Object]$Resolved,
        [Parameter(Mandatory = $true)][Object]$Permission,
        [Parameter(Mandatory = $true)][Hashtable]$Body,
        [Parameter(Mandatory = $true)][String]$Summary,
        [Parameter(Mandatory = $true)][Hashtable]$UndoBody
    )

    $uri = "https://graph.microsoft.com/v1.0/drives/$($Resolved.DriveId)/items/$($Resolved.ItemId)/permissions/$($Permission.id)"

    return New-M365PAction -Item $Item -Summary $Summary -Target $Resolved.WebUrl `
        -Detail @("currently: $(Get-M365PPermissionDescription -Permission $Permission)") `
        -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "PATCH" -Body $action.State.Body } `
        -State @{ Uri = $uri; Body = $Body } `
        -Undo @{ type = "patchPermission"; uri = $uri; body = $UndoBody }
}

function New-M365PGraphPermissionDelete {
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][Object]$Resolved,
        [Parameter(Mandatory = $true)][Object]$Permission,
        [Parameter(Mandatory = $true)][String]$Summary
    )

    $detail = @("removing: $(Get-M365PPermissionDescription -Permission $Permission)")
    if ($Permission.link.webUrl) { $detail += "link url: $($Permission.link.webUrl)" }
    if ($Permission.roles) { $detail += "roles: $(@($Permission.roles) -join ', ')" }

    return New-M365PAction -Item $Item -Summary $Summary -Target $Resolved.WebUrl -Detail $detail `
        -Apply { Param($action, $context) $Null = Invoke-M365PCall -Uri $action.State.Uri -Method "DELETE" } `
        -State @{ Uri = "https://graph.microsoft.com/v1.0/drives/$($Resolved.DriveId)/items/$($Resolved.ItemId)/permissions/$($Permission.id)" }
}

# ------------------------------------------------------------------------------------------------

Register-M365PRemediation -Reason "Anonymous link with write access" `
    -Categories @("Sharepoint", "Onedrive", "Teams", "O365Group") `
    -RequiredFields @("targetPath") `
    -Description "Takes edit rights off an anyone-with-the-link permission" `
    -Plan {
    Param($item, $context)

    $target = Get-M365PSharingTarget -Item $item -Context $context
    if (!$target) { Add-M365PSkip -Item $item -Why "This is a site level finding, which needs the SharePoint site handler"; return }

    if ($target.Route -eq "graph") {
        $links = @($target.Permissions | Where-Object { $_.link -and $_.link.scope -eq "anonymous" -and @(@($_.roles) | Where-Object { $script:M365PWriteRoles -contains "$_".ToLower() }).Count -gt 0 })
        if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "No anyone-with-the-link permission with edit rights left on this item"; return }
        foreach ($permission in $links) {
            New-M365PGraphPermissionPatch -Item $item -Resolved $target.Resolved -Permission $permission `
                -Body @{ roles = @("read") } -UndoBody @{ roles = @($permission.roles) } `
                -Summary "Downgrade the anyone link on $($target.Resolved.Name) from $(@($permission.roles) -join '+') to read"
        }
        return
    }

    $links = @($target.Links | Where-Object { $_.Anonymous -and $_.IsEdit })
    if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "No anyone-with-the-link permission with edit rights left on this item"; return }
    foreach ($link in $links) {
        New-M365PUnshareLinkAction -Item $item -Resolved $target.Resolved -Link $link `
            -Detail @("SharePoint cannot take edit off a link, so the edit link goes. Share it again as view only if it is still needed.") `
            -Summary "Delete the anyone-with-edit link on $($target.Resolved.Name)"
    }
}

Register-M365PRemediation -Reason "Anonymous link never expires" `
    -Categories @("Sharepoint", "Onedrive", "Teams", "O365Group") `
    -RequiredFields @("targetPath") `
    -Description "Puts an expiry on an anyone-with-the-link permission, or removes it" `
    -Plan {
    Param($item, $context)

    $target = Get-M365PSharingTarget -Item $item -Context $context
    if (!$target) { Add-M365PSkip -Item $item -Why "This is a site level finding, which needs the SharePoint site handler"; return }

    if ($target.Route -eq "graph") {
        $links = @($target.Permissions | Where-Object { $_.link -and $_.link.scope -eq "anonymous" -and !$_.expirationDateTime })
        if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "Every anyone-with-the-link permission on this item already has an expiry"; return }
        $expiry = [DateTime]::UtcNow.AddDays($context.LinkExpiryDays)
        foreach ($permission in $links) {
            New-M365PGraphPermissionPatch -Item $item -Resolved $target.Resolved -Permission $permission `
                -Body @{ expirationDateTime = $expiry.ToString("yyyy-MM-ddTHH:mm:ssZ") } -UndoBody @{ expirationDateTime = $Null } `
                -Summary "Expire the anyone link on $($target.Resolved.Name) on $($expiry.ToString('yyyy-MM-dd')) ($($context.LinkExpiryDays) days)"
        }
        return
    }

    $links = @($target.Links | Where-Object { $_.Anonymous -and !$_.Expiration })
    if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "Every anyone-with-the-link permission on this item already has an expiry"; return }
    foreach ($link in $links) {
        New-M365PUnshareLinkAction -Item $item -Resolved $target.Resolved -Link $link `
            -Detail @("an expiry date can only be set through Graph, which this sign in cannot do, so the link goes instead") `
            -Summary "Delete the never-expiring anyone link on $($target.Resolved.Name)"
    }
}

Register-M365PRemediation -Reason "Internal oversharing" `
    -Categories @("Sharepoint", "Onedrive", "Teams", "O365Group") `
    -RequiredFields @("targetPath") `
    -Description "Takes edit rights off everyone-in-the-organisation access, or removes it" `
    -Plan {
    Param($item, $context)

    $target = Get-M365PSharingTarget -Item $item -Context $context
    if (!$target) { Add-M365PSkip -Item $item -Why "This is a site level finding (a SharePoint group or a security group on the site), which needs the SharePoint site handler"; return }

    if ($target.Route -eq "graph") {
        $candidates = @($target.Permissions | Where-Object {
                (($_.link -and $_.link.scope -eq "organization") -or (Test-M365PPermissionMatchesPrincipal -Permission $_ -Item $item)) -and
                @(@($_.roles) | Where-Object { $script:M365PWriteRoles -contains "$_".ToLower() }).Count -gt 0
            })
        if ($candidates.Count -eq 0) { Add-M365PSkip -Item $item -Why "No organisation wide write access left on this item"; return }
        foreach ($permission in $candidates) {
            New-M365PGraphPermissionPatch -Item $item -Resolved $target.Resolved -Permission $permission `
                -Body @{ roles = @("read") } -UndoBody @{ roles = @($permission.roles) } `
                -Summary "Downgrade $(Get-M365PPermissionDescription -Permission $permission) on $($target.Resolved.Name) to read"
        }
        return
    }

    #a company wide link, and the built in everyone-except-external-users principal granted directly,
    #are the same finding wearing two hats, so both are looked for
    $acted = $False
    foreach ($link in @($target.Links | Where-Object { "$($_.Scope)" -eq "2" -and $_.IsEdit })) {
        $acted = $True
        New-M365PUnshareLinkAction -Item $item -Resolved $target.Resolved -Link $link `
            -Detail @("SharePoint cannot take edit off a link, so the company wide edit link goes") `
            -Summary "Delete the organisation wide edit link on $($target.Resolved.Name)"
    }
    foreach ($principal in @($target.Principals | Where-Object { Test-M365PPrincipalMatchesFinding -Principal $_ -Item $item })) {
        $acted = $True
        New-M365PRemoveRoleAssignmentAction -Item $item -Resolved $target.Resolved -Principal $principal `
            -Detail @("direct grant to $($principal.principal.name ?? $principal.principal.loginName)") `
            -Summary "Remove $($principal.principal.name ?? 'the organisation wide') grant from $($target.Resolved.Name)"
    }
    if (!$acted) { Add-M365PSkip -Item $item -Why "No organisation wide write access left on this item" }
}

Register-M365PRemediation -Reason "Sharing link older than two years" `
    -Categories @("Sharepoint", "Onedrive", "Teams", "O365Group") `
    -RequiredFields @("targetPath") `
    -Description "Deletes a sharing link that has been live for years" `
    -Plan {
    Param($item, $context)

    $target = Get-M365PSharingTarget -Item $item -Context $context
    if (!$target) { Add-M365PSkip -Item $item -Why "This is a site level finding, which needs the SharePoint site handler"; return }

    #the age comes from the scan on the Graph route, which does not report when a link was created.
    #SharePoint does report it, and then the plan can state the real date instead.
    $created = $Null
    foreach ($candidate in @($item.createdDateTime, $item.startDateTime)) {
        if ($candidate) { try { $created = ConvertTo-M365PDate -Value $candidate ; break } catch { $created = $Null } }
    }

    $wantedScope = switch ("$($item.principalId)") {
        "Anonymous" { "anonymous" }
        "AllInternalUsers" { "organization" }
        "AllUsers" { "organization" }
        default { $Null }
    }

    if ($target.Route -eq "graph") {
        $links = @($target.Permissions | Where-Object { $_.link })
        if ($wantedScope) {
            $narrowed = @($links | Where-Object { $_.link.scope -eq $wantedScope })
            if ($narrowed.Count -gt 0) { $links = $narrowed }
        }
        if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "No sharing link left on this item"; return }
        foreach ($permission in $links) {
            $age = if ($created) { "created $($created.ToString('yyyy-MM-dd')) according to the last scan" } else { "creation date not recorded by the scan" }
            $action = New-M365PGraphPermissionDelete -Item $item -Resolved $target.Resolved -Permission $permission `
                -Summary "Delete the $($permission.link.scope) link on $($target.Resolved.Name) ($age)"
            $action.Detail += $age
            if (!$wantedScope -and $links.Count -gt 1) { $action.Detail += "the finding does not say which link, so every link on this item is listed. Send principalId to narrow it." }
            $action
        }
        return
    }

    $links = @($target.Links)
    if ($wantedScope -eq "anonymous") { $links = @($links | Where-Object { $_.Anonymous }) }
    elseif ($wantedScope -eq "organization") { $links = @($links | Where-Object { "$($_.Scope)" -eq "2" }) }
    if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "No sharing link left on this item"; return }

    foreach ($link in $links) {
        $sharePointCreated = "$($link.Raw.Created)"
        $age = if ($sharePointCreated) { "created $($sharePointCreated.Substring(0, [Math]::Min(10, $sharePointCreated.Length)))" }
               elseif ($created) { "created $($created.ToString('yyyy-MM-dd')) according to the last scan" }
               else { "creation date unknown" }
        $detail = @($age)
        if (!$wantedScope -and $links.Count -gt 1) { $detail += "the finding does not say which link, so every link on this item is listed. Send principalId to narrow it." }
        New-M365PUnshareLinkAction -Item $item -Resolved $target.Resolved -Link $link -Detail $detail `
            -Summary "Delete the $(if($link.Anonymous){'anyone'}elseif("$($link.Scope)" -eq '2'){'organisation wide'}else{'specific people'}) link on $($target.Resolved.Name) ($age)"
    }
}

Register-M365PRemediation -Reason "External oversharing" `
    -Categories @("Sharepoint", "Onedrive", "Teams", "O365Group") `
    -RequiredFields @("targetPath", "principalId") `
    -Description "Removes the permission that lets someone outside the organisation reach this" `
    -Plan {
    Param($item, $context)

    $target = Get-M365PSharingTarget -Item $item -Context $context
    if (!$target) { Add-M365PSkip -Item $item -Why "This is a site level finding, which needs the SharePoint site handler"; return }

    $isAnonymous = "$($item.principalId)" -eq "Anonymous"

    if ($target.Route -eq "graph") {
        $candidates = if ($isAnonymous) { @($target.Permissions | Where-Object { $_.link -and $_.link.scope -eq "anonymous" }) }
                      else { @($target.Permissions | Where-Object { Test-M365PPermissionMatchesPrincipal -Permission $_ -Item $item }) }
        if ($candidates.Count -eq 0) { Add-M365PSkip -Item $item -Why "Could not find a permission for $($item.principalName ?? $item.principalId) on this item any more"; return }

        foreach ($permission in $candidates) {
            $identityCount = @(@($permission.grantedToIdentitiesV2)).Count
            if ($permission.link -and $permission.link.scope -eq "users" -and $identityCount -gt 1) {
                Add-M365PSkip -Item $item -Why "The link on $($target.Resolved.Name) is shared with $identityCount people, so removing it would cut off more than this finding. Remove this person from the link in SharePoint instead."
                continue
            }
            New-M365PGraphPermissionDelete -Item $item -Resolved $target.Resolved -Permission $permission `
                -Summary "Remove $(Get-M365PPermissionDescription -Permission $permission) from $($target.Resolved.Name)"
        }
        return
    }

    if ($isAnonymous) {
        $links = @($target.Links | Where-Object { $_.Anonymous })
        if ($links.Count -eq 0) { Add-M365PSkip -Item $item -Why "No anyone-with-the-link permission left on this item"; return }
        foreach ($link in $links) {
            New-M365PUnshareLinkAction -Item $item -Resolved $target.Resolved -Link $link `
                -Summary "Delete the anyone-with-the-link permission on $($target.Resolved.Name)"
        }
        return
    }

    #a named outsider holds either a direct grant or a place on a specific-people link. The grant is
    #removed on its own; a link shared with several people is left alone, because deleting it would cut
    #off more than this finding asked for.
    $acted = $False
    foreach ($principal in @($target.Principals | Where-Object { Test-M365PPrincipalMatchesFinding -Principal $_ -Item $item })) {
        $acted = $True
        New-M365PRemoveRoleAssignmentAction -Item $item -Resolved $target.Resolved -Principal $principal `
            -Detail @("direct grant to $($principal.principal.name ?? $principal.principal.loginName)") `
            -Summary "Remove $($item.principalName ?? $item.principalId) from $($target.Resolved.Name)"
    }

    foreach ($link in @($target.Links | Where-Object { @($_.Invitations).Count -gt 0 })) {
        $matched = @($link.Invitations | Where-Object {
                $invitee = $_.invitee
                @($item.principalId, $item.principalName, $item.principalUpn | Where-Object { $_ }) |
                Where-Object { "$($invitee.email)" -like "*$_*" -or "$($invitee.name)" -like "*$_*" -or "$($invitee.id)" -eq "$_" }
            })
        if ($matched.Count -eq 0) { continue }

        if (@($link.Invitations).Count -gt 1) {
            Add-M365PSkip -Item $item -Why "$($item.principalName ?? $item.principalId) is on a link shared with $(@($link.Invitations).Count) people, so deleting it would cut off more than this finding. Remove them from the link in SharePoint instead."
            continue
        }
        $acted = $True
        New-M365PUnshareLinkAction -Item $item -Resolved $target.Resolved -Link $link `
            -Summary "Delete the link that shares $($target.Resolved.Name) with $($item.principalName ?? $item.principalId)"
    }

    if (!$acted) { Add-M365PSkip -Item $item -Why "Could not find a permission for $($item.principalName ?? $item.principalId) on this item any more" }
}
