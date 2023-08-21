function get-tenantIdFromLogin(){
    <#
      .SYNOPSIS
      Retrieves an Office 365 / Azure AD tenant ID for a given user login name (email address)
      .EXAMPLE
      $tenantId = get-tenantIdFromLogin -Username you@domain.com
      .PARAMETER Username
      the UPN of a user
      .NOTES
      filename: get-tenantIdFromLogin.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 8/3/2019
    #>
    Param(
        [Parameter(Mandatory=$true)]$Username
    )
    $openIdInfo = Invoke-RestMethod "https://login.windows.net/$($Username.Split("@")[1])/.well-known/openid-configuration" -Method GET
    return $openIdInfo.userinfo_endpoint.Split("/")[3]
}