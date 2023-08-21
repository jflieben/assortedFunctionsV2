Param(
    $clientID,
    $tenantId,
    $scope,
    $cert #provide a cert object as created with New-AzureADAppManifestKeyCredentials.ps1
)

$base64Thumbprint = [System.Convert]::ToBase64String(($cert.GetCertHash()))

$header = @{
    alg = "RS256"
    typ = "JWT"
    x5t = $base64Thumbprint} | ConvertTo-Json -Compress

$claimsPayload = @{
    aud = "https://login.microsoftonline.com/$tenantid/oauth2/token"
    exp = [math]::Round(((New-TimeSpan -Start ((Get-Date "1970-01-01T00:00:00Z" ).ToUniversalTime()) -End (Get-Date).ToUniversalTime().AddMinutes(2)).TotalSeconds),0)
    iss = $clientID
    jti = (New-Guid).Guid
    nbf = [math]::Round(((New-TimeSpan -Start ((Get-Date "1970-01-01T00:00:00Z" ).ToUniversalTime()) -End ((Get-Date).ToUniversalTime())).TotalSeconds),0)
    sub = $clientID
} | ConvertTo-Json -Compress

$headerjsonbase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($header)).Split('=')[0].Replace('+', '-').Replace('/', '_')
$claimsPayloadjsonbase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($claimsPayload)).Split('=')[0].Replace('+', '-').Replace('/', '_')

$preJwt = $headerjsonbase64 + "." + $claimsPayloadjsonbase64
$signature = [Convert]::ToBase64String($cert.PrivateKey.SignData([System.Text.Encoding]::UTF8.GetBytes($preJwt),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) -replace '\+','-' -replace '/','_' -replace '='

$jwt = $headerjsonbase64 + "." + $claimsPayloadjsonbase64 + "." + $signature

$body = @{
    'tenant' = $tenantid
    'scope' = $scope
    'client_assertion_type' = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
    'client_id'     = $clientID
    'grant_type'    = 'client_credentials'
    'client_assertion' = $jwt
}

(Invoke-RestMethod -uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing).Access_Token