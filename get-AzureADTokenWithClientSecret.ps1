Param(
    $tenantId,
    $clientId,
    $clientSecret,
    $scope #eg: 'api://myapp'
)

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$body = @{
    client_id=$clientId;
    client_secret=$clientSecret;
    scope=$scope;
    grant_type='client_credentials'
}

Write-Output $((invoke-webrequest -uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
-Method POST -ContentType "application/x-www-form-urlencoded" -Body $body).Content | convertfrom-json | select access_token -ExpandProperty access_token)

