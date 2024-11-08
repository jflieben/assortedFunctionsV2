function get-AccessToken{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$resource,
        [Switch]$returnHeader
    )   

    if(!$global:LCRefreshToken){
        get-AuthorizationCode
    }

    if(!$global:LCCachedTokens.$resource){
        $jwtTokenProperties = $Null
    }else{
        $jwtTokenProperties = Get-JwtTokenProperties -token $global:LCCachedTokens.$resource
    }

    if(!$global:LCCachedTokens.$resource -or !$jwtTokenProperties -or ($jwtTokenProperties -and ([timezone]::CurrentTimeZone.ToLocalTime('1/1/1970').AddSeconds($jwtTokenProperties.exp) -lt (Get-Date).AddMinutes(-10)) -or $jwtTokenProperties.aud -ne $resource)){
        Write-Verbose "Token cache miss, refreshing V1 token for $resource..."
        $response = (Invoke-RestMethod "https://login.microsoftonline.com/common/oauth2/token" -Method POST -Body "resource=$([System.Web.HttpUtility]::UrlEncode($resource))&grant_type=refresh_token&refresh_token=$($global:LCRefreshToken)&client_id=$($global:LCClientId)&scope=openid" -ErrorAction Stop -Verbose:$false)
        if($response.refresh_token -and $response.access_token){
            if($response.refresh_token){ 
                $global:LCRefreshToken = $response.refresh_token 
            }                
            $global:LCCachedTokens.$resource = $response.access_token
        }else{
            Write-Error "Failed to retrieve access and/or refresh token! Please reload PowerShell / this module to refresh or google this error: $_" -ErrorAction Stop
        }
    }else{
        Write-Verbose "Token cache hit, using cached token :)"
    }

    if($returnHeader){
        return @{
            Authorization = "Bearer $($global:LCCachedTokens.$resource)"
        }
    }else{
        return $global:LCCachedTokens.$resource
    }
}
