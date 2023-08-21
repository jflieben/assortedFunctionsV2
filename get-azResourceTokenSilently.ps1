
<#
    .SYNOPSIS
    Retrieve graph or other azure tokens as desired (e.g. for https://main.iam.ad.ext.azure.com / 74658136-14ec-4630-ad9b-26e160ff0fc6) and bypass MFA by repeatedly recaching the RefreshToken stolen from the TokenCache of the Az module.
    Only the first login will require an interactive login, subsequent logins will not require interactivity and will bypass MFA.

    This script is without warranty and not for commercial use without prior consent from the author. It is meant for scenario's where you need an Azure token to automate something that cannot yet be done with service principals.
    If your refresh token expires (default 90 days of inactivity) you'll have to rerun the script interactively.

    .EXAMPLE
    $graphToken = get-azResourceTokenSilently -userUPN nobody@lieben.nu
    .PARAMETER userUPN
    the UPN of the user you need a token for (that is MFA enabled or protected by a CA policy)
    .PARAMETER refreshTokenCachePath
    Path to encrypted token cache if you don't want to use the default
    .PARAMETER tenantId
    If supplied, logs in to specified tenant, optional and only required if you're using Azure B2B
    .PARAMETER resource
    Resource your token is for, e.g. "https://graph.microsoft.com" would give a token for the Graph API, "74658136-14ec-4630-ad9b-26e160ff0fc6" for the 'hidden' Azure Portal API
    .PARAMETER refreshToken
    If supplied, this is used to update the token cache and interactive login will not be required. This parameter is meant as an alternative to that initial first time interactive login
    
    .NOTES
    filename: get-azResourceTokenSilently.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 09/04/2020
#>
Param(
    $refreshTokenCachePath=(Join-Path $env:APPDATA -ChildPath "azRfTknCache.cf"),
    $refreshToken,
    $tenantId,
    [Parameter(Mandatory=$true)]$userUPN,
    $resource="https://graph.microsoft.com"
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
    Write-Verbose "No cache file exists and no refresh token supplied, perform interactive logon"
    if ([Environment]::UserInteractive) {
        foreach ($arg in [Environment]::GetCommandLineArgs()) {
            if ($arg -like '-NonI*') {
                Throw "Interactive login required, but script is not running interactively. Run once interactively or supply a refresh token with -refreshToken"
            }
        }
    }

    Import-Module az.accounts -erroraction silentlycontinue | out-null

    if(!(Get-Module -Name "Az.Accounts")){
        Throw "Az.Accounts module not installed!"
    }
    Write-Verbose "Calling Login-AzAccount"
    if($tenantId){
        $Null = Login-AzAccount -Tenant $tenantId -ErrorAction Stop
    }else{
        $Null = Login-AzAccount -ErrorAction Stop
    }

    #if login worked, we should have a Context
    $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
    if($context){
        Write-verbose "logged in, checking local refresh tokens..."
        $string = [System.Text.Encoding]::Default.GetString($context.TokenCache.CacheData)
        $marker = 0
        $tokens = @()
        while($true){
            $marker = $string.IndexOf("https://",$marker)
            if($marker -eq -1){break}
            $uri = $string.SubString($marker,$string.IndexOf("RefreshToken",$marker)-4-$marker)
            $marker = $string.IndexOf("RefreshToken",$marker)+15
            if($string.Substring($marker+2,4) -ne "null"){
                $refreshtoken = $string.SubString($marker,$string.IndexOf("ResourceInResponse",$marker)-3-$marker)
                $marker = $string.IndexOf("ExpiresOn",$marker)+31
                $expirydate = $string.SubString($marker,$string.IndexOf("OffsetMinutes",$marker)-6-$marker)
                $tokens += [PSCustomObject]@{"expiresOn"=[System.TimeZoneInfo]::ConvertTimeFromUtc($origin.AddMilliseconds($expirydate), $TZ);"refreshToken"=$refreshToken;"target"=$uri}
            }
        }       
        $refreshToken = @($tokens | Where-Object {$_.expiresOn -gt (get-Date)} | Sort-Object -Descending -Property expiresOn)[0].refreshToken
        write-verbose "updating stolen refresh token"
        $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "grant_type=refresh_token&refresh_token=$refreshToken" -ErrorAction Stop)
        $refreshToken = $response.refresh_token
        $AccessToken = $response.access_token
        write-verbose "tokens updated"

    }else{
        Throw "Login-AzAccount failed, cannot continue"
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
    $response = (Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&grant_type=refresh_token&refresh_token=$refreshToken&client_id=1950a258-227b-4e31-a9cf-717495945fc2&scope=openid" -ErrorAction Stop)
    $resourceToken = $response.access_token
    write-verbose "token translated to $resource"
}catch{
    Throw "Failed to translate access token to $resource , cannot continue"
}

return $resourceToken
