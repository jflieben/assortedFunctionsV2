$filePath = "C:\Windows\System32\IntegratedServicesRegionPolicySet.json"
write-host "Taking ownership of $filePath ..."
try{
    takeown /f $filePath
    icacls $filePath /grant Administrators:F /c
}catch{$Null}

write-host "Rewriting $filePath ..."

$policies = Get-Content $filePath | ConvertFrom-Json
$targetPolicy = $policies.policies | Where-Object {$_.guid -eq "{1d290cdb-499c-4d42-938a-9b8dceffe998}"}
try{
    $policies.policies[$policies.policies.IndexOf($targetPolicy)].defaultState = "enabled"
}catch{$Null}
$policies.policies[$policies.policies.IndexOf($targetPolicy)].conditions.region.disabled = @()
$policies | ConvertTo-Json -depth 10 | Set-Content $filePath -Force