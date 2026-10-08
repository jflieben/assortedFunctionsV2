<#
    .SYNOPSIS
    On-demand check and repair of a OneDrive client that hangs or can't serve Files On-Demand downloads, e.g. while it ingests a newly added large library.
    Run in the affected user's session in Windows PowerShell 5.1. Everything shown is also appended to a log file. For Intune, use remediate-OneDriveHydration.ps1.

    Checks, per OneDrive account:
    1. OneDrive's own status (state, label, quota, extra info) as Explorer shows it, via the Windows 11 storage provider status API.
       The call is relayed to OneDrive.exe and gets no answer while it hangs. When OneDrive reports syncing, the label is followed for a while to see if it moves.
    2. The Cloud Files API provider status of each sync root. Disconnected = OneDrive isn't serving downloads ("The cloud file provider is not running").
    3. A download probe on a small online-only file, which fails after 60 seconds when OneDrive hangs. Skipped when 1 already found OneDrive hung.
    Accounts OneDrive hasn't signed in since it started, and personal accounts with personal sync disabled by policy, are reported but don't count: a restart doesn't fix those.

    When unhealthy (or with -Force), OneDrive is restarted, its status followed until it settles, and the checks run again.
    If a large library sync hangs again, run it again or use -Continuous: a restart resumes where OneDrive left off.

    With -Continuous it keeps watch until logoff or until the window is closed: every 10 seconds it checks OneDrive's status, whether OneDrive.exe runs and
    whether its sync roots are connected, and repairs when a problem lasts a minute. The full check, including the download probe, runs every 15 minutes.
    It first gives OneDrive up to 5 minutes to start, and never starts OneDrive for a user without a configured OneDrive account.

    Running hidden at every logon, e.g. on AVD session hosts: run once elevated or as SYSTEM (image build, Intune script):
        powershell.exe -ExecutionPolicy Bypass -File repair-OneDrive.ps1 -Install
    This copies the script to %ProgramFiles%\repair-OneDrive and adds an HKLM Run entry that starts it for every user without a window:
        conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\repair-OneDrive\repair-OneDrive.ps1" -Continuous
    The same command line works for a scheduled task. powershell.exe -WindowStyle Hidden still flashes a window, conhost --headless doesn't.
    Don't use a GPO logon script: Windows stops those after 10 minutes by default, and a synchronous one blocks the logon.
    Each watcher is a powershell.exe using about 90 MB of memory. On hosts with many sessions, remediate-OneDriveHydration.ps1 as an hourly Intune Remediation costs nothing in between.

    .PARAMETER Force
    Restart OneDrive even when it looks healthy. With -Continuous only on the first check.

    .PARAMETER DiagnoseOnly
    Only check, never restart. With -Continuous this only monitors.

    .PARAMETER Continuous
    Keep watching and repairing until logoff or until the window is closed. One instance per user session.

    .PARAMETER Install
    Copy the script to %ProgramFiles%\repair-OneDrive and start it hidden with -Continuous at every user's logon (HKLM Run). Needs elevation or SYSTEM.
    -DiagnoseOnly and -MaxLogSizeMB are passed on.

    .PARAMETER Uninstall
    Remove what -Install added. Running watchers stop at logoff.

    .PARAMETER LogPath
    Log file to append to, per user by default.

    .PARAMETER MaxLogSizeMB
    Size at which the log rotates (.log to .1, .1 to .2 and so on); the 3 most recent old logs are kept.

    .NOTES
    filename: repair-OneDrive.ps1
    author: Jos Lieben / jos@lieben.nu
    copyright: JSolve B.V., commercial use: see https://www.jsolve.nl/commercial-use.html
    site: https://www.jsolve.nl
#>
#Requires -PSEdition Desktop
param(
    [Switch]$Force,
    [Switch]$DiagnoseOnly,
    [Switch]$Continuous,
    [Switch]$Install,
    [Switch]$Uninstall,
    [String]$LogPath = (Join-Path $env:LOCALAPPDATA 'repair-OneDrive\repair-OneDrive.log'),
    [ValidateRange(1, 1024)][Int]$MaxLogSizeMB = 5
)

