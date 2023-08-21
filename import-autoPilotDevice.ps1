<#
    .DESCRIPTION
    Imports the device this script runs on into Intune Autopilot automatically and triggers a sync.
  
    .NOTES
    filename:       import-autoPilotDevice.ps1
    author:         Jos Lieben (Lieben Consultancy)
    created:        16/06/2021
    last updated:   16/06/2021
    copyright:      2021, Jos Lieben, Lieben Consultancy, free to use and modify, not for resale
#>
$clientId = "d1ddf0e4-d672-4dae-b554-9d5bdfd93547"
$userUPN = Read-Host -Prompt "Please type your username"
$tenantId = (Invoke-RestMethod "https://login.windows.net/$($userUPN.Split("@")[1])/.well-known/openid-configuration" -Method GET).userinfo_endpoint.Split("/")[3]
$response = Invoke-RestMethod -Method POST -UseBasicParsing -Uri "https://login.microsoftonline.com/$tenantId/oauth2/devicecode" -ContentType "application/x-www-form-urlencoded" -Body "resource=https%3A%2F%2Fgraph.microsoft.com&client_id=$clientId"
Write-Output $response.message

$waited = 0
while($true){
    try{
        $authResponse = Invoke-RestMethod -uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -ContentType "application/x-www-form-urlencoded" -Method POST -Body "grant_type=device_code&resource=https%3A%2F%2Fgraph.microsoft.com&code=$($response.device_code)&client_id=$clientId" -ErrorAction Stop
        $refreshToken = $authResponse.refresh_token
        break
    }catch{
        if($waited -gt 300){
            Write-Verbose "No valid login detected within 5 minutes"
            Throw
        }
        #try again
        Start-Sleep -s 5
        $waited += 5
    }
}


Function Get-AutoPilotImportedDevice(){
    [cmdletbinding()]
    param([Parameter(Mandatory=$false)]$id)

    if ($id) {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$id"
    }else {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities"
    }
    try {
        $devices = @()
        $response = Invoke-RestMethod -Uri $uri -Headers @{"Authorization" = "Bearer $($authResponse.access_token)"} -Method Get
        if ($id) {
            $devices+=$response
        }else {
            $devices+=$response.value
            while($response.'@odata.nextLink'){
                $response = Invoke-RestMethod -Uri $response.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $($authResponse.access_token)"} -Method Get
                $devices+=$response.value
            }
        }
        $devices
    }catch {
        $_
        Exit
    }

}

Function Get-AutoPilotDevice(){
    [cmdletbinding()]
    param([Parameter(Mandatory=$false)]$id)

    if ($id) {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$id"
    }else {
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
    }
    try {
        $devices = @()
        $response = Invoke-RestMethod -Uri $uri -Headers @{"Authorization" = "Bearer $($authResponse.access_token)"} -Method Get
        if ($id) {
            $devices+=$response
        }else {
            $devices+=$response.value
            while($response.'@odata.nextLink'){
                $response = Invoke-RestMethod -Uri $response.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $($authResponse.access_token)"} -Method Get
                $devices+=$response.value
            }
        }
        $devices
    }catch {
        $_
        Exit
    }

}

Function Add-AutoPilotImportedDevice(){
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true)] $serialNumber,
        [Parameter(Mandatory=$true)] $hardwareIdentifier
    )
   
    $json = @"
{
    "@odata.type": "#microsoft.graph.importedWindowsAutopilotDeviceIdentity",
    "orderIdentifier": "",
    "serialNumber": "$serialNumber",
    "productKey": "",
    "hardwareIdentifier": "$hardwareIdentifier",
    "state": {
        "@odata.type": "microsoft.graph.importedWindowsAutopilotDeviceIdentityState",
        "deviceImportStatus": "pending",
        "deviceRegistrationId": "",
        "deviceErrorCode": 0,
        "deviceErrorName": ""
        }
}
"@

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities" -Headers @{"Authorization" = "Bearer $($authResponse.access_token)"} -Method Post -Body $json -ContentType "application/json"
    }catch {
        $_
        break
    }
}

Function Invoke-AutopilotSync(){
    [cmdletbinding()]
    param()
    $uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync"
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{"Authorization" = "Bearer $($authResponse.access_token)"} -Method Post
        $response.Value
    }catch {
        $_
        break
    }
}

try{
    $session = New-CimSession
    $serial = (Get-CimInstance -CimSession $session -Class Win32_BIOS).SerialNumber
    $devDetail = (Get-CimInstance -CimSession $session -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'")
    if($devDetail){
        $hash = $devDetail.DeviceHardwareData
    }else{
        Write-Error "Failed to get device hardware hash! Cannot continue" -ErrorAction Stop
    }
    Remove-CimSession $session
}catch{
    Write-Host $_
    Exit
}

$alreadyImportedDevices = Get-AutoPilotImportedDevice
if($alreadyImportedDevices.serialNumber -contains $serial){
    Write-Host "This device has already been imported"
}else{
    Add-AutoPilotImportedDevice -serialNumber $serial -hardwareIdentifier $hash
}

Invoke-AutopilotSync
Write-Host "Waiting 120 seconds for AutoPilot Sync"
Start-Sleep -Seconds 120
Write-Host "Sync completed"

$autopilotDevices = Get-AutoPilotDevice | Where-Object {$_.serialNumber -eq $serial}
if($autopilotDevices){
    Write-Host "Your device has synced to Autopilot and is ready for its next user!"
    foreach($device in $autopilotDevices){
        Write-Host "$($device.serialNumber) $($device.model) $($device.manufacturer) $($device.systemFamily)"
    }
}else{
    Write-Error "The device was not detected in autopilot, the import may be delayed or have failed" -ErrorAction Stop
}
