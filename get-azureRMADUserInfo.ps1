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