$statusTimeoutSeconds = 10 #OneDrive's status normally answers within a second
$probeTimeoutSeconds = 65 #the cloud files filter fails a hung request after 60 seconds
$maxProbeFileBytes = 5MB
$freeUpWaitSeconds = 30 #how long OneDrive gets to free up a file
$movementWatchSeconds = 30 #how long to follow the label when OneDrive reports it is syncing
$settleSeconds = 240 #how long to follow the status after a restart
$watchIntervalSeconds = 10 #-Continuous: interval of the quick checks
$problemSeconds = 60 #-Continuous: how long a hang, disconnect or missing OneDrive.exe may last before repairing (rides out OneDrive's own update restarts)
$fullCheckMinutes = 15 #-Continuous: interval of the full check including the download probe
$heartbeatMinutes = 10 #-Continuous: log an unchanged status (or a repeating error) at least this often
$logonWaitMinutes = 5 #-Continuous: how long OneDrive gets to start at logon before it is judged
$logFilesToKeep = 3

function Write-Log([String]$message, [ValidateSet('INFO','OK','WARN','ERROR')][String]$level = 'INFO'){
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $message
    $color = @{INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'}[$level]
    Write-Host $line -ForegroundColor $color
    #a failing write (file locked by another instance or a scanner, disk full) is retried and then dropped: logging must never stop the watcher
    for($attempt = 1; $attempt -le 3; $attempt++){
        try{
            if((Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue).Length -gt $MaxLogSizeMB * 1MB){
                for($i = $logFilesToKeep; $i -ge 1; $i--){
                    $source = if($i -eq 1){ $LogPath }else{ "$LogPath.$($i - 1)" }
                    if(Test-Path -LiteralPath $source){ Move-Item -LiteralPath $source -Destination "$LogPath.$i" -Force -ErrorAction Stop }
                }
            }
            Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
            return
        }catch{
            Start-Sleep -Milliseconds 200
        }
    }
}

if($Install -or $Uninstall){
    #HKLM Run starts the watcher in every user's session at logon, e.g. on an AVD session host image
    if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        Write-Host "-Install and -Uninstall need an elevated session or SYSTEM"
        Exit 1
    }
    $programFiles = if($env:ProgramW6432){ $env:ProgramW6432 }else{ $env:ProgramFiles } #64-bit Program Files, also from 32-bit PowerShell
    $installPath = Join-Path $programFiles 'repair-OneDrive\repair-OneDrive.ps1'
    $runKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Run', $True)
    try{
        if($Install){
            New-Item -ItemType Directory -Path (Split-Path -Parent $installPath) -Force | Out-Null
            if($PSCommandPath -ne $installPath){ Copy-Item -LiteralPath $PSCommandPath -Destination $installPath -Force }
            $command = "$env:SystemRoot\System32\conhost.exe --headless $env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installPath`" -Continuous"
            if($DiagnoseOnly){ $command += ' -DiagnoseOnly' }
            if($PSBoundParameters.ContainsKey('MaxLogSizeMB')){ $command += " -MaxLogSizeMB $MaxLogSizeMB" }
            $runKey.SetValue('repair-OneDrive', $command)
            Write-Host "Installed, every user starts this at logon: $command"
        }else{
            $runKey.DeleteValue('repair-OneDrive', $False)
            Remove-Item -LiteralPath (Split-Path -Parent $installPath) -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Uninstalled, running watchers stop at logoff"
        }
    }finally{
        $runKey.Close()
    }
    Exit 0
}

if($Env:USERPROFILE.EndsWith("system32\config\systemprofile")){
    Write-Host "Running as SYSTEM, this script should run in the user's session!"
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
// WinRT types are resolved at runtime, so this sets Error where they don't exist (Windows 10).
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
        return [PSCustomObject]@{Answered = $False; Seconds = [int]$read.Stopwatch.Elapsed.TotalSeconds; Roots = @(); Error = $null}
    }
    $script:statusRead = $null
    return [PSCustomObject]@{Answered = $True; Seconds = [Math]::Round($read.Stopwatch.Elapsed.TotalSeconds, 1); Roots = @($read.Roots); Error = $read.Error}
}

function Format-StatusRoot($root){
    if($root.Error){ return "$($root.Account): status unavailable, $($root.Error)" }
    $text = "$($root.Account): $($root.State), $($root.Label)"
    if($root.Quota){ $text += " | $($root.Quota)" }
    if($root.MoreInfo){ $text += " | more: $($root.MoreInfo)" }
    return $text
}

function Format-Status($status){
    if(-not $status.Answered){ return "no answer for $($status.Seconds) s, OneDrive.exe is not responding" }
    if($status.Error){ return "status unavailable: $($status.Error)" }
    if($status.Roots.Count -eq 0){ return "no OneDrive sync roots registered" }
    return (@($status.Roots | ForEach-Object { Format-StatusRoot $_ }) -join ' || ')
}

