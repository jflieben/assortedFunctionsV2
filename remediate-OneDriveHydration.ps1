<#
    .SYNOPSIS
    Detects and remediates a OneDrive client that hangs or can't serve Files On-Demand downloads (opening an online-only file fails with "The cloud file provider is not running" or a time-out).
    Typically seen while OneDrive ingests the metadata of a newly added large library. A restart resumes that ingest, so a recurring schedule restarts OneDrive until it completes.
    Use this file as both the detection and remediation script of an Intune Remediation, in user context. Intune saves it as remediate.ps1 for remediation; any other name detects. Use -Mode to run manually.
    For on-demand use with screen output and a log file, see repair-OneDrive.ps1.

    Detection, per OneDrive account:
    1. OneDrive's own status as Explorer shows it, via the Windows 11 storage provider status API. The call is relayed to OneDrive.exe: no answer within 10 seconds = hung.
       Unavailable on Windows 10, where steps 2 and 3 still apply.
    2. Reads the provider status of each sync root from the Cloud Files API. Disconnected/terminated/error = unhealthy. Instant and local.
    3. Reads one byte of a small online-only file, which makes the cloud files filter request the content from OneDrive.exe.
       A hung OneDrive still reports idle in step 2, but this read fails after the filter's 60 second time-out. Skipped when step 1 already found OneDrive hung.
       The file is set back to online-only afterwards. Without online-only files, OneDrive first frees up a small synced file, which the probe downloads again.
    The output shows each account's status (localized label as OneDrive shows it), provider status and probe result.

    Not flagged:
    - Accounts OneDrive hasn't signed in since it started (signed out, disabled, needs credentials) and personal accounts when personal sync is disabled by policy. A restart doesn't fix those.
    - Sync roots that are still connecting, or a status that doesn't answer yet, shortly after OneDrive started (e.g. first logon setup), see $startupGraceMinutes.
    - Accounts without any synced file yet: there is nothing a user can fail to open.
    - Error, Warning, Paused or Offline status: reported only, a restart doesn't fix sync errors or a missing network.

    Remediation restarts OneDrive, waits for its status to settle and runs the detection again.

    .NOTES
    filename: remediate-OneDriveHydration.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: JSolve B.V., commercial use: see https://www.jsolve.nl/commercial-use.html
    site: https://www.jsolve.nl
#>
param(
    [ValidateSet('detect','remediate')][String]$Mode = $(if($MyInvocation.MyCommand.Name -eq 'remediate.ps1'){'remediate'}else{'detect'})
)

$statusTimeoutSeconds = 10 #OneDrive's status normally answers within a second
$probeTimeoutSeconds = 65 #the cloud files filter fails a hung request after 60 seconds
$maxProbeFileBytes = 5MB
$connectWaitSeconds = 180 #how long to wait for OneDrive to (re)connect its sync roots
$settleSeconds = 120 #after a restart, how long to wait for OneDrive's status to settle
$startupGraceMinutes = 10 #detection doesn't flag sync roots that are still connecting this soon after OneDrive started
$freeUpWaitSeconds = 30 #how long OneDrive gets to free up a file

if($Env:USERPROFILE.EndsWith("system32\config\systemprofile")){
    Write-Host "Running as SYSTEM, this script should run in user context!"
    Exit 1
}

