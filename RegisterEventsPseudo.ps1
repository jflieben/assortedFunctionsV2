$slept = 0;$script:refreshNeeded = $false;
$sysevent = [microsoft.win32.systemevents]
Register-ObjectEvent -InputObject $sysevent -EventName "SessionEnding" -Action {$script:refreshNeeded = $true;};
Register-ObjectEvent -InputObject $sysevent -EventName "SessionEnded"  -Action {$script:refreshNeeded = $true;};
Register-ObjectEvent -InputObject $sysevent -EventName "SessionSwitch"  -Action {$script:refreshNeeded = $true;};
while($true){
    $slept += 0.5;
    if(($slept -gt ($autoRerunMinutes*60) -and $autoRerunMinutes -ne 0) -or $script:refreshNeeded){
        $slept=0;$script:refreshNeeded=$False
        Remove-Item $regPath -Force -Confirm:$False -ErrorAction SilentlyContinue;
        Restart-Service -Name IntuneManagementExtension -Force;
    }
    Start-Sleep -m 500;
}