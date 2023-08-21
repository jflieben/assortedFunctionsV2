#Requires -Modules ImportExcel
<#
    .SYNOPSIS
    generate a full report of all AzureAD applications
    .DESCRIPTION
    A number of functions to generate a full report of all applications your Azure AD has, including all permissions they require and how they have been assigned (user / admin)
    .EXAMPLE
    To get your report, run get-azureRMADAppPermissionsReport -token (get-azureRMtoken -username jos.lieben@xxx.com -password password01) -reportPath c:\temp\report.xlsx
    .PARAMETER token
    a valid Azure RM token retrieved through my get-azureRMtoken function, can de done on the fly as the example shows
    .PARAMETER reportPath
    Full path to desired report file, if unspecified, will write to temp
    .NOTES
    If you have enabled MFA on your admin account, you may have to manually run the get-azureRMtoken function step by step, because -Credential is buddy as of the time of writing
    filename: azureRMADAppPermissionsReport.psm1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 26/7/2018
#>

function get-azureRMADAppPermissionsReport(){
    <#
      .SYNOPSIS
      Retrieve all permissions an Azure AD application has set
      .DESCRIPTION
      
      .EXAMPLE
      $permissions = get-azureRMADAppPermissionsReport -token (get-azureRMtoken -username jos.lieben@xxx.com -password password01) -reportPath c:\temp\report.xlsx
      .PARAMETER token
      a valid Azure RM token retrieved through my get-azureRMtoken function
      .PARAMETER reportPath
      Full path to desired report file, if unspecified, will write to temp
      .NOTES
      filename: get-azureRMADAppPermissionsReport.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 26/7/2018
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]$token,
        $reportPath=(Join-Path $Env:TEMP -ChildPath "azureRMAppPermissionsReport.xlsx")
    )
    $applications = get-azureRMADAllApplications -token $token
    $userConsent = @()
    $adminConsent = @()
    $userToApp = @{}
    $count = 0
    foreach($application in $applications){
        $permissions = get-azureRMADAppPermissions -token $token -appId $application.objectId
        if($permissions.admin){
            $applications[$count] | Add-Member NoteProperty -Name AdminHasConsented -Value $True
        }else{
            $applications[$count] | Add-Member NoteProperty -Name AdminHasConsented -Value $False
        }
        if($permissions.user){
            $applications[$count] | Add-Member NoteProperty -Name UsersHaveConsented -Value $True
        }else{
            $applications[$count] | Add-Member NoteProperty -Name UsersHaveConsented -Value $False
        }
        $applications[$count] | Add-Member NoteProperty -Name Permissions -Value $permissions
        $count++
    }

    $applications | Select displayName,publisherName,accountEnabled,appRoleAssignmentRequired,isApplicationVisible,AdminHasConsented,UsersHaveConsented,appDisplayName,homePageUrl,ssoConfiguration,appRoles,tags,userAccessUrl | Export-Excel -workSheetName "Applications" -path $reportPath -ClearSheet -TableName "Applications" -AutoSize
    
    foreach($application in ($applications | Where-Object {$_.AdminHasConsented})){
        foreach($permission in $application.permissions.admin){
            $adminConsent += [PSCustomObject]@{
            "appId"=$application.appId
            "appDisplayName"=$application.displayName
            "Resource"=$permission.resourceName
            "Permission"=$permission.permissionId
            "RoleOrScopeClaim"=$permission.roleOrScopeClaim
            "Description"=$permission.permissionDescription}
        }
    }

    $adminConsent | Export-Excel -workSheetName "AdminConsentedRights" -path $reportPath -ClearSheet -TableName "AdminConsentedRights" -AutoSize

    foreach($application in ($applications | Where-Object {$_.UsersHaveConsented})){
        foreach($permission in $application.permissions.user){
            $userConsent += [PSCustomObject]@{
            "appId"=$application.appId
            "appDisplayName"=$application.displayName
            "Resource"=$permission.resourceName
            "Permission"=$permission.permissionId
            "RoleOrScopeClaim"=$permission.roleOrScopeClaim
            "Description"=$permission.permissionDescription}

            foreach($principal in $permission.principalIds){
                if(!$userToApp.$principal){
                    $userToApp.$principal = @()
                }
                $userToApp.$principal += [PSCustomObject]@{
                "appId"=$application.appId
                "appDisplayName"=$application.displayName
                "Resource"=$permission.resourceName
                "Permission"=$permission.permissionId
                "RoleOrScopeClaim"=$permission.roleOrScopeClaim
                "Description"=$permission.permissionDescription}
            }
        }
    }
    
    $userConsent | Export-Excel -workSheetName "UserConsentedRights" -path $reportPath -ClearSheet -TableName "UserConsentedRights" -AutoSize

    $userToAppTranslated = @()
    foreach($user in $userToApp.Keys){
        try{
            $userInfo = get-azureRMADUserInfo -token $token -userGuid $user
        }catch{
            $userInfo = [PSCustomObject]@{
                "UserDisplayName"=$user
                "UserPrincipalName"=$NULL
                "accountEnabled"=$NULL
                "appId"=$NULL
                "appDisplayName"=$NULL
                "Resource"=$NULL
                "Permission"=$NULL
                "RoleOrScopeClaim"=$NULL
                "Description"="FAILED TO RETRIEVE DATA FOR THIS USER GUID: $user"}
        }
        $userToAppTranslated += [PSCustomObject]@{
        "UserDisplayName"=$userInfo.displayName
        "UserPrincipalName"=$userInfo.userPrincipalName
        "accountEnabled"=$userInfo.accountEnabled
        "appId"=$userToApp.$user.appId
        "appDisplayName"=$userToApp.$user.appDisplayName
        "Resource"=$userToApp.$user.Resource
        "Permission"=$userToApp.$user.Permission
        "RoleOrScopeClaim"=$userToApp.$user.RoleOrScopeClaim
        "Description"=$userToApp.$user.Description}
    }
    
    $userToAppTranslated | Export-Excel -workSheetName "UserToAppMapping" -path $reportPath -ClearSheet -TableName "UserToAppMapping" -AutoSize
}

