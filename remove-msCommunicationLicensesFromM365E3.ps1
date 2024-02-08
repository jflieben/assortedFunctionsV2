Connect-Graph -Scopes User.ReadWrite.All, Organization.Read.All

$users = Get-MgUser -All
$sku = Get-MgSubscribedSku -All | Where SkuPartNumber -eq 'SPE_E3'
foreach($user in $users){
    try{
        $userLicense = $Null; $userLicense = Get-MgUserLicenseDetail -UserId $user.id | Where {$_.SkuPartNumber -eq 'SPE_E3'}
        if(!$userLicense){
            write-Host "$($user.userPrincipalName) skipping because not M365 E3"
            continue
        }

        [Array]$userDisabledPlans = @($userLicense.ServicePlans | Where ProvisioningStatus -eq "Disabled" | Select -ExpandProperty ServicePlanId)

        $update = $False
        if($userDisabledPlans -notcontains "57ff2da0-773e-42df-b2af-ffb7a2317929"){
            $userDisabledPlans += "57ff2da0-773e-42df-b2af-ffb7a2317929"
            $update = $true
        }

        if($userDisabledPlans -notcontains "0feaeb32-d00e-4d66-bd5a-43b5b83db82c"){
            $userDisabledPlans += "0feaeb32-d00e-4d66-bd5a-43b5b83db82c"
            $update = $True
        }

        if($update){
            write-host "$($user.userPrincipalName) updating "
            $addLicenses = @(
                @{
                    SkuId = $sku.SkuId
                    DisabledPlans = $userDisabledPlans
                }
            )

            $res = Set-MgUserLicense -UserId $user.id -AddLicenses $addLicenses -RemoveLicenses @()
            write-host "$($user.userPrincipalName) updated "
        }else{
            write-Host "$($user.userPrincipalName) skipping because already disabled"
        }
    }catch{
        write-Host "$($user.userPrincipalName) FAILED: $_" -ForegroundColor Red
    }
}