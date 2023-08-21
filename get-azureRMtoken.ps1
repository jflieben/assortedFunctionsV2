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