if(-not ('OneDriveProbe' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public class OneDriveStatusRoot {
    public string Account, State, Label, Quota, MoreInfo, Error;
}

// Reads OneDrive's own status (Windows 11 storage provider status API) on a background thread.
// The call is relayed to OneDrive.exe and blocks while it hangs; unlike a runspace, a background thread doesn't keep the process from exiting.
// WinRT types are resolved at runtime, so this sets Error where they don't exist (Windows 10, PowerShell 7).
public class OneDriveStatusRead {
    public List<OneDriveStatusRoot> Roots = new List<OneDriveStatusRoot>();
    public string Error;
    public Stopwatch Stopwatch = Stopwatch.StartNew();
    private Thread worker;

    public OneDriveStatusRead(string sid) {
        worker = new Thread(() => Read(sid));
        worker.IsBackground = true;
        worker.Start();
    }

    public bool Wait(int timeoutMs) { return worker.Join(timeoutMs); }

    static Type WinRt(string name) {
        Type type = Type.GetType("Windows.Storage.Provider." + name + ", Windows.Storage, ContentType=WindowsRuntime");
        if (type == null) throw new Exception("Windows.Storage.Provider." + name + " is not available");
        return type;
    }

    static object Get(object instance, Type type, string property) {
        return type.GetProperty(property).GetValue(instance);
    }

    void Read(string sid) {
        try {
            Type manager = WinRt("StorageProviderSyncRootManager");
            Type rootInfo = WinRt("StorageProviderSyncRootInfo");
            Type factoryType = WinRt("IStorageProviderStatusUISourceFactory");
            Type sourceType = WinRt("IStorageProviderStatusUISource");
            Type uiType = WinRt("StorageProviderStatusUI");
            Type commandType = WinRt("IStorageProviderUICommand");
            Type quotaType = WinRt("StorageProviderQuotaUI");
            Type moreInfoType = WinRt("StorageProviderMoreInfoUI");
            RegistryKey syncRoots = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager");
            foreach (object root in (IEnumerable)manager.GetMethod("GetCurrentSyncRoots").Invoke(null, null)) {
                string id = (string)Get(root, rootInfo, "Id");
                if (!id.StartsWith("OneDrive!" + sid + "!", StringComparison.OrdinalIgnoreCase)) continue;
                OneDriveStatusRoot result = new OneDriveStatusRoot();
                result.Account = id.Split('!')[2].Split('|')[0];
                try {
                    RegistryKey key = syncRoots == null ? null : syncRoots.OpenSubKey(id);
                    string clsid = key == null ? null : key.GetValue("StorageProviderStatusUISourceFactory") as string;
                    if (clsid == null) throw new Exception("OneDrive registered no status source for this sync root (needs Windows 11)");
                    object factory = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid(clsid)));
                    object source = factoryType.GetMethod("GetStatusUISource").Invoke(factory, new object[] { id });
                    object ui = sourceType.GetMethod("GetStatusUI").Invoke(source, null);
                    result.State = Get(ui, uiType, "ProviderState").ToString();
                    object command = Get(ui, uiType, "SyncStatusCommand");
                    if (command != null) result.Label = (string)Get(command, commandType, "Label");
                    object quota = Get(ui, uiType, "QuotaUI");
                    if (quota != null) result.Quota = (string)Get(quota, quotaType, "QuotaUsedLabel");
                    object moreInfo = Get(ui, uiType, "MoreInfoUI");
                    if (moreInfo != null) {
                        result.MoreInfo = (string)Get(moreInfo, moreInfoType, "Message");
                        object moreCommand = Get(moreInfo, moreInfoType, "Command");
                        if (moreCommand != null) result.MoreInfo += " [" + (string)Get(moreCommand, commandType, "Label") + "]";
                    }
                } catch (Exception e) {
                    result.Error = (e.InnerException ?? e).Message;
                }
                lock (Roots) { Roots.Add(result); }
            }
        } catch (Exception e) {
            Error = (e.InnerException ?? e).Message;
        }
    }
}

public static class OneDriveProbe {
    [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
    static extern int CfGetSyncRootInfoByPath(string path, int infoClass, IntPtr buffer, uint length, out uint returned);

    // Returns the CF_SYNC_PROVIDER_STATUS of the sync root containing path, or the (negative) HRESULT on failure.
    public static long GetProviderStatus(string path) {
        IntPtr buffer = Marshal.AllocHGlobal(4096);
        try {
            uint returned;
            int hr = CfGetSyncRootInfoByPath(path, 2, buffer, 4096, out returned); // 2 = CF_SYNC_ROOT_INFO_PROVIDER
            if (hr != 0) return hr;
            return (uint)Marshal.ReadInt32(buffer);
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    // Reads one byte on a worker thread so a hung provider can't block the caller past timeoutMs.
    // Returns 0 on success, 1 on time-out, otherwise the HRESULT of the failure.
    public static int Read(string path, int timeoutMs) {
        int result = 1;
        Thread worker = new Thread(() => {
            try {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1)) {
                    fs.ReadByte();
                }
                result = 0;
            } catch (Exception e) {
                result = e.HResult;
            }
        });
        worker.IsBackground = true;
        worker.Start();
        worker.Join(timeoutMs);
        return result;
    }
}
'@
}

#HRESULTs that mean OneDrive isn't serving requests: provider not running, provider terminated, request time-out, provider didn't acknowledge
$unhealthyReadResults = @(0x8007016A, 0x80070194, 0x800701AA, 0x800701DB)

