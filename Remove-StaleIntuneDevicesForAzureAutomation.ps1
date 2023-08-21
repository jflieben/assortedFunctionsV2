<#

.COPYRIGHT
Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
See LICENSE in the project root for license information.

.EXPANDED COPYRIGHT INFORMATION
Heavily modified and tested by Jos Lieben (OGD, www.lieben.nu) to make it easier to schedule as a runbook in Azure;
1. automatically authorize / consent to the Intune powershell azure app
2. retrieve token silently based on azure credential
3. log to azure log stream

Original script location: https://gallery.technet.microsoft.com/Script-to-Remove-Stale-8328aca0
Original script explanation: https://blogs.technet.microsoft.com/smeems/2018/03/07/device-cleanup-with-graph-api/
Original authors: Sarah L Handler and Josh Douglas

#>


####################################################

[cmdletbinding()]

Param(
    [Parameter(Mandatory=$true)]$automationAccountCredentialName,
    [Int]$cutoffDays=90,
    [Int]$testMode=0 #set to 1 to run in read-only mode
)

function Get-AuthToken {

    <#
    .SYNOPSIS
    This function is used to authenticate with the Graph API REST interface
    .DESCRIPTION
    The function authenticate with the Graph API Interface with the tenant name
    .EXAMPLE
    Get-AuthToken
    Authenticates you with the Graph API interface
    .NOTES
    NAME: Get-AuthToken
    #>
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory=$true)]$User,
        [Parameter(Mandatory=$true)]$Password
    )

    $userUpn = New-Object "System.Net.Mail.MailAddress" -ArgumentList $User

    $tenant = $userUpn.Host

    Write-Verbose "Checking for AzureAD module..."

    $AadModule = Get-Module -Name "AzureAD" -ListAvailable

    if ($AadModule -eq $null) {
        Write-Verbose "AzureAD PowerShell module not found, looking for AzureADPreview"
        $AadModule = Get-Module -Name "AzureADPreview" -ListAvailable
    }

    if ($AadModule -eq $null) {
        write-error "AzureAD Powershell module not installed...install this module into your automation account (add from the gallery) and rerun this runbook" -erroraction Continue
        Throw
    }

    # Getting path to ActiveDirectory Assemblies
    # If the module count is greater than 1 find the latest version

    if($AadModule.count -gt 1){

        $Latest_Version = ($AadModule | select version | Sort-Object)[-1]

        $aadModule = $AadModule | ? { $_.version -eq $Latest_Version.version }

            # Checking if there are multiple versions of the same module found
            if($AadModule.count -gt 1){
                $aadModule = $AadModule | select -Unique
            }

        $adal = Join-Path $AadModule.ModuleBase "Microsoft.IdentityModel.Clients.ActiveDirectory.dll"
        $adalforms = Join-Path $AadModule.ModuleBase "Microsoft.IdentityModel.Clients.ActiveDirectory.Platform.dll"

    }else{

        $adal = Join-Path $AadModule.ModuleBase "Microsoft.IdentityModel.Clients.ActiveDirectory.dll"
        $adalforms = Join-Path $AadModule.ModuleBase "Microsoft.IdentityModel.Clients.ActiveDirectory.Platform.dll"

    }

    [System.Reflection.Assembly]::LoadFrom($adal) | Out-Null
    [System.Reflection.Assembly]::LoadFrom($adalforms) | Out-Null
    $clientId = "d1ddf0e4-d672-4dae-b554-9d5bdfd93547"
    $redirectUri = "urn:ietf:wg:oauth:2.0:oob"
    $resourceAppIdURI = "https://graph.microsoft.com"
    $authority = "https://login.microsoftonline.com/$Tenant"

    try {

        $authContext = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext" -ArgumentList $authority

        # https://msdn.microsoft.com/en-us/library/azure/microsoft.identitymodel.clients.activedirectory.promptbehavior.aspx
        # Change the prompt behaviour to force credentials each time: Auto, Always, Never, RefreshSession

        $platformParameters = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.PlatformParameters" -ArgumentList "Auto"

        $userId = New-Object "Microsoft.IdentityModel.Clients.ActiveDirectory.UserIdentifier" -ArgumentList ($User, "OptionalDisplayableId")

        $userCredentials = new-object Microsoft.IdentityModel.Clients.ActiveDirectory.UserPasswordCredential -ArgumentList $userUpn,$Password

        $authResult = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContextIntegratedAuthExtensions]::AcquireTokenAsync($authContext, $resourceAppIdURI, $clientid, $userCredentials);
        if($authResult.Exception -and $authResult.Exception.ToString() -like "*Send an interactive authorization request*"){
            try{
                #Intune Powershell has not yet been authorized, let's try to do this on the fly;
                login-azurermaccount -Credential $intuneAdminCreds
                $context = Get-AzureRmContext
                $tenantId = $context.Tenant.Id
                $refreshToken = $context.TokenCache.ReadItems().RefreshToken
                $body = "grant_type=refresh_token&refresh_token=$($refreshToken)&resource=74658136-14ec-4630-ad9b-26e160ff0fc6"
                $apiToken = Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
                $header = @{
                'Authorization' = 'Bearer ' + $apiToken.access_token
                'X-Requested-With'= 'XMLHttpRequest'
                'x-ms-client-request-id'= [guid]::NewGuid()
                'x-ms-correlation-id' = [guid]::NewGuid()}
                $url = "https://main.iam.ad.ext.azure.com/api/RegisteredApplications/d1ddf0e4-d672-4dae-b554-9d5bdfd93547/Consent?onBehalfOfAll=true" #this is the Microsoft Intune Powershell app ID managed by Microsoft
                Invoke-RestMethod –Uri $url –Headers $header –Method POST -ErrorAction Stop
                $authResult = [Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContextIntegratedAuthExtensions]::AcquireTokenAsync($authContext, $resourceAppIdURI, $clientid, $userCredentials);
            }catch{
                Throw "You have not yet authorized Powershell, visit https://login.microsoftonline.com/$Tenant/oauth2/authorize?client_id=d1ddf0e4-d672-4dae-b554-9d5bdfd93547&response_type=code&redirect_uri=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob&response_mode=query&resource=https%3A%2F%2Fgraph.microsoft.com%2F&state=12345&prompt=admin_consent using a global administrator"
            }
        }
        $authResult = $authResult.Result
        if($authResult.AccessToken){
            # Creating header for Authorization token
            $authHeader = @{
                'Content-Type'='application/json'
                'Authorization'="Bearer " + $authResult.AccessToken
                'ExpiresOn'=$authResult.ExpiresOn
                }
            return $authHeader
        }else {
            Throw "access token is null!"
        }

    }catch {
        write-error "Failed to retrieve access token from Azure" -erroraction Continue
        write-error $_ -erroraction Stop
    }
}

