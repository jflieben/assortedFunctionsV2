<#
    .SYNOPSIS
    Retrieve graph or other azure tokens as desired (e.g. for https://main.iam.ad.ext.azure.com) and bypass MFA by repeatedly recaching the RefreshToken
    Only the first login will require an interactive / device login, subsequent logins will not require interactivity and will bypass MFA.

    This script is without warranty and not for commercial use without prior consent from the author. It is meant for scenario's where you need an Azure token to automate something that cannot yet be done with service principals.
    If your refresh token expires (default 90 days of inactivity) you'll have to rerun the script interactively.

    .EXAMPLE
    $graphToken = get-azResourceTokenSilentlyWithoutModuleDependencies -userUPN nobody@lieben.nu
    .PARAMETER userUPN
    the UPN of the user you need a token for (that is MFA enabled or protected by a CA policy)
    .PARAMETER refreshTokenCachePath
    Path to encrypted token cache if you don't want to use the default
    .PARAMETER tenantId
    If supplied, logs in to specified tenant, optional and only required if you're using Azure B2B
    .PARAMETER resource
    Resource your token is for, e.g. "https://graph.microsoft.com" would give a token for the Graph API
    .PARAMETER refreshToken
    If supplied, this is used to update the token cache and interactive login will not be required. This parameter is meant as an alternative to that initial first time interactive login
    
    .NOTES
    filename: get-azResourceTokenSilentlyWithoutModuleDependencies.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 23/04/2020
#>
Param(
    $refreshTokenCachePath=(Join-Path $env:APPDATA -ChildPath "azRfTknCache.cf"),
    $refreshToken,
    $tenantId,
    [Parameter(Mandatory=$true)]$userUPN,
    $resource="https://graph.microsoft.com",
    $clientId="1950a258-227b-4e31-a9cf-717495945fc2" #use 1b730954-1685-4b74-9bfd-dac224a7b894 for audit/sign in logs or other things that only work through the AzureAD module, use d1ddf0e4-d672-4dae-b554-9d5bdfd93547 for Intune
)

$strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName
$TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone)
[datetime]$origin = '1970-01-01 00:00:00'

if(!$tenantId){
    $tenantId = (Invoke-RestMethod "https://login.windows.net/$($userUPN.Split("@")[1])/.well-known/openid-configuration" -Method GET).userinfo_endpoint.Split("/")[3]
}

if($refreshToken){
    try{
        write-verbose "checking provided refresh token and updating it"
        $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop)
        $refreshToken = $response.refresh_token
        $AccessToken = $response.access_token
        write-verbose "refresh and access token updated"
    }catch{
        Write-Output "Failed to use cached refresh token, need interactive login or token from cache"   
        $refreshToken = $False 
    }
}

if([System.IO.File]::Exists($refreshTokenCachePath) -and !$refreshToken){
    try{
        write-verbose "getting refresh token from cache"
        $refreshToken = Get-Content $refreshTokenCachePath -ErrorAction Stop | ConvertTo-SecureString -ErrorAction Stop
        $refreshToken = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($refreshToken)
        $refreshToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($refreshToken)
        $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop)
        $refreshToken = $response.refresh_token
        $AccessToken = $response.access_token
        write-verbose "tokens updated using cached token"
    }catch{
        Write-Output "Failed to use cached refresh token, need interactive login"
        $refreshToken = $False
    }
}

#full login required
if(!$refreshToken){
    Write-Verbose "No cache file exists and no refresh token supplied, we have to perform interactive logon"
    if ([Environment]::UserInteractive) {
        foreach ($arg in [Environment]::GetCommandLineArgs()) {
            if ($arg -like '-NonI*') {
                Throw "Interactive login required, but script is not running interactively. Run once interactively or supply a refresh token with -refreshToken"
            }
        }
    }

    try{
        Write-Verbose "Attempting device sign in method"
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
    }catch{
        Throw "Interactive login failed, cannot continue"
    }
}

if($refreshToken){
    write-verbose "caching refresh token"
    Set-Content -Path $refreshTokenCachePath -Value ($refreshToken | ConvertTo-SecureString -AsPlainText -Force -ErrorAction Stop | ConvertFrom-SecureString -ErrorAction Stop) -Force -ErrorAction Continue | Out-Null
    write-verbose "refresh token cached"
}else{
    Throw "No refresh token found in cache and no valid refresh token passed or received after login, cannot continue"
}

#translate the token
try{
    write-verbose "update token for supplied resource"
    $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&grant_type=refresh_token&refresh_token=$refreshToken&client_id=$clientId&scope=openid" -ErrorAction Stop)
    $resourceToken = $response.access_token
    write-verbose "token translated to $resource"
}catch{
    Throw "Failed to translate access token to $resource , cannot continue"
}

return $resourceToken
