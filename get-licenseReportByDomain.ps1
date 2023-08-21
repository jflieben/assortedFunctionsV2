<#
.DESCRIPTION
Generates a HTML report of all licenses used per domain and emails it as an html table to the specified recipient.
Runs in Azure without a user account, only a managed identity with correct permissions is required

.NOTES
runbook name:       get-licenseReportbyDomain.ps1
author:             Jos Lieben (Lieben Consultancy)
created:            28/09/2021
last updated:       28/09/2021
Copyright/License:  https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)

Before this runbook, make sure you assign the correct rights to the managed identity of your automation account:
required MS Graph Permissions (application level): (Organization.Read.All AND User.Read.All AND Mail.Send) OR (Directory.Read.All AND Mail.Send)

assign MS Graph Rights to a Managed Identity using: https://gitlab.com/Lieben/assortedFunctions/-/blob/master/add-roleToManagedIdentity.ps1

#>
#Requires -modules Az.Accounts

Param(
    [Parameter(Mandatory = $true)][String]$recipientAddress,
    [Parameter(Mandatory = $true)][String]$sentFromUPN
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

Write-Output "Retrieving subscribed SKU's"
$headers = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/v1.0/subscribedSkus"; Method = "GET"; Headers = $graphHeaders; ErrorAction = "Stop"}).value.skuPartNumber

Write-Output "Retrieving users..."
$users = @()
$rawUsers = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/beta/Users?`$select=companyName,displayName,mail,userPrincipalName,id"; Method = "GET"; Headers = $graphHeaders; ErrorAction = "Stop"})
$users += $rawUsers.Value
Write-Output "Retrieved first batch of $($users.Count) users"

while($rawUsers.'@odata.nextLink'){
    $rawUsers = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = $rawUsers.'@odata.nextLink'; Method = "GET"; Headers = $graphHeaders; ErrorAction = "Stop"})
    $users += $rawUsers.Value
    Write-Output "Retrieved $($users.Count) users"
}

Write-Output "Users retrieved, retrieving license information for each user"
$byDomains = @{}

for($u=0;$u -lt $users.Count;$u++){
    if($u -gt 0 -and $u % 100 -eq 0){
        Write-Output "Checked $u of $($users.Count) users"
    }
    $lics = (New-RetryCommand -Command 'Invoke-RestMethod' -Arguments @{Uri = "https://graph.microsoft.com/v1.0/users/$($users[$u].id)/licenseDetails"; Method = "GET"; Headers = $graphHeaders; ErrorAction = "Stop"}).value
    #skip users without licenses
    if(!$lics -or $lics.Count -eq 0){
        continue
    }
    try{
        $domain = $users[$u].mail.Split("@")[1]
        if(!$domain){
            Throw
        }
    }catch{
        $domain = $users[$u].UserPrincipalName.Split("@")[1]
    }

    if(!$byDomains.$domain){
        $byDomains.$domain = @{}
        foreach($header in $headers){
            $byDomains.$domain.$header=0
        }
    }

    foreach($lic in $lics){
        $byDomains.$domain.$($lic.SkuPartNumber)++
    }
}

write-output "license information retrieved" 

$byDomainsOutputArray = @()
foreach($key in $byDomains.Keys){
    $obj = [PSCustomObject]@{"domain"=$key}
    foreach($header in $headers){
        $obj | Add-Member -MemberType NoteProperty -Name $header -Value $byDomains.$key.$header
    }
    $byDomainsOutputArray += $obj
}

$totals = @{}
foreach($header in $headers){
    $totals.$header = 0
}

foreach($domain in $byDomainsOutputArray){
    foreach($header in $headers){
        $totals.$header += $domain.$header
    }
}

$obj = [PSCustomObject]@{"domain"="Total"}

foreach($header in $headers){
    $obj | Add-Member -MemberType NoteProperty -Name $header -Value $totals.$header
}

$byDomainsOutputArray+=$obj

Write-Output "licensed parsed, sending mail..."

$htmlTable = $byDomainsOutputArray | ConvertTo-Html -As Table

$body = @{
    "message"=@{
        "subject" = "License report"
        "body" = @{
            "contentType" = "HTML"
            "content" = [String]$htmlTable
        }
        "toRecipients" = @(
            [PSCustomObject]@{
                "emailAddress" = [PSCustomObject]@{"address"=$recipientAddress}
            }   
        )
    };
    "saveToSentItems"=$False
}

Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$sentFromUPN/sendMail" -Method POST -Headers $graphHeaders -Body ($body | convertto-json -depth 10) -ContentType "application/json"

Write-Output "Mail sent, script has completed"