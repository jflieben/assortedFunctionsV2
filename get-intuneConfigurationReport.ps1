function get-intuneConfigurationReport(){
    <#
      .SYNOPSIS
      Retrieve conditional access policy settings from Intune
      .DESCRIPTION
      Retrieves all conditional access policies from Intune (if policyId is omitted) and outputs their settings
      .EXAMPLE
      $policy = get-conditionalAccessPolicySettings -Username you@domain.com -Password Welcome01 -policyId 533ceb01-3603-48cb-8586-56a60153939d
      .PARAMETER Username
      the UPN of a user with sufficient permissions (global admin)
      .PARAMETER Password
      Password of Username
      .PARAMETER policyId
      GUID of the policy you wish to return, if left empty, all policies will be returned
      .NOTES
      filename: get-intuneSettingsReport.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 12/6/2018
      requires: get-conditionalAccessPolicySettings.ps1,get-deviceConfigurationPolicySettings.ps1,get-azureRMToken.ps1,get-graphTokenForIntune.ps1
    #>
    Param(
        [Parameter(Mandatory=$true)]$Username, #global administrator username
        [Parameter(Mandatory=$true)]$Password, #global administrator password
        $reportPath #path where you're like the HTML file to be stored, by default this will be on your desktop
    )
    if(!$reportPath){
        $reportPath = Join-Path ([Environment]::GetFolderPath("Desktop")) -ChildPath "IntuneSettings.html"
    }

    $html = "<html><head><title>Intune settings report</title></head><body><h1>Intune settings report</h1>"
    $graphToken = get-graphTokenForIntune -User $Username -Password $Password
    $caPolicies = get-conditionalAccessPolicySettings -Username $Username -Password $Password
    $html += "<h2>Conditional Access Policies</h2>"
    if($caPolicies.count -gt 0){
        foreach($caPolicy in $caPolicies){
            $html += "<b>$($caPolicy.policyName)</b>"
            $html += "<table border=`"1`"><tr><td><b>Setting</b></td><td><b>Details</b></td></tr>"
            if($caPolicy.usersv2.included.groupIds.count -gt 0){
                $html += "<tr><td>Applies to groups</td><td>"
                foreach($groupId in $caPolicy.usersv2.included.groupIds){
                    $graphHeader = @{
                        'Authorization' = 'Bearer ' + $graphToken
                        'X-Requested-With'= 'XMLHttpRequest'
                        'x-ms-client-request-id'= [guid]::NewGuid()
                        'x-ms-correlation-id' = [guid]::NewGuid()
                    }
                    $groupMeta = Invoke-RestMethod –Uri "https://graph.microsoft.com/beta/groups/$groupId" –Headers $graphHeader –Method GET -ErrorAction Stop
                    $html += "$($groupMeta.displayName)<br>"
                }
                $html += "</td></tr>"
            }
            $html += "<tr><td>policy ID</td><td>$($caPolicy.policyId)</td></tr>"
            $html += "<tr><td>Enabled</td><td>$($caPolicy.applyRule)</td></tr>"
            $html += "<tr><td>Blocking policy</td><td>$($caPolicy.controls.blockAccess)</td></tr>"
            $html += "<tr><td>MFA</td><td>$($caPolicy.controls.challengeWithMfa)</td></tr>"
            $html += "<tr><td>Compliant device required</td><td>$($caPolicy.controls.compliantDevice)</td></tr>"
            $html += "<tr><td>Domain joined device required</td><td>$($caPolicy.controls.domainJoinedDevice)</td></tr>"
            $html += "<tr><td>Allow only approved client apps</td><td>$($caPolicy.controls.approvedClientApp)</td></tr>"
            $html += "<tr><td>Allow only compliant apps</td><td>$($caPolicy.controls.requireCompliantApp)</td></tr>"
            $html += "<tr><td>target Exchange Active Sync</td><td>$($caPolicy.conditions.clientAppsV2.exchangeActiveSync)</td></tr>"
            $html += "<tr><td>target web browsers</td><td>$($caPolicy.conditions.clientAppsV2.webBrowsers)</td></tr>"
            $html += "<tr><td>block other clients (IMAP etc)</td><td>$($caPolicy.conditions.clientAppsV2.otherClients)</td></tr>"
            $html += "</table><br><br>"
        }
    }else{
        $html += "<p><b>No conditional access policies found</b></p>"
    }

    $dcPolicies = get-deviceConfigurationPolicySettings -Username $Username -Password $Password
    $html += "<h2>Device Configuration Policies</h2>"
    if($dcPolicies.count -gt 0){
        foreach($dcPolicy in $dcPolicies){
            $html += "<b>$($dcPolicy.displayName)</b>"
            $html += "<table border=`"1`"><tr><td><b>Setting</b></td><td><b>Details</b></td></tr>"
            if($dcPolicy.assignments.count -gt 0){
                $html += "<tr><td>Applies to groups</td><td>"
                foreach($groupId in $dcPolicy.assignments.target.groupId){
                    $graphHeader = @{
                        'Authorization' = 'Bearer ' + $graphToken
                        'X-Requested-With'= 'XMLHttpRequest'
                        'x-ms-client-request-id'= [guid]::NewGuid()
                        'x-ms-correlation-id' = [guid]::NewGuid()
                    }
                    $groupMeta = Invoke-RestMethod –Uri "https://graph.microsoft.com/beta/groups/$groupId" –Headers $graphHeader –Method GET -ErrorAction Stop
                    $html += "$($groupMeta.displayName)<br>"
                }
                $html += "</td></tr>"
            }
            $dcPolicy.PSObject.properties | % {
                $html += "<tr><td>$($_.Name)</td><td>$($_.Value)</td></tr>"
            }
            $html += "</table>"

        }
    }else{
        $html += "<p><b>No device configuration policies found</b></p>"
    }
    $html += "</body></html>"
    $html | Set-Content -Path $reportPath -Encoding UTF8
}