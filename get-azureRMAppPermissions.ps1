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