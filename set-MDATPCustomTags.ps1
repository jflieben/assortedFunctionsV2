<#
    .SYNOPSIS
    Automatically tag devices in Microsoft Defender Advanced Threat Protection based on the primary user attributes (company in the example). To be used in MDATP device groups for targetting (https://securitycenter.windows.com/preferences2/machine_groups)
    
    .REQUIREMENTS
    An app registration (client ID) with graph\Device.Read.All, WindowsDefenderATP\Machine.ReadWrite (delegated) scopes and a user account with sufficient permissions in MDATP

    .ASSUMPTIONS
    It is assumed you're running this from an Azure Runbook with a credential stored, if not you'll have to replace line 99 to prompt for a credential

    .NOTES
    filename: set-MDATPCustomTags.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 05/10/2020
#>

##CONFIG
$clientId = "ac016cbc-fbb5-14b2-b3a5-5ca9a8c760d6"
$tenantId = "c42c1656-bdb0-4185-91ba-b2e48cacd561"
$automationCredentialName = "SVC-WE-MDATP-RW"

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
function update-MSSecApiToken{
    Param(
        [PSCredential]$creds,
        [String]$resource="https://api.securitycenter.microsoft.com"
    )
    if($global:MSSecApiToken.msApiToken -eq $Null -or $global:MSSecApiToken.msApiToken.resource -ne $resource -or ((Get-Date).AddSeconds(600)) -gt ([timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($global:MSSecApiToken.msApiToken.expires_on)))){
        $uri = "https://login.microsoftonline.com/$tenantId/oauth2/token"     
        $postBody = "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&client_id=$([System.Web.HttpUtility]::UrlEncode($clientId))&grant_type=password&username=$([System.Web.HttpUtility]::UrlEncode($creds.UserName))&password=$([System.Web.HttpUtility]::UrlEncode($($creds.GetNetworkCredential().Password)))"
        $global:MSSecApiToken = @{}
        $global:MSSecApiToken.msApiToken = ((Invoke-RestMethod -Uri $uri -Body $postBody -Method POST -ContentType 'application/x-www-form-urlencoded')) 
        $global:MSSecApiToken.headers = @{"Authorization" = "Bearer $($global:MSSecApiToken.msApiToken.access_token)"}
    }
    return $global:MSSecApiToken
}

function update-MSGraphApiToken{
    Param(
        [PSCredential]$creds,
        [String]$resource="https://graph.microsoft.com"
    )
    if($global:MSGraphApiToken.msApiToken -eq $Null -or $global:MSGraphApiToken.msApiToken.resource -ne $resource -or ((Get-Date).AddSeconds(600)) -gt ([timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($global:MSGraphApiToken.msApiToken.expires_on)))){
        $uri = "https://login.microsoftonline.com/$tenantId/oauth2/token"     
        $postBody = "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&client_id=$([System.Web.HttpUtility]::UrlEncode($clientId))&grant_type=password&username=$([System.Web.HttpUtility]::UrlEncode($creds.UserName))&password=$([System.Web.HttpUtility]::UrlEncode($($creds.GetNetworkCredential().Password)))"
        $global:MSGraphApiToken = @{}
        $global:MSGraphApiToken.msApiToken = ((Invoke-RestMethod -Uri $uri -Body $postBody -Method POST -ContentType 'application/x-www-form-urlencoded')) 
        $global:MSGraphApiToken.headers = @{"Authorization" = "Bearer $($global:MSGraphApiToken.msApiToken.access_token)"}
    }
    return $global:MSGraphApiToken
}

function New-RetryCommand {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments,

        [Parameter(Mandatory = $false)]
        [int]$MaxNumberOfRetries = 7,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelayInSeconds = 4
    )

    $RetryCommand = $true
    $RetryCount = 0
    $RetryMultiplier = 1

    while ($RetryCommand) {
        try {
            & $Command @Arguments
            $RetryCommand = $false
        }
        catch {
            if ($RetryCount -le $MaxNumberOfRetries) {
                Start-Sleep -Seconds ($RetryDelayInSeconds * $RetryMultiplier)
                $RetryMultiplier += 1
                $RetryCount++
            }
            else {
                throw $_
            }
        }
    }
}

