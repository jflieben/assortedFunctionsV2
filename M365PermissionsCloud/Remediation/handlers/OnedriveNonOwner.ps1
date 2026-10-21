#Requires -Version 7.0
<#
    Non-owner access to a personal OneDrive.

    Somebody other than the owner holds full control of a personal OneDrive, which in SharePoint terms
    means they are a site collection administrator of it. That is not something Graph can read or write:
    site collection administrators only exist in the SharePoint API, so this handler is the one place
    that needs a SharePoint sign in of its own.

    What that means in practice:
      a second device code sign in, against the SharePoint Online Management Shell client
      the account signing in has to be a SharePoint administrator
      the change is reversible: the rollback file puts the administrator back

    A finding where the non-owner is the product's own identity is left alone, since that access is how
    the scan reads the drive in the first place.
#>

function Get-M365PSharePointLogin {
    <#
        .SYNOPSIS
        The claims login name SharePoint knows a user by.

        .DESCRIPTION
        SharePoint identifies members with i:0#.f|membership|<upn>, which is what the scan records in
        principalSysId for a site level finding. When the portal only had an Entra id and a UPN, the
        login is rebuilt from the UPN, which is the same string SharePoint would have produced.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Item)

    foreach ($candidate in @($Item.principalSysId, $Item.principalLogin)) {
        if ("$candidate" -like "i:0#.f|*") { return "$candidate" }
    }
    foreach ($candidate in @($Item.principalUpn, $Item.principalName)) {
        if ("$candidate" -like "*@*") { return "i:0#.f|membership|$candidate" }
    }
    return $Null
}

Register-M365PRemediation -Reason "Non-owner access to a personal Onedrive" `
    -Categories @("Onedrive") `
    -RequiredScopes @() `
    -RequiredFields @("targetPath", "principalUpn") `
    -Description "Removes a site collection administrator from somebody else's OneDrive" `
    -Plan {
    Param($item, $context)

    $login = Get-M365PSharePointLogin -Item $item
    if (!$login) {
        Add-M365PSkip -Item $item -Why "No sign in name for the non-owner. Pass principalUpn, which is what SharePoint identifies a person by."
        return
    }
    if (Test-M365PIsProtected -DisplayName "$($item.principalName)" -ObjectId "$($item.principalId)") {
        Add-M365PSkip -Item $item -Why "$($item.principalName) belongs to M365Permissions itself, and that access is how this drive gets scanned"
        return
    }

    $parts = Split-M365PSharePointPath -TargetPath $item.targetPath
    if (!$parts.SitePath -or $parts.SitePath -notlike "/personal/*") {
        Add-M365PSkip -Item $item -Why "$($item.targetPath) is not a personal OneDrive site"
        return
    }

    $siteUrl = "https://$($parts.Host)$($parts.SitePath)"

    #read it back first, so the plan states what is actually true now rather than what the scan saw
    $user = $Null
    try {
        $encoded = [Uri]::EscapeDataString($login)
        $user = @(Invoke-M365PCall -Audience "https://$($parts.Host)" -NoPaging `
                -Uri "$siteUrl/_api/web/siteusers(@v)?@v='$encoded'") | Select-Object -First 1
    }catch {
        Add-M365PSkip -Item $item -Why "Could not read $login on $siteUrl : $($_.Exception.Message)"
        return
    }

    if (!$user.IsSiteAdmin) {
        Add-M365PSkip -Item $item -Why "$login is no longer a site collection administrator of $siteUrl"
        return
    }

    New-M365PAction -Item $item `
        -Summary "Remove $($item.principalName ?? $login) as site collection administrator of $($parts.SitePath)" `
        -Target $siteUrl `
        -Detail @("the owner keeps their own access", "this does not delete the account or any content") `
        -State @{
            Uri   = "$siteUrl/_api/web/siteusers(@v)?@v='$([Uri]::EscapeDataString($login))'"
            Host  = $parts.Host
            Login = $login
        } `
        -Apply {
        Param($action, $context)
        #MERGE with the SP.User type is how the SharePoint API changes one property of a site user, and
        #the verbose content type is what lets __metadata be sent at all
        $Null = Invoke-M365PCall -Audience "https://$($action.State.Host)" -Uri $action.State.Uri -Method "MERGE" `
            -ContentType "application/json;odata=verbose" -ExtraHeaders @{ "IF-MATCH" = "*" } `
            -Body @{ "__metadata" = @{ "type" = "SP.User" }; "IsSiteAdmin" = $False }
    } `
        -Undo @{
        type        = "sharePointMerge"
        uri         = "$siteUrl/_api/web/siteusers(@v)?@v='$([Uri]::EscapeDataString($login))'"
        audience    = "https://$($parts.Host)"
        contentType = "application/json;odata=verbose"
        body        = @{ "__metadata" = @{ "type" = "SP.User" }; "IsSiteAdmin" = $True }
    }
}