function get-azureRMADUserInfo(){
    <#
      .SYNOPSIS
      Retrieve info about specified user
      .DESCRIPTION
      Retrieve info about specified user by GUID
      .EXAMPLE
      $users = get-azureRMADUserInfo -token (get-azureRMtoken -username jos.lieben@xxx.com -password password01) -userGuid 479c3c0d-a103-4899-84ce-54b05e5be5fa
      .PARAMETER token
      a valid Azure RM token retrieved through my get-azureRMtoken function
      .PARAMETER userGuid
      GUID of the user you want to retrieve info about
      .NOTES
      filename: get-azureRMADUserInfo.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 27/7/2018
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]$token,
        [Parameter(Mandatory=$true)]$userGuid
    )
    $header = @{
        'Authorization' = 'Bearer ' + $token
        'X-Requested-With'= 'XMLHttpRequest'
        'x-ms-client-request-id'= [guid]::NewGuid()
        'x-ms-correlation-id' = [guid]::NewGuid()}
        $url = "https://main.iam.ad.ext.azure.com/api/UserDetails/$userGuid"
        Write-Output (Invoke-RestMethod -Uri $url -Headers $header -Method GET -ErrorAction Stop)
}

function get-azureRMADAppPermissions(){
    <#
      .SYNOPSIS
      Retrieve all permissions an Azure AD application has set
      .DESCRIPTION
      Returns a hashtable with 'admin' and 'user' as properties, which contain arrays of all permissions this application has
      .EXAMPLE
      $permissions = get-azureRMADAppPermissions -token (get-azureRMtoken -username jos.lieben@xxx.com -password password01) -appId 479c3c0d-a103-4899-84ce-54b05e5be5fa
      .PARAMETER token
      a valid Azure RM token retrieved through my get-azureRMtoken function
      .PARAMETER appId
      object ID of the application you want to retrieve permissions from
      .NOTES
      filename: get-azureRMADAppPermissions.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 26/7/2018
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]$token,
        [Parameter(Mandatory=$true)]$appId
    )
    $permissions = @{"admin"=@();"user"=@()}
    $header = @{
        'Authorization' = 'Bearer ' + $token
        'X-Requested-With'= 'XMLHttpRequest'
        'x-ms-client-request-id'= [guid]::NewGuid()
        'x-ms-correlation-id' = [guid]::NewGuid()}
    $url = "https://main.iam.ad.ext.azure.com/api/EnterpriseApplications/$appId/ServicePrincipalPermissions?consentType=Admin&userObjectId="
    $res = Invoke-RestMethod -Uri $url -Headers $header -Method GET -ErrorAction Stop -ContentType "application/json"
    $permissions.admin += $res
    $url = "https://main.iam.ad.ext.azure.com/api/EnterpriseApplications/$appId/ServicePrincipalPermissions?consentType=User&userObjectId="
    $res = Invoke-RestMethod -Uri $url -Headers $header -Method GET -ErrorAction Stop -ContentType "application/json"
    $permissions.user += $res
    return $permissions
}

