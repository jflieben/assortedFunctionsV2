<#PSScriptInfo

.VERSION 1.0.2

.GUID a4167185-5eb8-4e61-93bc-3cf86394fc6b

.AUTHOR Jos Lieben

.COMPANYNAME Lieben Consultancy

.COPYRIGHT 

.TAGS 

.LICENSEURI 

.PROJECTURI https://www.lieben.nu/

.ICONURI 

#>

#Requires -Module @{ModuleName = 'MSOnline'; ModuleVersion = '1.1.183.57'}


<# 

.DESCRIPTION 
 Cleans up older duplicates of Azure Device Entries with the same hardware ID (Windows only) 

#> 
#try to set TLS to v1.2, Powershell defaults to v1.0
try{
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
    Write-Verbose "Set TLS protocol version to prefer v1.2"
}catch{
    Write-Error "Failed to set TLS protocol to prefer v1.2, script may fail" -ErrorAction Continue
    Write-Error $_ -ErrorAction Continue
}

#get O365 Creds
try{
    $script:o365credentials = Get-Credential #you can use Get-AutomationPSCredential here
    Write-Output "O365 credentials loaded"
}catch{
    Write-Error "Failed to load credentials"
    Exit
}

try{
    Connect-MsolService -Credential $script:o365credentials
}catch{
    Write-Error "Failed to connect to AzureAD"
    Exit   
}

$script:token = $Null

function update-MSApiToken{
    Param(
        [String]$resource="https://graph.windows.net/"
    )
    if($script:token -eq $Null -or $script:token.resource -ne $resource -or ((Get-Date).AddSeconds(-180)) -le ([timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($script:token.expires_on)))){
        $userName = $script:o365credentials.UserName
        $pwd = $script:o365credentials.GetNetworkCredential().Password
        $uri = "https://login.microsoftonline.com/$tenantId/oauth2/token"     
        $postBody = "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&client_id=$([System.Web.HttpUtility]::UrlEncode("1950a258-227b-4e31-a9cf-717495945fc2"))&grant_type=password&username=$([System.Web.HttpUtility]::UrlEncode($userName))&password=$([System.Web.HttpUtility]::UrlEncode($pwd))&scope=openid"
        $script:token = ((Invoke-RestMethod -Uri $uri -Body $postBody -Method POST -ContentType 'application/x-www-form-urlencoded')) 
    }
}

#automatically look up the tenant ID based on the standardized environment name
$tenantId = (Invoke-RestMethod "https://login.windows.net/$($o365credentials.UserName.Split("@")[1])/.well-known/openid-configuration" -Method GET).userinfo_endpoint.Split("/")[3]

Write-Output "Autodetected tenant ID $tenantID"

$enabledWindowsDevices = @()
try{
    update-MSApiToken
    $devices = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://graph.windows.net/$tenantId/devices?`$expand=registeredOwners&api-version=1.61-internal&`$top=100&`$filter=deviceOSType eq 'Windows' and accountEnabled eq true" -Headers @{"Authorization" = "Bearer $($script:token.access_token)"} -ContentType "application/json"
    $enabledWindowsDevices += $devices.value
    Write-Output "Initial fetch of $($devices.value.count) succeeded"
}catch{
    Write-Verbose "Failed to get a token or retrieve devices, aborting"
    Throw
}

while($devices.'odata.nextLink'){
    Write-Verbose "Fetching next 100 devices..."
    $skipToken = $devices.'odata.nextLink'.SubString($devices.'odata.nextLink'.IndexOf("skiptoken=")+10)
    $devices = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://graph.windows.net/$tenantId/devices?api-version=1.61-internal&`$expand=registeredOwners&`$filter=deviceOSType eq 'Windows' and accountEnabled eq true&`$skiptoken=$skipToken&`$top=100" -Headers @{"Authorization" = "Bearer $($script:token.access_token)"} -ContentType "application/json"
    $enabledWindowsDevices += $devices.value
    Write-Verbose "Got $($devices.value.Count) devices (total is now $($enabledWindowsDevices.Count))"
}

#get all enabled AzureAD devices
Write-Output "$($enabledWindowsDevices.count) total enabled Windows devices in environment, building hashtable..."
$hwIds = @{}
$duplicates=@{}

#create hashtable with all devices that have a Hardware ID
foreach($device in $enabledWindowsDevices){
    $physId = $Null
    foreach($deviceId in $device.DevicePhysicalIds){
        if($deviceId.StartsWith("[HWID]")){
            $physId = $deviceId.Split(":")[-1]
        }
    }
    if($physId){
        if(!$hwIds.$physId){
            $hwIds.$physId = @{}
            $hwIds.$physId.Devices = @()
            $hwIds.$physId.DeviceCount = 0
        }
        $hwIds.$physId.DeviceCount++
        $hwIds.$physId.Devices += $device
    }
}
S
Write-Output "Hashtable created, detecting duplicates...."

#select HW ID's that have multiple device entries
$hwIds.Keys | ForEach-Object{
    if($hwIds.$_.DeviceCount -gt 1){
        $duplicates.$_ = $hwIds.$_.Devices
    }
}

Write-Output "$($duplicates.Keys.Count) duplicates detected, remediating...."

#loop over the duplicate HW Id's
$cleanedUp = 0
$totalDevices = 0
foreach($key in $duplicates.Keys){
    $mostRecentlyActive = (Get-Date).AddYears(-100)
    foreach($device in $duplicates.$key){
        $totalDevices++
        #detect which device is the most recently active device
        if([DateTime]$device.ApproximateLastLogonTimestamp -gt $mostRecentlyActive){
            $mostRecentlyActive = [DateTime]$device.ApproximateLastLogonTimestamp
        }
    }
    $mostRecentlyCreated = (Get-Date).AddYears(-100)
    foreach($device in $duplicates.$key){
        #detect which device is the most recently registered device
        try{
            $createdDateTime = [DateTime]($device.deviceSystemMetadata | where {$_.key -eq "CreationTime"}).value
            if($createdDateTime -gt $mostRecentlyCreated){
                $mostRecentlyCreated = $createdDateTime
            }
        }catch{
            $createdDateTime = (Get-Date).AddYears(-100)
        }

    }

    foreach($device in $duplicates.$key){
        try{
            $createdDateTime = [DateTime]($device.deviceSystemMetadata | where {$_.key -eq "CreationTime"}).value
        }catch{
            $createdDateTime = $Null
        }
        if($createdDateTime -and $createdDateTime -lt $mostRecentlyCreated){
            try{
                Disable-MsolDevice -DeviceId $device.DeviceId -Force -Confirm:$False -ErrorAction Stop
                Write-Output "Disabled Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp) and registered date $createdDateTime"
                $cleanedUp++
            }catch{
                Write-Output "Failed to disable Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp) and registered date $createdDateTime"
                Write-Output $_.Exception
            }
            
        }
    }
}

Write-Output "Total unique hardware ID's with >1 device registration: $($duplicates.Keys.Count)"

Write-Output "Total devices registered to these $($duplicates.Keys.Count) hardware ID's: $totalDevices" 

Write-Output "Devices cleaned up: $cleanedUp"