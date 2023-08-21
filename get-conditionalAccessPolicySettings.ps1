function get-conditionalAccessPolicySettings(){
    <#
      .SYNOPSIS
      Retrieve conditional access policy settings from Intune
      .DESCRIPTION
      Retrieves all conditional access policies from Intune (if policyId is omitted) and outputs their settings
      .EXAMPLE
      $policies = get-conditionalAccessPolicySettings -Username you@domain.com -Password Welcome01
      .EXAMPLE
      $policy = get-conditionalAccessPolicySettings -Username you@domain.com -Password Welcome01 -policyId 533ceb01-3603-48cb-8586-56a60153939d
      .PARAMETER Username
      the UPN of a user with sufficient permissions (global admin)
      .PARAMETER Password
      Password of Username
      .PARAMETER policyId
      GUID of the policy you wish to return, if left empty, all policies will be returned
      .NOTES
      filename: get-conditionalAccessPolicySettings.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 12/6/2018
      requires: get-azureRMtoken.ps1
    #>
    Param(
        [Parameter(Mandatory=$true)]$Username, #global administrator username
        [Parameter(Mandatory=$true)]$Password, #global administrator password
        $policyId #if not specified, return all policies
    )

    $azureToken = get-azureRMToken -Username $Username -Password $Password
    $header = @{
    'Authorization' = 'Bearer ' + $azureToken
    'X-Requested-With'= 'XMLHttpRequest'
    'x-ms-client-request-id'= [guid]::NewGuid()
    'x-ms-correlation-id' = [guid]::NewGuid()}
    if(!$policyId){
        $url = "https://main.iam.ad.ext.azure.com/api/Policies/Policies?top=100&nextLink=null&appId=&includeBaseline=true"
        $policies = @(Invoke-RestMethod –Uri $url –Headers $header –Method GET -ErrorAction Stop).items
        foreach($policy in $policies){
            get-conditionalAccessPolicySettings -Username $Username -Password $Password -policyId $policy.policyId
        }
    }else{
        $url = "https://main.iam.ad.ext.azure.com/api/Policies/$policyId"
        $policy = Invoke-RestMethod –Uri $url –Headers $header –Method GET -ErrorAction Stop
        Write-Output $policy
    }
}
