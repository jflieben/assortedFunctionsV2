#Author: Jos Lieben
#Creating a RunAs account programmatically
Param(
    $subscriptionId,
    $tenantId,
    $automationAccountName,
    $resourceGroupName,
    $userName,
    $password,
    $region
)

#load assemblies
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")

#get a token for the API
$body = @{
    client_id="1950a258-227b-4e31-a9cf-717495945fc2"
    resource="https://graph.windows.net"
    grant_type="password"
    username=$userName
    password=$password
    scope="openid"
}
$token = $((invoke-webrequest -uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -Method POST -ContentType "application/x-www-form-urlencoded" -Body $body).Content | convertfrom-json | select access_token -ExpandProperty access_token)

#build header
$headers = @{
    "Authorization" = "Bearer $token"
    "x-ms-client-request-id"=[Guid]::NewGuid()
}

#phase 1 of new account
$uri = "https://s2.automation.ext.azure.com/api/Orchestrator/CreateAzureRunAsAccountForExistingAccount?accountResourceId=%2Fsubscriptions%2F$subscriptionId%2FresourceGroups%2F$resourceGroupName%2Fproviders%2FMicrosoft.Automation%2FautomationAccounts%2F$automationAccountName"
$payload = @{
    "accountResourceId"="/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName"
    "servicePrincipalScopeId"="/subscriptions/$subscriptionId"    
}
$res = Invoke-RestMethod -Method POST -UseBasicParsing -Uri $uri -Body ($payload | ConvertTo-Json -Depth 10) -ContentType "application/json" -Headers $headers

#get new token for the API
$body = @{
    client_id="1950a258-227b-4e31-a9cf-717495945fc2"
    resource="https://management.core.windows.net/"
    grant_type="password"
    username=$userName
    password=$password
    scope="openid"
}
$token = $((invoke-webrequest -uri "https://login.microsoftonline.com/$tenantId/oauth2/token" -Method POST -ContentType "application/x-www-form-urlencoded" -Body $body).Content | convertfrom-json | select access_token -ExpandProperty access_token)

#build new header
$headers = @{
    "Authorization" = "Bearer $token"
    "x-ms-client-request-id"=[Guid]::NewGuid()
}

#phase 2 of new account
$uri = "https://s2.automation.ext.azure.com/api/Orchestrator/CreateAzureRunAsAccountRolesAssetsAndTutorialRunbookForExistingAccountUsingArmToken?accountResourceId=%2Fsubscriptions%2F$subscriptionId%2FresourceGroups%2F$resourceGroupName%2Fproviders%2FMicrosoft.Automation%2FautomationAccounts%2F$automationAccountName&region=$region"
$payload = @{
    "accountResourceId"="/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName"
    "servicePrincipalName"=$Null
    "servicePrincipalScopeId"="/subscriptions/$subscriptionId"  
    "certificateValue"=$res.certificateValue
    "aadApplicationId"=$res.aadApplicationId
    "servicePrincipalObjectId"=$res.servicePrincipalObjectId
    "previousServicePrincipalObjectId"=$null  
}
$res = Invoke-RestMethod -Method POST -UseBasicParsing -Uri $uri -Body ($payload | ConvertTo-Json -Depth 10) -ContentType "application/json" -Headers $headers