function Watch-Status([Int]$seconds, [Switch]$untilSettled){
    #logs OneDrive's status when it changes, and at least every 30 s. Returns how often it changed
    #-untilSettled stops once every account has been InSync for 30 s
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    $lastLogged = 0
    $changes = 0
    $inSyncSince = $null
    while($stopwatch.Elapsed.TotalSeconds -lt $seconds){
        $status = Get-StatusUI 5
        $text = Format-Status $status
        $level = if(-not $status.Answered){ 'ERROR' }else{ 'INFO' }
        if($text -ne $last){
            if($null -ne $last){ $changes++ }
            Write-Log "  $text" $level
            $last = $text
            $lastLogged = $stopwatch.Elapsed.TotalSeconds
        }elseif($stopwatch.Elapsed.TotalSeconds - $lastLogged -ge 30){
            Write-Log "  unchanged: $text" $level
            $lastLogged = $stopwatch.Elapsed.TotalSeconds
        }
        if($untilSettled){
            if($status.Answered -and $status.Roots.Count -gt 0 -and @($status.Roots | Where-Object { $_.State -ne 'InSync' }).Count -eq 0){
                if($null -eq $inSyncSince){ $inSyncSince = $stopwatch.Elapsed.TotalSeconds }
                elseif($stopwatch.Elapsed.TotalSeconds - $inSyncSince -ge 30){ break }
            }else{
                $inSyncSince = $null
            }
        }
        Start-Sleep -Seconds 3
    }
    return $changes
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
    $target = "$($file.Name) ($([Math]::Ceiling($file.Length / 1KB)) KB)"
    if($result -eq 0){
        if(-not $borrowed){ Set-OnlineOnly $file | Out-Null }
        return [PSCustomObject]@{Healthy = $True; Message = "download probe of $target ok in $elapsed ms"}
    }
    if($result -eq 1){
        return [PSCustomObject]@{Healthy = $False; Message = "download probe of $target got no answer within $probeTimeoutSeconds s"}
    }
    $message = ([ComponentModel.Win32Exception]::new($result -band 0xFFFF)).Message
    return [PSCustomObject]@{Healthy = ($result -notin $unhealthyReadResults); Message = "download probe of $target failed after $elapsed ms: $message (0x$($result.ToString('X8')))"}
}

