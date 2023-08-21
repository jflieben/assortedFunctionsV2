#Requires -Modules AzureAD
<#
    .DESCRIPTION
    Cleans up any duplicate devices in Azure AD that have the same hardware ID, by only leaving the most recently active one enabled

    .PARAMETER WhatIf
    If specified, will not remove/disable anything (report-only mode).
    -Force overrides -WhatIf

    .PARAMETER Force
    If specified, devices will be REMOVED instead of disabled
    NOTE: -Force overrides -WhatIf!

    .NOTES
    author: Jos Lieben
    blog: www.lieben.nu
    created: 17/12/2019
    editied: 07/30/2020
    Modified by: Powershellcrack
    
    .CHANGES
    - Added it as a function 
    - changed cmdlets to AzureAD
#>
function Invoke-AzureADCleanup {
    Param(
        [Switch]$WhatIf,
        [Switch]$Force
    )
    Begin {
        Write-Verbose "Checking Azure Connection"
        try{
            $null = Connect-AzureAD
        }catch{
            Throw "Not authenticated.  Please use the `"Connect-AzureAD`" command to authenticate."
        }
    }
    Process {
        #get all enabled AzureAD devices
        $devices = Get-AzureADDevice -All:$true | Where{$_.AccountEnabled}
        $hwIds = @{}
        $duplicates=@{}

        #create hashtable with all devices that have a Hardware ID
        foreach($device in $devices){
            $physId = $Null
            foreach($deviceId in $device.DevicePhysicalIds){
                if($deviceId.StartsWith("[HWID]")){
                    $physId = $deviceId.Split(":")[-1]
                }
            }
            if($physId){
                if(!$hwIds.$physId){
                    $hwIds.$physId = @{}
                    $hwIds.$physId.Devices = @()
                    $hwIds.$physId.DeviceCount = 0
                }
                $hwIds.$physId.DeviceCount++
                $hwIds.$physId.Devices += $device
            }
        }

        #select HW ID's that have multiple device entries
        $hwIds.Keys | % {
            if($hwIds.$_.DeviceCount -gt 1){
                $duplicates.$_ = $hwIds.$_.Devices
            }
        }

        #loop over the duplicate HW Id's
        $cleanedUp = 0
        $totalDevices = 0
        foreach($key in $duplicates.Keys){
            $mostRecent = (Get-Date).AddYears(-100)
            foreach($device in $duplicates.$key){
                $totalDevices++
                #detect which device is the most recently active device
                if([DateTime]$device.ApproximateLastLogonTimestamp -gt $mostRecent){
                    $mostRecent = [DateTime]$device.ApproximateLastLogonTimestamp
                }
            }

            foreach($device in $duplicates.$key){
                if([DateTime]$device.ApproximateLastLogonTimestamp -lt $mostRecent){
                    try{
                        if($Force){
                            Remove-AzureADDevice -ObjectId $device.objectId -verbose  -ErrorAction Stop
                            Write-Output "Removed Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp)"
                        }elseif($WhatIf){
                            Write-Output "Should disable Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp)"               
                        }else{
                            Disable-AzureADDevice -ObjectId $device.objectId -verbose  -ErrorAction Stop
                            Write-Output "Disabled Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp)"
                        }
                        $cleanedUp++
                    }catch{
                        Write-Output "Failed to disable Stale device $($device.DisplayName) with last active date: $($device.ApproximateLastLogonTimestamp)"
                        Write-Output $_.Exception
                    }
                }
            }
        }

        Write-Output "Total unique hardware ID's with >1 device registration: $($duplicates.Keys.Count)"

        Write-Output "Total devices registered to these $($duplicates.Keys.Count) hardware ID's: $totalDevices" 

        Write-Output "Devices cleaned up: $cleanedUp"

        <# fun snippet to get distribution:
        $distribution = @{}
        foreach($key in $duplicates.Keys){
            if($distribution.$($duplicates.$key.Count)){
                [Int]$distribution.$($duplicates.$key.Count)++ | out-null
            }else{
                [Int]$distribution.$($duplicates.$key.Count) = 1
            }
        }
        Write-Output $distribution
        #>
    }
    End {
    }
}

Invoke-AzureADCleanup -WhatIf
