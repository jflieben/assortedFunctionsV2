function get-deviceConfigurationPolicySettings(){
    <#
      .SYNOPSIS
      Retrieve device configuration policy settings from Intune
      .DESCRIPTION
      Retrieves all device configuration policies from Intune (if policyId is omitted) and outputs their settings
      .EXAMPLE
      $policies = get-deviceConfigurationPolicySettings -Username you@domain.com -Password Welcome01
      .EXAMPLE
      $policy = get-deviceConfigurationPolicySettings -Username you@domain.com -Password Welcome01 -policyId 533ceb01-3603-48cb-8586-56a60153939d
      .PARAMETER Username
      the UPN of a user with sufficient permissions (global admin)
      .PARAMETER Password
      Password of Username
      .PARAMETER policyId
      GUID of the policy you wish to return, if left empty, all policies will be returned
      .NOTES
      filename: get-deviceConfigurationPolicySettings.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 12/6/2018
      requires: get-azureRMtoken.ps1, get-graphTokenforIntune.ps1
    #>
    Param(
        [Parameter(Mandatory=$true)]$Username, #global administrator username
        [Parameter(Mandatory=$true)]$Password, #global administrator password
        $policyId #if not specified, return all policies
    )
    $graphToken = get-graphTokenForIntune -User $Username -Password $Password
    $graphHeader = @{
    'Authorization' = 'Bearer ' + $graphToken
    'X-Requested-With'= 'XMLHttpRequest'
    'x-ms-client-request-id'= [guid]::NewGuid()
    'x-ms-correlation-id' = [guid]::NewGuid()}
    if(!$policyId){
        $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?`$expand=assignments"
        $policies = Invoke-RestMethod –Uri $url –Headers $graphHeader –Method GET -ErrorAction Stop
        Write-Output $policies.value
    }else{
        $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$($policyId)?`$expand=assignments,scheduledActionsForRule(`$expand=scheduledActionConfigurations)"
        $policy = Invoke-RestMethod –Uri $url –Headers $graphHeader –Method GET -ErrorAction Stop
        Write-Output $policy
    }
}
