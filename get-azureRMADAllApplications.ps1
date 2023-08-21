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