Function Get-StaleManagedDevices(){

    <#
    .SYNOPSIS
    This function is used to get Intune Managed Devices from the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets any Intune Managed Device that has not synced with the service in the past X days
    .EXAMPLE
    Get-StaleManagedDevices
    Returns all managed devices but excludes EAS devices registered within the Intune Service that have not checked in for X days
    .NOTES
    NAME: Get-StaleManagedDevices
    #>
    
    [cmdletbinding()]
    param
    (
        [Int]$cutoffDays
    )
    #change cutoffDays to negative number if non-negative was supplied
    if($cutoffDays -ge 0){
        $cutoffDays = $cutoffDays * -1
    }
    # Defining Variables
    $graphApiVersion = "beta"
    $Resource = "deviceManagement/managedDevices"
    # this will get the date/time at the time this is run, so if it is 3pm on 2/27, the 90 day back mark would be 11/29 at 3pm, meaning if a device checked in on 11/29 at 3:01pm it would not meet the check
    $cutoffDate = (Get-Date).AddDays($cutoffDays).ToString("yyyy-MM-dd")
    
    $uri = ("https://graph.microsoft.com/{0}/{1}?filter=managementAgent eq 'mdm' or managementAgent eq 'easMDM' and lastSyncDateTime le {2}" -f $graphApiVersion, $Resource, $cutoffDate)
        
    try {    
        $devices = (Invoke-RestMethod -Uri $uri -Headers $authToken -Method Get).Value
        return $devices
    }catch {
        $ex = $_.Exception
        $errorResponse = $ex.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorResponse)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd();
        Write-Error "Failed to retrieve managed devices; response content: `n$responseBody" -ErrorAction Continue
        Write-Error "Request to $Uri failed with HTTP Status $($ex.Response.StatusCode) $($ex.Response.StatusDescription)" -ErrorAction Stop
    }
    
} 

function Remove-StaleDevices(){

    <#
    .SYNOPSIS
    This function retires all stale devices in Intune that have not checked in within 90 days
    .DESCRIPTION
    The function connects to the Graph API Interface and retires any Intune Managed Device that has not synced with the service in the past 90 days
    .EXAMPLE
    Remove-StaleDevices -Devices $deviceList
    Executes a retire command against all devices in the list provided and then deletes the record from the console
    .NOTES
    NAME: Remove-StaleDevices
    #>
        
    [cmdletbinding()]
    param
    (
        [Parameter(Mandatory=$true)]$DeviceID
    )
    $graphApiVersion = "Beta"
    try {
        $Resource = "deviceManagement/managedDevices/$DeviceID/retire"
        $uri = "https://graph.microsoft.com/$graphApiVersion/$($resource)"
        Write-Output "Sending retire command to $DeviceID"
        Invoke-RestMethod -Uri $uri -Headers $authToken -Method Post -UseBasicParsing

        $Resource = "deviceManagement/managedDevices('$DeviceID')"
        $uri = "https://graph.microsoft.com/$graphApiVersion/$($resource)"
        Write-Output "Sending delete command to $DeviceID"
        Invoke-RestMethod -Uri $uri -Headers $authToken -Method Delete -UseBasicParsing
    }catch {
        $ex = $_.Exception
        $errorResponse = $ex.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorResponse)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd();
        Write-Error "Failed to remove device, response content:`n$responseBody" -erroraction Continue
        Write-Error "Request to $Uri failed with HTTP Status $($ex.Response.StatusCode) $($ex.Response.StatusDescription)" -ErrorAction Stop
    }
}

####################################################

# Getting the authorization token
try{
    Write-Output "Retrieving runbook credential object"
    $intuneAdminCreds = Get-AutomationPSCredential -Name $automationAccountCredentialName
    Write-Output "Credentials retrieved"
}catch{
    Write-Error "Failed to retrieve runbook credentials" -ErrorAction Continue
    Write-Error $_ -ErrorAction Stop
}

$global:authToken = Get-AuthToken -User $intuneAdminCreds.UserName -Password $intuneAdminCreds.GetNetworkCredential().password

$staleDevices = Get-StaleManagedDevices -cutoffDays $cutoffDays

if($staleDevices -eq $null){
    Write-Output "There are no devices that are out of date; ending script..."
    Exit
}else{
    Write-Output "Retrieved $($staleDevices.Count) stale devices, removing them now...."
}

foreach($device in $staleDevices){
    if($testMode -eq 1){
        Write-Output "Would remove $($device.deviceName) but running in test mode"
    }else{
        Write-Output "Will remove $($device.deviceName)"
        Remove-StaleDevices -DeviceID $device.ID
    }
}

Write-Output "Script finished"