function Invoke-Diagnosis([Int]$connectWait){
    #logs what it finds, returns whether OneDrive is healthy and why not
    $reasons = New-Object Collections.Generic.List[String]

    $oneDrive = Get-OneDriveProcess
    if($oneDrive){
        Write-Log "OneDrive.exe pid $($oneDrive.Id), started $($oneDrive.StartTime.ToString('yyyy-MM-dd HH:mm:ss')), version $($oneDrive.FileVersion)"
    }elseif(Test-OneDriveUser){
        Write-Log "OneDrive.exe is not running in this session" 'ERROR'
        $reasons.Add('OneDrive is not running')
    }else{
        Write-Log "OneDrive.exe is not running and no OneDrive account is configured, nothing to do"
    }

    #1: OneDrive's own status
    $hung = $False
    $status = Get-StatusUI $statusTimeoutSeconds
    if(-not $status.Answered){
        Write-Log "Status: no answer within $statusTimeoutSeconds s, OneDrive.exe is not responding" 'ERROR'
        if($oneDrive){
            $hung = $True
            $reasons.Add("OneDrive's status gives no answer (hung)")
        }
    }elseif($status.Error -or $status.Roots.Count -eq 0){
        Write-Log "Status: $(Format-Status $status)" 'WARN'
    }else{
        foreach($root in $status.Roots){
            $level = switch($root.State){ 'InSync' { 'OK' } 'Syncing' { 'INFO' } 'Error' { 'ERROR' } default { 'WARN' } }
            Write-Log "Status ($($status.Seconds) s): $(Format-StatusRoot $root)" $level
        }
        if(@($status.Roots | Where-Object { $_.State -eq 'Syncing' }).Count -gt 0){
            Write-Log "OneDrive is syncing, following its status for $movementWatchSeconds s"
            $changes = Watch-Status $movementWatchSeconds
            if($changes -gt 0){
                Write-Log "Status changed $changes times in $movementWatchSeconds s: OneDrive is making progress" 'OK'
            }else{
                Write-Log "Status unchanged for $movementWatchSeconds s. Normal for 'Looking for changes' or 'Processing changes', a hang shows as no answer" 'WARN'
            }
        }
    }

    #2 and 3: Cloud Files API provider status and a download probe, per account
    $accounts = @(Get-Accounts)
    if($accounts.Count -eq 0){
        Write-Log "No configured OneDrive accounts" 'WARN'
    }
    if(-not $oneDrive){ $connectWait = 0 }
    $deadline = (Get-Date).AddSeconds($connectWait)
    while($accounts.Count -gt 0){
        $oneDrive = Get-OneDriveProcess
        $states = @($accounts | ForEach-Object { Get-AccountState $_ $oneDrive })
        if(@($states | Where-Object { $_.State -eq 'disconnected' }).Count -eq 0 -or (Get-Date) -gt $deadline){ break }
        Start-Sleep -Seconds 5
    }
    for($i = 0; $i -lt $accounts.Count; $i++){
        $account = $accounts[$i].Account
        $state = $states[$i]
        if($state.State -eq 'ignored'){
            Write-Log "$($account): ignored, $($state.Reason)"
        }elseif($state.State -eq 'disconnected'){
            Write-Log "$($account): provider $($state.Status), downloads fail with 'The cloud file provider is not running'" 'ERROR'
            $reasons.Add("$($account): provider $($state.Status)")
        }elseif($state.State -eq 'offline'){
            Write-Log "$($account): provider $($state.Status), skipped download probe" 'WARN'
        }elseif($hung){
            Write-Log "$($account): provider $($state.Status), skipped download probe because OneDrive is not responding"
        }else{
            Write-Log "$($account): provider $($state.Status), running download probe (up to $probeTimeoutSeconds s)"
            $probe = Test-Hydration $accounts[$i]
            if($probe.Healthy){
                Write-Log "$($account): $($probe.Message)" 'OK'
            }else{
                Write-Log "$($account): $($probe.Message)" 'ERROR'
                $reasons.Add("$($account): $($probe.Message)")
            }
        }
    }
    return [PSCustomObject]@{Healthy = ($reasons.Count -eq 0); Reasons = $reasons}
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
        Write-Log "Asking OneDrive to exit"
        Start-Process $exePath -ArgumentList '/shutdown'
        Start-Sleep -Seconds 1
        Get-Process OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        $remaining = @(Get-Process OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
        if($remaining.Count -gt 0){
            Write-Log "OneDrive did not exit within 30 s, killing pid $($remaining.Id -join ', ')" 'WARN'
            $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
        }
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
    Write-Log "Started $exePath"
}

function Invoke-Repair([Switch]$force){
    #full check and, when needed (or forced), a restart. Returns whether OneDrive ends up healthy
    Write-Log "--- Checking OneDrive"
    $before = Invoke-Diagnosis -connectWait 60
    if($before.Healthy -and -not $force){
        Write-Log "OneDrive is healthy, nothing to repair" 'OK'
        return $True
    }
    if(-not $before.Healthy){
        Write-Log "Unhealthy: $($before.Reasons -join '; ')" 'ERROR'
    }
    if($DiagnoseOnly){
        Write-Log "Diagnose only, not restarting OneDrive"
        return $before.Healthy
    }

    Write-Log "--- Restarting OneDrive$(if($before.Healthy){' (forced)'})"
    Restart-OneDrive
    Write-Log "--- Following OneDrive's status for up to $settleSeconds s"
    $null = Watch-Status $settleSeconds -untilSettled

    Write-Log "--- Checking OneDrive again"
    $after = Invoke-Diagnosis -connectWait 180
    if($after.Healthy){
        Write-Log "OneDrive is healthy after the restart" 'OK'
        return $True
    }
    Write-Log "Still unhealthy after the restart: $($after.Reasons -join '; ')" 'ERROR'
    return $False
}

function Test-OneDriveUser(){
    #whether this user has a OneDrive account that needs OneDrive.exe; users without one (admins, service accounts) are left alone
    return @(Get-Accounts | Where-Object { -not $_.IgnoreReason }).Count -gt 0
}

function Get-QuickProblem($status){
    #cheap checks for the watch loop, returns a description of the problem or $null
    $oneDrive = Get-OneDriveProcess
    if(-not $oneDrive){
        if(Test-OneDriveUser){ return 'OneDrive.exe is not running' }
        return $null
    }
    if(-not $status.Answered){ return "OneDrive's status gives no answer" }
    if($oneDrive.StartTime -gt (Get-Date).AddMinutes(-2)){ return $null } #still starting
    foreach($account in @(Get-Accounts)){
        $state = Get-AccountState $account $oneDrive
        if($state.State -eq 'disconnected'){ return "$($account.Account): provider $($state.Status)" }
    }
    return $null
}

function Watch-OneDrive(){
    #runs until logoff or the window is closed: logs status changes, repairs a problem that lasts $problemSeconds and runs the full check every $fullCheckMinutes
    $nextFullCheck = (Get-Date).AddMinutes($fullCheckMinutes)
    Write-Log "--- Keeping watch until logoff or until this window is closed, next full check at $($nextFullCheck.ToString('HH:mm'))"
    $lastText = $null
    $lastLogged = Get-Date
    $problemSince = $null
    $lastError = $null
    $lastErrorLogged = Get-Date
    while($True){
        try{
            $status = Get-StatusUI 5
            $text = Format-Status $status
            if($text -ne $lastText -or $lastLogged -lt (Get-Date).AddMinutes(-$heartbeatMinutes)){
                Write-Log "  $(if($text -eq $lastText){ 'unchanged: ' })$text" $(if($status.Answered){ 'INFO' }else{ 'ERROR' })
                $lastText = $text
                $lastLogged = Get-Date
            }

            $problem = Get-QuickProblem $status
            if(-not $problem){
                if($problemSince){ Write-Log "Problem cleared up by itself" 'OK' }
                $problemSince = $null
            }elseif(-not $problemSince){
                $problemSince = Get-Date
                Write-Log "$problem, repairing if this lasts $problemSeconds s" 'WARN'
            }

            $repairNow = $problemSince -and $problemSince -lt (Get-Date).AddSeconds(-$problemSeconds)
            if($repairNow -or (Get-Date) -gt $nextFullCheck){
                if($repairNow){ Write-Log "$problem for $problemSeconds s" 'ERROR' }
                $null = Invoke-Repair
                $nextFullCheck = (Get-Date).AddMinutes($fullCheckMinutes)
                $problemSince = $null
                $lastText = $null
                Write-Log "--- Keeping watch, next full check at $($nextFullCheck.ToString('HH:mm'))"
            }
        }catch{
            #an error that repeats every round is logged once per heartbeat
            if("$_" -ne $lastError -or $lastErrorLogged -lt (Get-Date).AddMinutes(-$heartbeatMinutes)){
                Write-Log "Watch error: $_" 'ERROR'
                $lastError = "$_"
                $lastErrorLogged = Get-Date
            }
        }
        Start-Sleep -Seconds $watchIntervalSeconds
    }
}

function Wait-OneDriveStartup(){
    #at logon OneDrive.exe starts after the shell; give it time to start and sign in before judging it
    $deadline = (Get-Date).AddMinutes($logonWaitMinutes)
    $logged = $False
    while((Get-Date) -lt $deadline){
        $oneDrive = Get-OneDriveProcess
        if($oneDrive -and $oneDrive.StartTime -lt (Get-Date).AddMinutes(-2)){ return }
        if(-not $logged){
            Write-Log "Waiting up to $logonWaitMinutes min for OneDrive to start and sign in"
            $logged = $True
        }
        Start-Sleep -Seconds 10
    }
}

New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force -ErrorAction SilentlyContinue | Out-Null
if($Continuous){
    #one watcher per user session, released when the process ends
    $script:watcherMutex = New-Object Threading.Mutex($False, 'Local\repair-OneDrive-Continuous')
    if(-not $script:watcherMutex.WaitOne(0)){
        Write-Log "repair-OneDrive -Continuous is already running in this session" 'WARN'
        Exit 0
    }
}
Write-Log "=== repair-OneDrive on $env:COMPUTERNAME (session $((Get-Process -Id $PID).SessionId)) as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)$(if($Continuous){', continuous'}), log: $LogPath"
if($Continuous){
    Wait-OneDriveStartup
}
try{
    $healthy = Invoke-Repair -force:$Force
}catch{
    Write-Log "Failed: $_" 'ERROR'
    $healthy = $False
}
if($Continuous){
    Watch-OneDrive
}
if(-not $healthy -and -not $DiagnoseOnly){
    Write-Log "If a large library sync hangs again, run this again or use -Continuous: a restart resumes where OneDrive left off"
}
if($healthy){ Exit 0 }
Exit 1