function get-azureRMADAllApplications(){
    <#
      .SYNOPSIS
      Retrieve all Azure AD applications
      .DESCRIPTION
      Retrieves Azure AD applications (enterprise and app registrations) from AzureAD including numerous properties that get-AzureADRMApplication does not return
      .EXAMPLE
      $apps = get-azureRMADAllApplications -token (get-azureRMtoken -username jos.lieben@xxx.com -password password01)
      .PARAMETER token
      a valid Azure RM token retrieved through my get-azureRMtoken function
      .PARAMETER returnDisabledApplications
      if specified, also return applications that have been disabled
      .NOTES
      filename: get-azureRMADAllApplications.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 25/7/2018
    #>
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory=$true)]$token,
        [Switch]$returnDisabledApplications,
        [Parameter(DontShow)]$nextLink
    )
    $apps = @()
    $header = @{
        'Authorization' = 'Bearer ' + $token
        'X-Requested-With'= 'XMLHttpRequest'
        'x-ms-client-request-id'= [guid]::NewGuid()
        'x-ms-correlation-id' = [guid]::NewGuid()}
    $body = @{"accountEnabled"=$(if($returnDisabledApplications){$null}else{$True});"isAppVisible"=$null;"appListQuery"=0;"searchText"="";"top"=100;"loadLogo"=$false;"putCachedLogoUrlOnly"=$true;"nextLink"="$nextLink";"usedFirstPartyAppIds"=$null;
    "__ko_mapping__"=@{"ignore"=@();"include"=@("_destroy");"copy"=@();"observe"=@();"mappedProperties"=@{"accountEnabled"=$(if($returnDisabledApplications){$null}else{$True});"isAppVisible"=$true;"appListQuery"=$true;"searchText"=$true;"top"=$true;"loadLogo"=$true;"putCachedLogoUrlOnly"=$true;"nextLink"=$true;"usedFirstPartyAppIds"=$true};"copiedProperties"=@{}}}
    $url = "https://main.iam.ad.ext.azure.com/api/ManagedApplications/List"
    $res = Invoke-RestMethod -Uri $url -Headers $header -Method POST -body ($body | convertto-Json) -ErrorAction Stop -ContentType "application/json"
    foreach($app in $res.applist){
        $additionalInfo = Invoke-RestMethod -Headers $header -Uri "https://main.iam.ad.ext.azure.com/api/EnterpriseApplications/$($app.objectId)/Properties?appId=$($app.appId)&loadLogo={2}" -Method GET -ErrorAction Stop -ContentType "application/json"
        $app | add-member NoteProperty -name userAccessUrl -Value $additionalInfo.userAccessUrl
        $app | add-member NoteProperty -name appRoleAssignmentRequired -Value $additionalInfo.appRoleAssignmentRequired
        $app | add-member NoteProperty -name isApplicationVisible -Value $additionalInfo.isApplicationVisible
        $apps += $app
    }
    if($res.nextLink){
        $apps += get-azureRMADAllApplications -returnDisabledApplications:$returnDisabledApplications -nextLink $res.nextLink -token $token
    }
    return $apps
}
function get-azureRMToken(){
    <#
      .SYNOPSIS
      Retrieve special Azure RM token to use for the main.iam.ad.ext.azure.com endpoint
      .DESCRIPTION
      The Azure RM token can be used for various actions that are not possible using Powershell cmdlets. This is experimental and should be used with caution!
      .EXAMPLE
      $token = get-azureRMToken -Username you@domain.com -Password Welcome01
      .PARAMETER Username
      the UPN of a user with sufficient permissions to call the endpoint (this depends on what you'll use the token for)
      .PARAMETER Password
      Password of Username
      .PARAMETER tenantId
      If supplied, logs in to specified tenant.
      .NOTES
      filename: get-azureRMToken.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 12/6/2018
    #>
    Param(
        [Parameter(Mandatory=$true)]$Username,
        [Parameter(Mandatory=$true)]$Password,
        $tenantId
    )
    $secpasswd = ConvertTo-SecureString $Password -AsPlainText -Force
    $mycreds = New-Object System.Management.Automation.PSCredential ($Username, $secpasswd)
    if($tenantId){
        $res = login-azurermaccount -Credential $mycreds -TenantId $tenantId.ToLower()
    }else{
        $res = login-azurermaccount -Credential $mycreds
    }
    $context = Get-AzureRmContext
    $tenantId = $context.Tenant.Id
    $refreshToken = @($context.TokenCache.ReadItems() | where {$_.tenantId -eq $tenantId -and $_.ExpiresOn -gt (Get-Date)})[0].RefreshToken
    $body = "grant_type=refresh_token&refresh_token=$($refreshToken)&resource=74658136-14ec-4630-ad9b-26e160ff0fc6"
    $apiToken = Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $apiToken.access_token
}

Export-ModuleMember -Function *