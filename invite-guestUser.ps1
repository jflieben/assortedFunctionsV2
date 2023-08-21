<#
.DESCRIPTION
Generates an invitation to a user, and automatically adds this user to a specified security group

.NOTES
runbook name:       invite-guestUser.ps1
author:             Jos Lieben (Lieben Consultancy)
created:            04/10/2021
last updated:       04/10/2021
Copyright/License:  https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)

Before this runbook, make sure you assign the correct rights to the managed identity of your automation account:
required MS Graph Permissions (application level): Directory.Read.All AND User.Invite.All AND GroupMember.ReadWrite.All (the latter is only required if using targetGroupGUID)

assign MS Graph Rights to a Managed Identity using: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/add-roleToManagedIdentity.ps1

#>
#Requires -modules Az.Accounts

Param(
    [Parameter(Mandatory = $true)][String]$recipientAddress,
    [Parameter(Mandatory = $true)][String]$recipientName,
    [Parameter(Mandatory = $true)][String]$redirectUrl="https://xxxx.sharepoint.com/sites/xxxx/SitePages/Welcome-to-xxxx.aspx",
    [String]$targetGroupGUID = "c3489171-462d-4b68-a741-f90b61b457b7" #if specified, adds guest user to this group
)

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

$res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
Write-Verbose "Set TLS protocol version to prefer v1.2"

#log in as managed identity to populate the token cache
try{
    Write-Output "Logging in with MI"
    $Null = Connect-AzAccount -Identity
    Write-Output "Logged in as MI"
}catch{
    Throw $_
}

#get a token for the Graph API using the MI token cache
try{
    Write-Output "Authenticating with the Graph API"
    $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
    $graphToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com").AccessToken
    Write-Output "Got token for Graph API"
}catch{
    Write-Output "Failed to retrieve Graph token, cannot continue"
    Throw $_
}

$graphHeaders = @{"Authorization" = "Bearer $graphToken"}

Write-Output "Checking if a user already exists..."
$odataFilter = $recipientAddress.Replace("@","_")
$user = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/v1.0/users?`$filter=startsWith(userPrincipalName,'$odataFilter')&`$select=externalUserState,displayName,id,userPrincipalName,userType"; Method = "GET"; Headers = $graphHeaders; ErrorAction = "Stop"}).value

$existingUser = $Null
if($user.Count -gt 0){
    if($user.count -gt 1){
        Throw "Error: more than 1 invitations for this email address!"
    }
    $existingUser = $user[0]
    write-output "Discovered existing invitation $($existingUser.displayName)"
}

if($existingUser -and $existingUser.externalUserState -ne "Accepted"){
    Write-Output "User has not yet redeemed an invitation, will resend invitation"
    $existingUser = $Null
}

if($existingUser -and $existingUser.externalUserState -eq "Accepted"){
    $userGuid = $existingUser.id
}

if(!$existingUser){
    Write-Output "Sending invitation to $recipientAddress"
    $body = @{
        "invitedUserEmailAddress" = $recipientAddress
        "inviteRedirectUrl" = $redirectUrl
        "sendInvitationMessage" = $True
        "invitedUserDisplayName" = $recipientName
    }
    $invitationMetadata = New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/v1.0/invitations"; Method = "POST"; Body = ($body | convertto-json);Headers = $graphHeaders; ErrorAction = "Stop"}
    $userGuid = $invitationMetadata.invitedUser.id               
}

#if a target group was specified, check if the guest is a member and if not, add
if($targetGroupGUID -and $userGuid){
    $retVal = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$userGuid/checkMemberGroups" -Method POST -Body "{`"groupIds`":[`"$targetGroupGUID`"]}" -Headers $graphHeaders -ErrorAction Stop -ContentType "application/json").value
    if($retVal -eq $targetGroupGUID){
        Write-Output "Guest is already a member of $($targetGroupGUID)"
    }else{
        Write-Output "Group $($targetGroupGUID) specified, adding user to group..."
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupGUID/members/`$ref" -Body "{`"@odata.id`":`"https://graph.microsoft.com/v1.0/directoryObjects/$userGuid`"}" -Method POST -Headers $graphHeaders -ContentType "application/json"
    }
}

Write-Output "script has completed"