using namespace System.Net
<#
    .SYNOPSIS
    This script adds X users from Group A to Group B. Optionally, it can group users from Group A by a specific property, processing e.g. by country instead of randomly
    This script should be scheduled as an Azure Runbook to implement e.g. a new feature tied to Group B, e.g. a new policy in Intune
    Before running, enable Managed Identity on the automation account and assign GroupMember.ReadWrite.All permissions to it e.g. by using:
    https://gitlab.com/Lieben/assortedFunctions/-/blob/master/add-roleToManagedIdentity.ps1

    .NOTES
    filename: add-batchToGroup.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: Lieben Consultancy, free to use
    site: https://www.lieben.nu
    Created: 27/08/2021
    Updated: 18/10/2021
#>
#Requires -Modules Az.Accounts

Param(
    [Parameter(Mandatory=$true)][String]$sourceGroupGuid,
    [Parameter(Mandatory=$true)][String]$targetGroupGuid,
    [Parameter(Mandatory=$true)][Int]$increment,
    [String]$groupByProperty
)

function Update-MSApiToken{
    #get a token for the Graph API using the MI token cache
    if($Null -eq $global:startTime){
        $global:startTime = Get-Date
    }
    if($Null -eq $global:msApiToken.msApiToken -or (Get-Date).AddSeconds(-500) -gt $global:startTime){
        $global:startTime = Get-Date
        try{
            Write-Host "Authenticating with the Graph API"
            $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
            $global:msApiToken = @{}
            $global:msApiToken.msApiToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com")
            $global:msApiToken.headers = @{"Authorization" = "Bearer $($global:msApiToken.msApiToken.AccessToken)"}
            Write-Host "Got token for Graph API"
        }catch{
            Write-Host "Failed to retrieve Graph token, cannot continue"
            Throw $_
        }
    }
    return $global:msApiToken
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

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
try{
    Write-Output "Logging in with MI"
    $Null = Connect-AzAccount -Identity
    Write-Output "Logged in as MI"
}catch{
    Throw $_
}

Write-Output "Starting batch sync of $increment users from $sourceGroupGuid to $targetGroupGuid"

$additionalFilter = $Null
if($groupByProperty){
    $additionalFilter = ",$($groupByProperty)"
}

Write-Output "Retrieving members of source group $sourceGroupGuid"

$sourceGroupMembers = @()
try{
    $sourceGroupMembersBatch = (New-RetryCommand -MaxNumberOfRetries 2 -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/v1.0/groups/$sourceGroupGuid/members?`$select=id$($additionalFilter)"; Method = "GET"; Headers = $(Update-MSApiToken).headers; ErrorAction = "Stop"})
}catch{
    Write-Output "Failed to retrieve source group members, aborting, see next error for details"
    Throw $_
}
$sourceGroupMembers += $sourceGroupMembersBatch.value

Write-Output "Current count: $($sourceGroupMembers.Count)"

while($sourceGroupMembersBatch.'@odata.nextLink'){
    $sourceGroupMembersBatch = (New-RetryCommand -MaxNumberOfRetries 5 -Command 'Invoke-RestMethod' -Arguments @{Uri = $sourceGroupMembersBatch.'@odata.nextLink'; Method = "GET"; Headers = $(Update-MSApiToken).headers; ErrorAction = "Stop"})
    $sourceGroupMembers += $sourceGroupMembersBatch.value
    Write-Output "Current count: $($sourceGroupMembers.Count)"
}

if($groupByProperty){
    $sourceGroupMembers = $sourceGroupMembers | Sort-Object -Descending -Property $groupByProperty
}

Write-Output "Retrieving members of target group $targetGroupGuid"

$targetGroupMembers = @()
try{
    $targetGroupMembersBatch = (New-RetryCommand -MaxNumberOfRetries 2 -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/v1.0/groups/$targetGroupGuid/members?`$select=id"; Method = "GET"; Headers = $(Update-MSApiToken).headers; ErrorAction = "Stop"})
}catch{
    Write-Output "Failed to retrieve target group members, aborting, see next error for details"
    Throw $_
}
Write-Output "Current count: $($targetGroupMembers.Count)"
$targetGroupMembers += $targetGroupMembersBatch.value

while($targetGroupMembersBatch.'@odata.nextLink'){
    $targetGroupMembersBatch = (New-RetryCommand -MaxNumberOfRetries 5 -Command 'Invoke-RestMethod' -Arguments @{Uri = $targetGroupMembersBatch.'@odata.nextLink'; Method = "GET"; Headers = $(Update-MSApiToken).headers; ErrorAction = "Stop"})
    $targetGroupMembers += $targetGroupMembersBatch.value
    Write-Output "Current count: $($targetGroupMembers.Count)"
}

Write-Output "Adding $increment users from source to target group"
$added = 0
for($i=0;$i -lt $sourceGroupMembers.Count;$i++){
    if($added -ge $increment){
        break
    }
    if($targetGroupMembers.id -notcontains $sourceGroupMembers[$i].id){
        Write-Output "Adding $($sourceGroupMembers[$i].id) to target group"
        try{
            $res = New-RetryCommand -MaxNumberOfRetries 5 -Command 'Invoke-RestMethod' -Arguments @{Body = "{`"@odata.id`":`"https://graph.microsoft.com/v1.0/directoryObjects/$($sourceGroupMembers[$i].id)`"}" ;Uri = "https://graph.microsoft.com/v1.0/groups/$($targetGroupGuid)/members/`$ref"; Method = "POST"; Headers = $(Update-MSApiToken).headers; ContentType ="application/json"; ErrorAction = "Stop"}
            $added++
            Write-Output "Added $($sourceGroupMembers[$i].id) to target group"
        }catch{
            Write-Output "FAILED TO ADD $($sourceGroupMembers[$i].id) to target group"
            Write-Error $_ -ErrorAction Continue
        }
    }
}

if($added -eq 0){
    Write-Output "All members of source group have already been added to target group"
}else{
    Write-Output "Added $added members from source group to target group"
}
Write-Output "Job completed"