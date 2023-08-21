<#
    .DESCRIPTION
    Sets the interface metric of a given VPN connection to 1 to ensure all traffic with a route through that VPN actually gets sent there instead of through another OS adapter
    Can easily be adapted to configure other VPN properties by modifying 'targetProperty'
  
    .NOTES
    filename:               set-vpnConnectionInterfaceMetric.ps1
    author:                 Jos Lieben (Lieben Consultancy)
    created:                21/02/2022
    last updated:           see Git
    Copyright/License:      https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)
#>

####CONFIG
[String]$connectionName = "AzureVirtualNetwork"
[String]$targetProperty = "IpInterfaceMetric"
$desiredValue = 1

if($Env:USERPROFILE.EndsWith("system32\config\systemprofile")){
    Write-Host "Running as SYSTEM, this script should run in user context!"
    Exit 1
}

$mode = $MyInvocation.MyCommand.Name.Split(".")[0]

try{
    $rasFilePath = Join-Path $env:appdata -ChildPath "\Microsoft\Network\Connections\Pbk\rasphone.pbk"
    if(!(Test-Path $rasFilePath)){
        Write-Error "No VPN Profiles detected" -ErrorAction Continue
        Write-Host "No VPN Profiles detected"
        Exit 1
    }
}catch{
    Write-Host "Could not find VPN profiles file because of $($_)"
    Exit 1
}

try{
    $rasProfiles = Get-Content $rasFilePath
    $profile = $rasProfiles | Select-String "\[$($connectionName)\]"
    if(!$profile.Matches.Count -eq 1){
        Write-Error "$connectionName VPN Profile not found" -ErrorAction Continue
        Write-Host "$connectionName VPN Profile not found"
        Exit 1
    }

    $targetPropertyMatch = $rasProfiles | Select-String "$targetProperty" | Where{$_.LineNumber -le $profile.LineNumber+152}
    if(!$targetPropertyMatch.Matches.Count -eq 1){
        Write-Error "$connectionName VPN Profile does not have an $targetProperty" -ErrorAction Continue
        Write-Host "$connectionName VPN Profile does not have an $targetProperty"
        Exit 1
    }
}catch{
    Write-Host "Issue parsing VPN profile on machine becasue of $($_)"
    Exit 1
}

if($mode -eq "detect"){
    if($targetPropertyMatch.Line.Split("=")[1] -ne $desiredValue){
        Write-Host "$connectionName VPN Profile has an invalid $targetProperty of $($targetPropertyMatch.Line.Split("=")[1]), remediating..."
        Exit 1
    }else{
        Write-Host "$targetProperty is configured correctly at $desiredValue"
        Exit 0
    }
}

#remediation logic
try{
    $rasProfiles[$targetPropertyMatch.LineNumber-1] = "$targetProperty=$($desiredValue)"
    $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
    [System.IO.File]::WriteAllLines($rasFilePath, $rasProfiles, $Utf8NoBomEncoding)
    Write-Host "$connectionName VPN Profile $targetProperty updated to $desiredValue"
    Exit 0
}catch{
    Write-Host "Failed to update $connectionName VPN Profile $targetProperty to $desiredValue because of $($_)"
    Write-Error "Failed to update $connectionName VPN Profile $targetProperty to $desiredValue" -ErrorAction Continue
    Exit 1
}