$script:statusRead = $null
function Get-StatusUI([Int]$timeoutSeconds){
    #a read still waiting on a hung OneDrive is reused instead of starting another one
    if(-not $script:statusRead){
        $script:statusRead = [OneDriveStatusRead]::new([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    $read = $script:statusRead
    if(-not $read.Wait($timeoutSeconds * 1000)){
        return [PSCustomObject]@{Answered = $False; Roots = @(); Error = $null}
    }
    $script:statusRead = $null
    return [PSCustomObject]@{Answered = $True; Roots = @($read.Roots); Error = $read.Error}
}

function Get-StatusText($status, [String]$account){
    if(-not $status.Answered){ return 'no status answer' }
    if($status.Error){ return "status unavailable: $($status.Error)" }
    $root = @($status.Roots | Where-Object { $_.Account -eq $account })[0]
    if(-not $root){ return 'no status' }
    if($root.Error){ return "status unavailable: $($root.Error)" }
    $text = "$($root.State) '$($root.Label)'"
    if($root.MoreInfo){ $text += " ($($root.MoreInfo))" }
    return $text
}

function Wait-StatusSettled([Int]$seconds){
    #after a restart OneDrive goes from offline via signing in to in sync; returns once every account has been InSync for 30 s
    $deadline = (Get-Date).AddSeconds($seconds)
    $inSyncSince = $null
    while((Get-Date) -lt $deadline){
        $status = Get-StatusUI 5
        if($status.Answered -and ($status.Error -or @($status.Roots | Where-Object { -not $_.Error }).Count -eq 0)){ return } #no status to wait for
        if($status.Answered -and @($status.Roots | Where-Object { $_.State -ne 'InSync' }).Count -eq 0){
            if($null -eq $inSyncSince){ $inSyncSince = Get-Date }
            elseif($inSyncSince -lt (Get-Date).AddSeconds(-30)){ return }
        }else{
            $inSyncSince = $null
        }
        Start-Sleep -Seconds 3
    }
}

function Get-ProviderStatusName([long]$status){
    switch($status){
        0 { return 'disconnected' }
        0xC0000001L { return 'terminated' }
        0xC0000002L { return 'error' }
    }
    $flags = [ordered]@{1='idle'; 2='populating namespace'; 4='populating metadata'; 8='populating content'; 0x10='syncing'; 0x20='synced'; 0x40='connectivity lost'}
    return (@($flags.Keys | Where-Object { $status -band $_ } | ForEach-Object { $flags[$_] }) -join '+')
}

function Get-OneDriveProcess(){
    #oldest OneDrive.exe in this session (other sessions belong to other users on multi-session hosts)
    $sessionId = (Get-Process -Id $PID).SessionId
    return Get-Process OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Sort-Object StartTime | Select-Object -First 1
}

function Get-Accounts(){
    #user folder and synced library mount points per configured OneDrive account
    $personalSyncDisabled = @('HKLM:\SOFTWARE\Policies\Microsoft\OneDrive', 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive') | Where-Object { (Get-ItemProperty $_ -Name DisablePersonalSync -ErrorAction SilentlyContinue).DisablePersonalSync -eq 1 }
    foreach($account in @(Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue)){
        $paths = @($account.GetValue('UserFolder'))
        $mountPoints = Get-Item (Join-Path $account.PSPath 'ScopeIdToMountPointPathCache') -ErrorAction SilentlyContinue
        if($mountPoints){
            $paths += @($mountPoints.GetValueNames() | ForEach-Object { $mountPoints.GetValue($_) })
        }
        $paths = @($paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
        if($paths.Count -gt 0){
            [PSCustomObject]@{
                Account = $account.PSChildName
                KeyPath = $account.PSPath
                Paths = $paths
                IgnoreReason = $(if($account.PSChildName -eq 'Personal' -and $personalSyncDisabled){ 'personal sync disabled by policy' })
            }
        }
    }
}

function Get-AccountState($account, $oneDrive){
    #State: ignored, disconnected, offline or connected
    $result = [PSCustomObject]@{State = 'connected'; Status = 'not registered'; Reason = $account.IgnoreReason}
    if($result.Reason){
        $result.State = 'ignored'
        return $result
    }
    foreach($path in $account.Paths){
        $status = [OneDriveProbe]::GetProviderStatus($path)
        if($status -lt 0){ continue } #not (or no longer) a sync root
        $result.Status = Get-ProviderStatusName $status
        if($status -in @(0, 0xC0000001L, 0xC0000002L)){
            $result.State = 'disconnected'
            break
        }
        if($status -band 0x40){ $result.State = 'offline' }
    }

    #OneDrive records each account's sign-in when it starts. An account it hasn't signed in since then isn't served by this OneDrive, a restart won't change that
    if($result.State -eq 'disconnected' -and $oneDrive -and $oneDrive.StartTime -lt (Get-Date).AddMinutes(-2)){
        $started = ([DateTimeOffset]$oneDrive.StartTime).ToUnixTimeSeconds()
        $signIn = Get-ItemProperty -LiteralPath $account.KeyPath -ErrorAction SilentlyContinue
        if($signIn.LastAttemptedSignInTime -and $signIn.LastAttemptedSignInTime -lt $started){
            $result.State = 'ignored'
            $result.Reason = 'not signed in by OneDrive since it started'
        }elseif($signIn.LastSignInTime -and $signIn.LastSignInTime -lt $started){
            $result.State = 'ignored'
            $result.Reason = "sign-in failed since OneDrive started (result $($signIn.LastSignInResult))"
        }
    }
    return $result
}

function Find-Placeholder($account, [Switch]$Hydrated){
    #smallest of the first 100 matching placeholders within the first 10000 files per path
    #online-only: reparse point + recall on data access, not pinned. -Hydrated: reparse point only, not pinned, unpinned or read-only (OneDrive won't free those up)
    if($Hydrated){ $mask = 0x580401; $wanted = 0x400 }else{ $mask = 0x480400; $wanted = 0x400400 }
    foreach($path in $account.Paths){
        $file = Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 10000 |
            Where-Object { ([int]$_.Attributes -band $mask) -eq $wanted -and $_.Length -gt 0 -and $_.Length -le $maxProbeFileBytes } |
            Select-Object -First 100 | Sort-Object Length | Select-Object -First 1
        if($file){ return $file }
    }
}

function Set-OnlineOnly([IO.FileInfo]$file){
    #OneDrive frees up files marked unpinned, like "Free up space" does. Returns whether it did in time
    #$file.Attributes is from before the probe (a download clears the unpinned flag), that flag is restored either way
    $wasUnpinned = ([int]$file.Attributes -band 0x100000) -ne 0
    attrib.exe +U "$($file.FullName)" | Out-Null
    $freed = $False
    for($i = 0; $i -lt $freeUpWaitSeconds * 2; $i++){
        Start-Sleep -Milliseconds 500
        if([int](Get-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue).Attributes -band 0x400000){
            $freed = $True
            break
        }
    }
    if(-not $wasUnpinned){ attrib.exe -U "$($file.FullName)" | Out-Null }
    return $freed
}

function Test-Hydration($account){
    #without online-only files, have OneDrive free up a small synced file; the probe downloads it again so it ends up as it was
    $file = Find-Placeholder $account
    $borrowed = $False
    if(-not $file){
        $file = Find-Placeholder $account -Hydrated
        if(-not $file){
            return [PSCustomObject]@{Healthy = $True; Message = 'no synced file to probe yet'}
        }
        if(-not (Set-OnlineOnly $file)){
            return [PSCustomObject]@{Healthy = $True; Message = "OneDrive did not free up a file to probe within $freeUpWaitSeconds s"}
        }
        $borrowed = $True
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $result = [OneDriveProbe]::Read($file.FullName, $probeTimeoutSeconds * 1000)
    $elapsed = $stopwatch.ElapsedMilliseconds
    if($result -eq 0){
        if(-not $borrowed){ Set-OnlineOnly $file | Out-Null }
        return [PSCustomObject]@{Healthy = $True; Message = "probe ok in $elapsed ms"}
    }
    if($result -eq 1){
        return [PSCustomObject]@{Healthy = $False; Message = "probe got no answer within $probeTimeoutSeconds s"}
    }
    $message = ([ComponentModel.Win32Exception]::new($result -band 0xFFFF)).Message
    return [PSCustomObject]@{Healthy = ($result -notin $unhealthyReadResults); Message = "probe failed after $elapsed ms: $message (0x$($result.ToString('X8')))"}
}

function Test-OneDriveHealth([Int]$connectWait = 0, [Int]$graceMinutes = 0){
    $accounts = @(Get-Accounts)
    if($accounts.Count -eq 0){
        return [PSCustomObject]@{Healthy = $True; Summary = "No configured OneDrive accounts"}
    }

    $healthy = $True
    $summary = @()

    #OneDrive's own status: no answer means OneDrive.exe hangs, so the download probe can be skipped
    $oneDrive = Get-OneDriveProcess
    $status = Get-StatusUI $statusTimeoutSeconds
    $hung = $oneDrive -and -not $status.Answered
    if($hung){
        if($oneDrive.StartTime -gt (Get-Date).AddMinutes(-$graceMinutes)){
            $summary += "OneDrive's status gives no answer within $statusTimeoutSeconds s, OneDrive started $([int]((Get-Date) - $oneDrive.StartTime).TotalMinutes) min ago"
        }else{
            $healthy = $False
            $summary += "OneDrive's status gives no answer within $statusTimeoutSeconds s (hung)"
        }
    }

    #a starting OneDrive takes a few seconds to connect its sync roots and sign in its accounts
    $deadline = (Get-Date).AddSeconds($connectWait)
    while($True){
        $oneDrive = Get-OneDriveProcess
        $states = @($accounts | ForEach-Object { Get-AccountState $_ $oneDrive })
        if(@($states | Where-Object { $_.State -eq 'disconnected' }).Count -eq 0 -or (Get-Date) -gt $deadline){ break }
        Start-Sleep -Seconds 5
    }

    for($i = 0; $i -lt $accounts.Count; $i++){
        $state = $states[$i]
        $label = "$($accounts[$i].Account): $(Get-StatusText $status $accounts[$i].Account), provider $($state.Status)"
        if($state.State -eq 'ignored'){
            $summary += "$($accounts[$i].Account): ignored, $($state.Reason)"
        }elseif($state.State -eq 'disconnected'){
            if($oneDrive -and $oneDrive.StartTime -gt (Get-Date).AddMinutes(-$graceMinutes)){
                $summary += "$label, OneDrive started $([int]((Get-Date) - $oneDrive.StartTime).TotalMinutes) min ago"
            }else{
                $healthy = $False
                $summary += $label
            }
        }elseif($state.State -eq 'offline' -or $hung){
            $summary += "$label, skipped probe"
        }else{
            $probe = Test-Hydration $accounts[$i]
            if(-not $probe.Healthy){ $healthy = $False }
            $summary += "$label, $($probe.Message)"
        }
    }
    return [PSCustomObject]@{Healthy = $healthy; Summary = $summary -join ' | '}
}

function Restart-OneDrive(){
    $exePath = (Get-ItemProperty 'HKCU:\Software\Microsoft\OneDrive' -Name OneDriveTrigger -ErrorAction SilentlyContinue).OneDriveTrigger
    if(-not $exePath -or -not (Test-Path $exePath)){
        $exePath = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if(-not $exePath){ Throw "OneDrive.exe not found" }

    #ask OneDrive to exit, kill it if it doesn't (a hung instance won't). Only this session's instance (multi-session hosts)
    $sessionId = (Get-Process -Id $PID).SessionId
    if(Get-Process OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }){
        Start-Process $exePath -ArgumentList '/shutdown'
        Start-Sleep -Seconds 1
        Get-Process OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        Get-Process OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    #OneDrive must not run elevated
    if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        $taskName = "restartOneDrive$PID"
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action (New-ScheduledTaskAction -Execute $exePath -Argument '/background') -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 2
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$False
    }else{
        Start-Process $exePath -ArgumentList '/background'
    }
}

try{
    if($Mode -eq 'detect'){
        $health = Test-OneDriveHealth -connectWait 60 -graceMinutes $startupGraceMinutes
        Write-Host $health.Summary
        if($health.Healthy){ Exit 0 }else{ Exit 1 }
    }

    Restart-OneDrive
    Wait-StatusSettled $settleSeconds
    $health = Test-OneDriveHealth -connectWait $connectWaitSeconds
    if($health.Healthy){
        Write-Host "Restarted OneDrive: $($health.Summary)"
        Exit 0
    }else{
        Write-Host "Restarted OneDrive, still unhealthy: $($health.Summary)"
        Exit 1
    }
}catch{
    Write-Host "Failed: $_"
    Exit 1
}
