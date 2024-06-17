<#
    .SYNOPSIS
    Retrieves all manages devices for a given Azure AD group name and exports the data to CSV

    .NOTES
    filename: get-managedDevicesOfGroup.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
    Updated: 03/09/2021
#>

$clientId = "1950a258-227b-4e31-a9cf-717495945fc2"

$groupName = Read-Host -Prompt "Please type the group name you wish to list users+devices for"
$userUPN = Read-Host -Prompt "Please type your login name"

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

try{
    Write-Output "Checking if $groupName exists..."
    $group = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'" -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}
    if(!$group.value){throw "no group found when searching for $groupName"}
    if($group.value.count -gt 1){throw "found multiple groups, please use exact name"}
    Write-Output "Found $groupName, checking members..."
}catch{
    Throw $_
}

try{
    $groupMembers = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($group.value.id)/members" -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}
    if(!$groupMembers.value){throw "no members found!"}
    Write-Output "Found $($groupMembers.count) members in $groupName, checking devices for each member..."
}catch{
    Throw $_
}

$dataArray = @()

foreach($groupMember in $groupMembers.value){
    write-output "Checking $($groupMember.displayName)..."
    $devices = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($groupMember.id)/managedDevices" -Method GET -ContentType "application/json" -Headers @{"Authorization"="Bearer $($authResponse.access_token)"}        
    foreach($device in $devices.value){
        $device | Add-Member -MemberType NoteProperty -Name owningUserDisplayName -Value $groupMember.displayName -Force
        $device | Add-Member -MemberType NoteProperty -Name owningUserUPN -Value $groupMember.userPrincipalName -Force
        $dataArray += $device
    }
}

try{
    Write-Output "Exporting to CSV..."
    $path = Join-Path (Get-Location) -ChildPath data.csv

    $dataArray | Export-CSV -NoTypeInformation -Force -Path $path
    Write-Output "Exported to $path"
}catch{
    Throw $_
}