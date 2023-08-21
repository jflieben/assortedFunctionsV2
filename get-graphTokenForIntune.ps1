function get-graphTokenForIntune(){
    <#
      .SYNOPSIS
      Retrieve special graph token to interact with the beta (and normal) Intune endpoint
      .DESCRIPTION
      this function wil also, if needed, register the well known microsoft ID for intune PS management
      .EXAMPLE
      $token = get-graphTokenForIntune -User you@domain.com -Password Welcome01
      .PARAMETER User
      the UPN of a user with global admin permissions
      .PARAMETER Password
      Password of Username
      .NOTES
      filename: get-graphTokenForIntune.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 12/6/2018
      requires: get-azureRMtoken.ps1
    #>    
    Param(
        [Parameter(Mandatory=$true)]$User,
        [Parameter(Mandatory=$true)]$Password
    )
    $userUpn = New-Object "System.Net.Mail.MailAddress" -ArgumentList $User
    $tenant = $userUpn.Host
    $AadModule = Get-Module -Name "AzureAD" -ListAvailable
    if ($AadModule -eq $null) {$AadModule = Get-Module -Name "AzureADPreview" -ListAvailable}
    if ($AadModule -eq $null) {
        write-error "AzureAD Powershell module not installed...install this module into your automation account (add from the gallery) and rerun this runbook" -erroraction Continue
        Throw
    }
    if($AadModule.count -gt 1){
        $Latest_Version = ($AadModule | select version | Sort-Object)[-1]
        $aadModule = $AadModule | ? { $_.version -eq $Latest_Version.version }
        if($AadModule.count -gt 1){$aadModule = $AadModule | select -Unique}
    }
    $adal = Join-Path $AadModule.ModuleBase "Microsoft.IdentityModel.Clients.ActiveDirectory.dll"
    $adalforms = Join-Path $AadModule.ModuleBase "Microsoft.IdentityModel.Clients.ActiveDirectory.Platform.dll"

    [System.Reflection.Assembly]::LoadFrom($adal) | Out-Null
    [System.Reflection.Assembly]::LoadFrom($adalforms) | Out-Null
    $clientId = "d1ddf0e4-d672-4dae-b554-9d5bdfd93547"
    $redirectUri = "urn:ietf:wg:oauth:2.0:oob"
    $resourceAppIdURI = "https://graph.microsoft.com"
    $authority = "https://login.microsoftonline.com/$Tenant"
    try {
        $authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority
        $platformParameters = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.PlatformParameters" -ArgumentList "Auto"
        $userId = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.UserIdentifier" -ArgumentList ($User, "OptionalDisplayableId")
        $userCredentials = new-object Microsoft.IdentityModel.Clients.ActiveDirectory.UserPasswordCredential -ArgumentList $userUpn,$Password
        $authResult = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContextIntegratedAuthExtensions]::AcquireTokenAsync($authContext, $resourceAppIdURI, $clientid, $userCredentials);
        if($authResult.Exception -and $authResult.Exception.ToString() -like "*Send an interactive authorization request*"){
            try{
                #Intune Powershell has not yet been authorized, let's try to do this on the fly;
                $apiToken = get-azureRMToken -Username $User -Password $Password
                $header = @{
                'Authorization' = 'Bearer ' + $apiToken
                'X-Requested-With'= 'XMLHttpRequest'
                'x-ms-client-request-id'= [guid]::NewGuid()
                'x-ms-correlation-id' = [guid]::NewGuid()}
                $url = "https://main.iam.ad.ext.azure.com/api/RegisteredApplications/d1ddf0e4-d672-4dae-b554-9d5bdfd93547/Consent?onBehalfOfAll=true" #this is the Microsoft Intune Powershell app ID managed by Microsoft
                Invoke-RestMethod -Uri $url -Headers $header -Method POST -ErrorAction Stop
                $authResult = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContextIntegratedAuthExtensions]::AcquireTokenAsync($authContext, $resourceAppIdURI, $clientid, $userCredentials);
            }catch{
                Throw "You have not yet authorized Powershell, visit https://login.microsoftonline.com/$Tenant/oauth2/authorize?client_id=d1ddf0e4-d672-4dae-b554-9d5bdfd93547&response_type=code&redirect_uri=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob&response_mode=query&resource=https%3A%2F%2Fgraph.microsoft.com%2F&state=12345&prompt=admin_consent using a global administrator"
            }
        }
        $authResult = $authResult.Result
        if(!$authResult.AccessToken){
            Throw "access token is null!"
        }else{
            return $authResult.AccessToken
        }
    }catch {
        write-error "Failed to retrieve access token from Azure" -erroraction Continue
        write-error $_ -erroraction Stop
    }
}