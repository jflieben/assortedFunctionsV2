<#
    .SYNOPSIS
    Installs a service principal in selected Cloud Solution Provider child tenants. Meant as a POC to show how to access and manage SPN's in CSP tenants for a project where I had to grant OAuth2 permissions to said child objects.
    
    .EXAMPLE
    add-servicePrincipalToAllCSPChildTenants -primarySpnClientID "cb773612-c917-4af5-8b81-4a5222340716"
    .PARAMETER primarySpnClientID
    client ID of the service principal in the main CSP tenant that should be added/consented to in the child tenants.
   
    .NOTES
    filename: add-servicePrincipalToAllCSPChildTenants.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 25/04/2021
#>
#Requires -Modules Az.Accounts,Az.Resources

Param(
    [String]$primarySpnClientID
)

$userName = Read-Host "Enter your username (should be in the Admin Agents role)"

try{
    $connection = Login-AzAccount -Force -Confirm:$False -SkipContextPopulation -Tenant $userName.Split("@")[1] -ErrorAction Stop
    $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
    if($connection.Context.Account.Id -ne $userName){Throw "Account prompt+login do not match"}
}catch{
    Write-Host "Failed to log in and/or retrieve token, aborting" -ForegroundColor Red
    Write-Host $_
    Exit
}

Write-Host "Checking registered CSP child tenants..." -ForegroundColor Green
Try{
    $graphToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.windows.net").AccessToken
    $childTenants = invoke-restmethod -Method GET -Uri "https://graph.windows.net/$($context.Tenant.Id)/contracts?api-version=1.6" -Headers @{"Authorization"="Bearer $graphToken"} -ContentType "application/json"
    if(!$childTenants.value -or $childTenants.value.count -le 0){
        Throw "No child tenants detected"
    }
}catch{
    Write-Host "Failed to retrieve child tenants, cannot continue" -ForegroundColor Red
    Write-Host $_
    Exit
}

$childTenants = $childTenants.value

$response = Read-Host "Detected $($childTenants.Count) customers under your CSP tenant, do you wish to continue? Y/N"
if($response -ne "Y" -and $response -ne "Yes"){
    Throw "Script completed"
}

foreach($tenant in $childTenants){
    $response = Read-Host "Installing SPN in tenant $($tenant.displayName), press Y to proceed, N to skip"
    if($response -ne "Y" -and $response -ne "Yes"){
        Write-Host "$($tenant.displayName) skipped" -ForegroundColor Yellow
        continue
    }
    Write-Host "Please login using $userName if prompted" -ForegroundColor Green
    $connection = Login-AzAccount -Force -Confirm:$False -SkipContextPopulation -Tenant $tenant.customerContextId -ErrorAction Stop -DefaultProfile $context
    $secondarySP = Get-AzADServicePrincipal -ApplicationId $primarySpnClientID -DefaultProfile $connection
    if(!$secondarySP){
        Write-Host "No child service principal found in $($tenant.customerContextId), creating..." -ForegroundColor Green
        try{
            $secondarySP = New-AzADServicePrincipal -ApplicationId $primarySpnClientID -DisplayName "CSPManagementSPN" -SkipAssignment -DefaultProfile $connection
            Write-Host "SPN created successfully" -ForegroundColor Green
        }catch{
            Write-Host "Failed to create SPN!" -ForegroundColor Red
            Write-Host $_
            continue
        }
    }
    $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
    $graphToken = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com").AccessToken
   
    try{
        $resourceLocalInstance = Get-AzAdServicePrincipal -ApplicationId "00000003-0000-0000-c000-000000000000" #Graph API
        $patchBody = @{
            "clientId"= $secondarySP.id
            "consentType"= "AllPrincipals"
            "principalId"= $Null
            "resourceId"= $resourceLocalInstance.Id
            "scope"= "AuditLog.Read.All"
            "startTime"= (Get-Date).ToString("yyy-MM-ddTHH:MM:ss")
            "expiryTime"= (Get-Date).AddYears(5).ToString("yyy-MM-ddTHH:MM:ss")
        }
        try{
            $res = Invoke-RestMethod -Method POST -body ($patchBody | convertto-json) -Uri "https://graph.microsoft.com/beta/oauth2PermissionGrants" -Headers @{"Authorization"="Bearer $graphToken"} -ContentType "application/json"
            Write-Host "Permission AuditLog.Read.All for instance $($resourceLocalInstance.Id) set" -ForegroundColor Green
        }catch{
            Write-Host "Failed to set permission AuditLog.Read.All for instance $($resourceLocalInstance.Id)" -ForegroundColor Red
        }
    }catch{
        Write-Host "Failed to retrieve local instance of $($resource.resourceAppId)" -ForegroundColor Red
    }
             
    Write-Host "$($tenant.displayName) completed" -ForegroundColor Green
}

Write-Host "SPN deployment process has completed"