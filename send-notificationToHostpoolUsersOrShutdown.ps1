#Module name:       send-notificationToHostpoolUsersOrShutdown.ps1
#Author:            Jos Lieben
#Author Blog:       https://www.lieben.nu
#Created:           02-12-2021
#Updated:           see Git
#Copyright/License: Free to use / modify, but leave header intact
#Purpose:           Sends a message to all Azure Virtual Desktop users in a given subscription, or shuts down all hosts in that given subscription. Optional hostpool filter
#Requirements:      Az.DesktopVirtualization module

Login-AzAccount
Select-AzSubscription "35a2204e-dbae-415e-8eee-a4583527ae" #configure which subscription to run for.
$runForHostpool = $Null #leave at $Null to run for all hostpools
$message = "Testbericht" #specify what message to send to logged in users, if set to $Null, all hosts will be shut down instead of a message being sent
$hostpools = Get-AzWvdHostPool
foreach($hostpool in $hostpools){
    if($runForHostpool -and $runForHostpool -ne $hostpool.Name){
        continue
    }
    if($message -eq $Null){
        $hostpoolHosts = Get-AzWvdSessionHost -HostPoolName $hostpool.Name -ResourceGroupName $hostpool.Id.Split("/")[4]
        foreach($vm in $hostpoolHosts){
            Stop-AzVM -NoWait -Confirm:$False -ResourceGroupName $hostpool.Id.Split("/")[4] -Name $vm.ResourceId.Split("/")[-1] -Force
        }
    }else{
        $sessions = Get-AzWvdUserSession -HostPoolName $hostpool.Name -ResourceGroupName $hostpool.Id.Split("/")[4]
        foreach($session in $sessions){
            Send-AzWvdUserSessionMessage -HostPoolName $hostpool.Name -ResourceGroupName $hostpool.Id.Split("/")[4] -SessionHostName $session.Id.Split("/")[-3] -UserSessionId $session.Id.Split("/")[-1] -MessageTitle "SYSTEM SHUTDOWN ALERT!" -MessageBody $message
        }
    }
}