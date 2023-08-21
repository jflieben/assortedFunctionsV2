 function get-bitlockerEscrowStatusForAzureADDevices{
    #Requires -Modules ImportExcel
    <#
      .SYNOPSIS
      Retrieves bitlocker key upload status for all azure ad devices
      .DESCRIPTION
      Use this report to determine which of your devices have backed up their bitlocker key to AzureAD (and find those that haven't and are at risk of data loss!).
      Report will be stored in current folder.
      .EXAMPLE
      get-bitlockerEscrowStatusForAzureADDevices
      .PARAMETER Credential
      Optional, pass a credential object to automatically sign in to Azure AD. Global Admin permissions required
      .PARAMETER showBitlockerKeysInReport
      Switch, is supplied, will show the actual recovery keys in the report. Be careful where you distribute the report to if you use this
      .PARAMETER showAllOSTypesInReport
      By default, only the Windows OS is reported on, if for some reason you like the additional information this report gives you about devices in general, you can add this switch to show all OS types
      .NOTES
      filename: get-bitlockerEscrowStatusForAzureADDevices.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 9/4/2019
    #>
    [cmdletbinding()]
    Param(
        $Credential,
        [Switch]$showBitlockerKeysInReport,
        [Switch]$showAllOSTypesInReport
    )

    Import-Module AzureRM.Profile
    if (Get-Module -Name "AzureADPreview" -ListAvailable) {
        Import-Module AzureADPreview
    } elseif (Get-Module -Name "AzureAD" -ListAvailable) {
        Import-Module AzureAD
    }
 
    if ($Credential) {
        Try {
            Connect-AzureAD -Credential $Credential -ErrorAction Stop | Out-Null
        } Catch {
            Write-Warning "Couldn't connect to Azure AD non-interactively, trying interactively."
            Connect-AzureAD -TenantId $(($Credential.UserName.Split("@"))[1]) -ErrorAction Stop | Out-Null
        }
 
        Try {
            Login-AzureRmAccount -Credential $Credential -ErrorAction Stop | Out-Null
        } Catch {
            Write-Warning "Couldn't connect to Azure RM non-interactively, trying interactively."
            Login-AzureRmAccount -TenantId $(($Credential.UserName.Split("@"))[1]) -ErrorAction Stop | Out-Null
        }
    } else {
        Login-AzureRmAccount -ErrorAction Stop | Out-Null
    }
    $context = Get-AzureRmContext
    $tenantId = $context.Tenant.Id
    $refreshToken = @($context.TokenCache.ReadItems() | where {$_.tenantId -eq $tenantId -and $_.ExpiresOn -gt (Get-Date)})[0].RefreshToken
    $body = "grant_type=refresh_token&refresh_token=$($refreshToken)&resource=74658136-14ec-4630-ad9b-26e160ff0fc6"
    $apiToken = Invoke-RestMethod "https://login.windows.net/$tenantId/oauth2/token" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
    $restHeader = @{
        'Authorization' = 'Bearer ' + $apiToken.access_token
        'X-Requested-With'= 'XMLHttpRequest'
        'x-ms-client-request-id'= [guid]::NewGuid()
        'x-ms-correlation-id' = [guid]::NewGuid()
    }
    Write-Verbose "Connected, retrieving devices..."
    $restResult = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://main.iam.ad.ext.azure.com/api/Devices?nextLink=&queryParams=%7B%22searchText%22%3A%22%22%7D&top=15" -Headers $restHeader
    $allDevices = @()
    $allDevices += $restResult.value
    while($restResult.nextLink){
        $restResult = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://main.iam.ad.ext.azure.com/api/Devices?nextLink=$([System.Web.HttpUtility]::UrlEncode($restResult.nextLink))&queryParams=%7B%22searchText%22%3A%22%22%7D&top=15" -Headers $restHeader
        $allDevices += $restResult.value
    }

    Write-Verbose "Retrieved $($allDevices.Count) devices from AzureAD, processing information..."

    $csvEntries = @()
    foreach($device in $allDevices){
        if(!$showAllOSTypesInReport -and $device.deviceOSType -notlike "Windows*"){
            Continue
        }
        $keysKnownToAzure = $False
        $osDriveEncrypted = $False
        $lastKeyUploadDate = $Null
        if($device.deviceOSType -eq "Windows" -and $device.bitLockerKey.Count -gt 0){
            $keysKnownToAzure = $True
            $keys = $device.bitLockerKey | Sort-Object -Property creationTime -Descending
            if($keys.driveType -contains "Operating system drive"){
                $osDriveEncrypted = $True
            }
            $lastKeyUploadDate = $keys[0].creationTime
            if($showBitlockerKeysInReport){
                $bitlockerKeys = ""
                foreach($key in $device.bitlockerKey){
                    $bitlockerKeys += "$($key.creationTime)|$($key.driveType)|$($key.recoveryKey)|"
                }
            }else{
                $bitlockerKeys = "HIDDEN FROM REPORT: READ INSTRUCTIONS TO REVEAL KEYS"
            }
        }else{
            $bitlockerKeys = "NOT UPLOADED YET OR N/A"
        }

        $csvEntries += [PSCustomObject]@{"Name"=$device.displayName;"BitlockerKeysUploadedToAzureAD"=$keysKnownToAzure;"OS Drive encrypted"=$osDriveEncrypted;"lastKeyUploadDate"=$lastKeyUploadDate;"DeviceAccountEnabled"=$device.accountEnabled;"managed"=$device.isManaged;"ManagedBy"=$device.managedBy;"lastLogon"=$device.approximateLastLogonTimeStamp;"Owner"=$device.Owner.userPrincipalName;"bitlockerKeys"=$bitlockerKeys;"OS"=$device.deviceOSType;"OSVersion"=$device.deviceOSVersion;"Trust Type"=$device.deviceTrustType;"dirSynced"=$device.dirSyncEnabled;"Compliant"=$device.isCompliant}
    }
    $csvEntries | Export-Excel -workSheetName "BitlockerReport" -path "BitLockerReport.xlsx" -ClearSheet -TableName "BitlockerReport" -AutoSize -Verbose
}

get-bitlockerEscrowStatusForAzureADDevices