#try to set TLS to v1.2, Powershell defaults to v1.0
try{
    $res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
    Write-Verbose "Set TLS protocol version to prefer v1.2"
}catch{
    Write-Output "Failed to set TLS protocol to prefer v1.2, job may fail"
    Write-Error $_ -ErrorAction SilentlyContinue
}

#get login/pw
try{
    $o365Creds = Get-AutomationPSCredential -Name $automationCredentialName -ErrorAction Stop
}catch{
    Write-Output "Failed to elevated permissions, cannot continue"
    Throw
}

Write-Output "Retrieving MDATP devices through API..."
#retrieve all MDATP devices into a single array
$DeviceData = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://api.securitycenter.microsoft.com/api/machines"; Method = "GET"; Headers = $(Update-MSSecApiToken -creds $o365Creds).headers; ErrorAction = "Stop"})
$Devices = @()
$Devices += $DeviceData.value
while($DeviceData.'@odata.nextLink'){
    $DeviceData = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = $DeviceData.'@odata.nextLink'; Method = "GET"; Headers = $(Update-MSSecApiToken -creds $o365Creds).headers; ErrorAction = "Stop"})
    $Devices += $DeviceData.value
}

Remove-Variable DeviceData
Write-Output "Retrieved $($Devices.count) MDATP devices"
$uniqueCategories = @()

#loop over all retrieved devices
foreach($Device in $Devices){
    $company = "Unknown"
    $AzureADDevice = $Null
    $registeredUsers = $Null
    if($Device.aadDeviceId){
        $AzureADDevice = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/beta/devices?`$filter=deviceId eq '$($Device.aadDeviceId)'"; Method = "GET"; Headers = $(Update-MSGraphApiToken -creds $o365Creds).headers; ErrorAction = "Stop"})
    }
    if($AzureADDevice){
        $registeredUsers = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/beta/devices/$($AzureADDevice.value.id)/registeredUsers"; Method = "GET"; Headers = $(Update-MSGraphApiToken -creds $o365Creds).headers; ErrorAction = "Stop"})
    }
    if($registeredUsers){
        foreach($user in $registeredUsers.value){
            if($user.companyName.Length -gt 0){
                $company = $user.companyName
            }
        }
    }

    $sb = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($company))
    $company =($sb -replace '[^a-zA-Z0-9 \-]', '')

    if($uniqueCategories -notcontains $company){
        $uniqueCategories += $company
    }
    
    if($Device.machineTags -notcontains $company){
        write-output "$($Device.id) ($($Device.computerDnsName)): is not tagged as $company"
        if($Device.machineTags.Count -gt 0){
            foreach($tag in $Device.machineTags){
                $Body = "{`"Value`":`"$tag`",`"Action`":`"Remove`"}"
                $res = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Body = $Body; ContentType = "application/json"; Uri = "https://api.securitycenter.windows.com/api/machines/$($Device.id)/tags"; Method = "POST"; Headers = $(Update-MSSecApiToken -creds $o365Creds).headers; ErrorAction = "Stop"})
            }
            write-output "$($Device.id) ($($Device.computerDnsName)): removed existing tags"
        }
        $Body = "{`"Value`":`"$company`",`"Action`":`"Add`"}"
        $res = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Body = $Body; ContentType = "application/json"; Uri = "https://api.securitycenter.windows.com/api/machines/$($Device.id)/tags"; Method = "POST"; Headers = $(Update-MSSecApiToken -creds $o365Creds).headers; ErrorAction = "Stop"})
        write-output "$($Device.id) ($($Device.computerDnsName)): added $company tag"
    }
}

Write-Output "All detected categories:"
Write-Output $uniqueCategories
Write-Output "Script has completed"