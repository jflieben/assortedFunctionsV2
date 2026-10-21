#Requires -Version 7.0
<#
    M365Permissions remediation engine.

    Master copy: https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/Remediation/remediation-lib.ps1
    Entry point: Invoke-M365PRemediation.ps1 (same folder), which is what an administrator runs
    Handlers:    Remediation/handlers/*.ps1, one file per family of risk reasons

    Rules this file exists to enforce, so that no handler has to remember them:

      nothing is written before the administrator has seen it
        every handler only ever plans. It reads, works out what it would change, and hands back a
        description plus a script block. The engine prints the lot and asks. Nothing in a handler runs
        a write of its own.

      everything is logged
        one transcript style log per run, plus a machine readable record of every action with its
        outcome. Written before the first change, flushed after every change, so a run that dies
        halfway still says exactly what it did.

      reversible where the platform allows it
        a handler that can describe the inverse of its change supplies it, and the engine writes it to
        a rollback file. Where the platform cannot restore something (a deleted sharing link gets a new
        id) the plan says so before the administrator approves.

      the product never remediates itself
        every identity level action is checked against the protected list: the scanner, the portal, and
        whatever the caller passes in. A run that would strip the product's own access is refused.

    Conventions:
      plain PowerShell 7, no module dependencies, so it runs in Azure Cloud Shell and on a workstation
      delegated authentication only: every change is made as the signed in administrator, never as an
      application, so the audit trail in Entra names a person
#>

$script:M365PHandlers = [System.Collections.Generic.List[Object]]::new()
$script:M365PTokens = @{}
$script:M365PCache = @{}

# ------------------------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------------------------

function Write-M365PStep { Param([String]$Message) Write-M365PLine "" ; Write-M365PLine "==> $Message" -Colour Cyan }
function Write-M365PDetail { Param([String]$Message) Write-M365PLine "    $Message" -Colour DarkGray }
function Write-M365PWarn { Param([String]$Message) Write-M365PLine "    $Message" -Colour DarkYellow }
function Write-M365PGood { Param([String]$Message) Write-M365PLine "    $Message" -Colour Green }
function Write-M365PBad { Param([String]$Message) Write-M365PLine "    $Message" -Colour Red }

function Write-M365PLine {
    <#
        .SYNOPSIS
        One line to the console and, once a run has started, to its log file.

        .DESCRIPTION
        Write-Host rather than Write-Output on purpose: these functions are called from inside functions
        whose return value matters, and the success stream is for data.
    #>
    Param(
        [Parameter(Position = 0)][String]$Message = "",
        [String]$Colour = "Gray"
    )

    Write-Host $Message -ForegroundColor $Colour
    if ($script:M365PLogFile) {
        try { Add-Content -Path $script:M365PLogFile -Value "$([DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")) $Message" -ErrorAction Stop } catch { }
    }
}

function Start-M365PRemediationLog {
    <#
        .SYNOPSIS
        Opens the run's log and record files and returns the folder they are in.

        .DESCRIPTION
        Under the user profile, which exists and is writable both in Cloud Shell and on a workstation.
        The record file is JSON lines: one object per action, appended as it happens, so an interrupted
        run is still readable and still tells you what to undo.
    #>
    Param([String]$LogFolder)

    if (!$LogFolder) {
        $LogFolder = Join-Path -Path ([Environment]::GetFolderPath("UserProfile")) -ChildPath "m365permissions-remediation"
    }
    if (!(Test-Path -Path $LogFolder)) { $Null = New-Item -Path $LogFolder -ItemType Directory -Force }

    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
    $script:M365PLogFile = Join-Path -Path $LogFolder -ChildPath "remediation-$stamp.log"
    $script:M365PRecordFile = Join-Path -Path $LogFolder -ChildPath "remediation-$stamp.actions.jsonl"
    $script:M365PRollbackFile = Join-Path -Path $LogFolder -ChildPath "remediation-$stamp.rollback.json"
    $script:M365PRollback = [System.Collections.Generic.List[Object]]::new()
    $script:M365PSkips = [System.Collections.Generic.List[Object]]::new()

    return $LogFolder
}

function Add-M365PSkip {
    <#
        .SYNOPSIS
        Records an item this run will not act on, and why.

        .DESCRIPTION
        A handler that cannot do something says so here instead of throwing or staying quiet. The plan
        lists these next to the changes, because "nothing happened" and "this one needs doing by hand"
        look identical otherwise, and the second one needs the administrator to know.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][String]$Why
    )

    $script:M365PSkips.Add([PSCustomObject]@{
            RiskItemId = $Item.id
            Reason     = $Item.reason
            Target     = "$($Item.targetPath)"
            Why        = $Why
        })
}

function Get-M365PSkips { return @($script:M365PSkips) }

function ConvertTo-M365PDate {
    <#
        .SYNOPSIS
        One date from an API or from the portal, read the same way wherever this runs.

        .DESCRIPTION
        [DateTime]::Parse uses the current culture, which on a Dutch or German workstation reads
        2021-03-04 as the fourth of March in one place and the third of April in another. The plan an
        administrator approves states these dates, so they have to be the dates the API meant.
    #>
    Param([Parameter(Mandatory = $true)]$Value)

    return [DateTime]::Parse("$Value", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Test-M365PDirectoryObjectExists {
    <#
        .SYNOPSIS
        Whether an object id still resolves in Entra, which is how an orphan is confirmed.

        .DESCRIPTION
        The scan's view can be hours old, so an orphan is re-checked at plan time rather than trusted:
        acting on a principal that has since been restored would remove a live permission.
    #>
    Param([Parameter(Mandatory = $true)][String]$ObjectId)

    try {
        $Null = Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$ObjectId" -NoPaging
        return $True
    }catch {
        if ("$($_.Exception.Message)" -match "Request_ResourceNotFound|does not exist|Resource .* not found|404") { return $False }
        Throw
    }
}

function Write-M365PRecord {
    Param([Parameter(Mandatory = $true)][Object]$Record)
    if (!$script:M365PRecordFile) { return }
    try {
        Add-Content -Path $script:M365PRecordFile -Value ($Record | ConvertTo-Json -Depth 8 -Compress) -ErrorAction Stop
    }catch {
        Write-M365PWarn "Could not append to the action record: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------------------------------------
# Tokens. Delegated only, so every change is attributable to the person running this.
# ------------------------------------------------------------------------------------------------

#Public clients that are first party, hold the delegated permissions each audience needs, and have a
#loopback redirect registered so the browser flow works. Used only when there is no session to borrow.
$script:M365PClients = @{
    graph = @{ clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"; name = "Microsoft Graph PowerShell" }
    arm   = @{ clientId = "1950a258-227b-4e31-a9cf-717495945fc2"; name = "Microsoft Azure PowerShell" }
    spo   = @{ clientId = "9bc3ab49-b65d-410a-85ad-de819febfddc"; name = "SharePoint Online Management Shell" }
}

function Test-M365PIsCloudShell {
    <#
        .SYNOPSIS
        Whether this is running in Azure Cloud Shell, where no browser flow can work.

        .DESCRIPTION
        There is no browser in the container and nothing can reach a loopback listener inside it, so the
        browser sign in is skipped there and the existing session is the only quiet way in.
    #>
    return ([Boolean]$env:ACC_CLOUD) -or ("$env:AZUREPS_HOST_ENVIRONMENT" -like "cloud-shell*")
}

function Get-M365PCliToken {
    <#
        .SYNOPSIS
        A delegated token from an existing Azure CLI sign in, or $null.

        .DESCRIPTION
        Tried first, and in Cloud Shell it is always there. The Azure CLI client can issue tokens for
        Graph, Azure, SharePoint and Exchange, so one session covers every audience this script needs,
        with no prompt and nothing for a conditional access policy to block. Measured on its Graph
        token: AppRoleAssignment.ReadWrite.All, Application.ReadWrite.All, Directory.AccessAsUser.All,
        DelegatedPermissionGrant.ReadWrite.All, Group.ReadWrite.All, User.ReadWrite.All. Not Sites or
        Files, which is why sharing goes through SharePoint's own API rather than Graph.
    #>
    Param([Parameter(Mandatory = $true)][String]$Resource)

    if (!(Get-Command -Name "az" -ErrorAction SilentlyContinue)) { return $Null }

    try {
        $output = & az account get-access-token --resource $Resource --output json 2>$Null
        if ($LASTEXITCODE -ne 0 -or !$output) { return $Null }
        return (($output | ConvertFrom-Json).accessToken)
    }catch {
        return $Null
    }
}

function Get-M365PBrowserToken {
    <#
        .SYNOPSIS
        Signs the administrator in through their browser and returns the access token.

        .DESCRIPTION
        Authorization code with PKCE against a loopback listener, which is what the Azure CLI and the
        Graph module do interactively. It replaces the device code flow, which conditional access
        commonly blocks, but it needs a browser on this machine, so it is skipped in Cloud Shell.
    #>
    Param(
        [Parameter(Mandatory = $true)][String]$ClientId,
        [Parameter(Mandatory = $true)][String[]]$Scopes,
        [String]$TenantId = "organizations"
    )

    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $verifierBytes = [Byte[]]::new(32)
    $random.GetBytes($verifierBytes)
    $verifier = [Convert]::ToBase64String($verifierBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    $challenge = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    $state = [Guid]::NewGuid().ToString()

    #a free port, asked of the operating system rather than guessed, so two runs never collide
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()

    $redirect = "http://localhost:$port/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($redirect)
    try {
        $listener.Start()
    }catch {
        Throw "Could not listen on $redirect for the sign in ($($_.Exception.Message)). Use -DeviceCode instead."
    }

    $query = @(
        "client_id=$ClientId"
        "response_type=code"
        "redirect_uri=$([Uri]::EscapeDataString($redirect))"
        "response_mode=query"
        "scope=$([Uri]::EscapeDataString((@($Scopes) + @("offline_access") -join " ")))"
        "state=$state"
        "code_challenge=$challenge"
        "code_challenge_method=S256"
        "prompt=select_account"
    ) -join "&"
    $authUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?$query"

    Write-M365PLine ""
    Write-M365PDetail "Opening your browser to sign in. If it does not open, paste this:"
    Write-M365PLine "    $authUrl" -Colour Cyan
    Write-M365PLine ""

    try {
        if ($IsWindows -or "$env:OS" -like "Windows*") { Start-Process $authUrl | Out-Null }
        elseif ($IsMacOS) { & open $authUrl }
        else { & xdg-open $authUrl 2>$Null }
    }catch {
        #the url is printed above, so a host without a launcher is not a failure
    }

    try {
        $contextTask = $listener.GetContextAsync()
        if (!$contextTask.Wait([TimeSpan]::FromMinutes(5))) { Throw "Timed out waiting for the browser sign in" }
        $context = $contextTask.Result

        $code = $context.Request.QueryString["code"]
        $returnedState = $context.Request.QueryString["state"]
        $error = $context.Request.QueryString["error_description"]

        $message = if ($code -and $returnedState -eq $state) { "Signed in. You can close this tab and go back to the terminal." }
                   else { "Sign in failed: $(if($error){ $error }else{ 'no authorization code returned' })" }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("<html><body style='font-family:sans-serif'><p>$message</p></body></html>")
        $context.Response.ContentType = "text/html"
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()

        if (!$code) { Throw "Sign in failed: $(if($error){ $error }else{ 'no authorization code returned' })" }
        if ($returnedState -ne $state) { Throw "Sign in failed: the reply did not match this request" }
    }finally {
        $listener.Stop()
        $listener.Close()
    }

    $token = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ErrorAction Stop -Body @{
        client_id     = $ClientId
        grant_type    = "authorization_code"
        code          = $code
        redirect_uri  = $redirect
        code_verifier = $verifier
    }
    return $token.access_token
}

function Get-M365PTokenClaims {
    Param([Parameter(Mandatory = $true)][String]$Token)
    try {
        $payload = $Token.Split(".")[1]
        switch ($payload.Length % 4) {
            1 { $payload = $payload.Substring(0, $payload.Length - 1) }
            2 { $payload += "==" }
            3 { $payload += "=" }
        }
        return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace("-", "+").Replace("_", "/"))) | ConvertFrom-Json)
    }catch {
        return $Null
    }
}

function Get-M365PAzToken {
    <#
        .SYNOPSIS
        A delegated token from the signed in Az session, or $null when that session cannot serve the
        audience. Shape normalising copied from authorize.ps1, whose Az versions this has to match.
    #>
    Param([Parameter(Mandatory = $true)][String]$Resource)

    if (!(Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue)) { return $Null }

    foreach ($attempt in @("secure", "plain")) {
        try {
            if ($attempt -eq "secure") {
                $token = Get-AzAccessToken -ResourceUrl $Resource -AsSecureString -ErrorAction Stop -WarningAction SilentlyContinue
                return ($token.Token | ConvertFrom-SecureString -AsPlainText)
            }
            $token = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop -WarningAction SilentlyContinue
            if ($token.Token -is [System.Security.SecureString]) { return ($token.Token | ConvertFrom-SecureString -AsPlainText) }
            return $token.Token
        }catch {
            $script:M365PLastTokenError = $_.Exception.Message
        }
    }
    return $Null
}

function Get-M365PDeviceCodeToken {
    <#
        .SYNOPSIS
        Signs the administrator in with the device code flow and returns the access token.

        .DESCRIPTION
        The fallback for every audience the Az session cannot serve, and the only way to ask for a
        specific set of Graph scopes rather than whatever the Azure PowerShell client happens to hold.
        No module needed, which is what keeps this runnable in a bare Cloud Shell.
    #>
    Param(
        [Parameter(Mandatory = $true)][String]$ClientId,
        [Parameter(Mandatory = $true)][String[]]$Scopes,
        [String]$TenantId = "organizations"
    )

    $body = @{ client_id = $ClientId; scope = (@($Scopes) + @("offline_access") -join " ") }
    $device = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" -Body $body -ErrorAction Stop

    Write-M365PLine ""
    Write-M365PLine "    Sign in to continue: $($device.verification_uri)" -Colour Cyan
    Write-M365PLine "    Code:                $($device.user_code)" -Colour Cyan
    Write-M365PLine ""

    $deadline = (Get-Date).AddSeconds([int]$device.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([Math]::Max(5, [int]$device.interval))
        try {
            $token = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ErrorAction Stop -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $ClientId
                device_code = $device.device_code
            }
            return $token.access_token
        }catch {
            $detail = $Null
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $detail = $Null }
            #the only two that mean "keep waiting"; anything else is a real refusal
            if ($detail -notin @("authorization_pending", "slow_down")) {
                Throw "Device sign in failed: $(if($detail){ $detail }else{ $_.Exception.Message })"
            }
        }
    }
    Throw "Device sign in timed out"
}

function Get-M365PToken {
    <#
        .SYNOPSIS
        A delegated access token for one audience, cached for the run.

        .PARAMETER Audience
        graph, arm, or the https://<tenant>.sharepoint.com url for SharePoint.

        .PARAMETER Scopes
        Graph only, and only used when a device sign in is needed: the scopes to ask for.
    #>
    Param(
        [Parameter(Mandatory = $true)][String]$Audience,
        [String[]]$Scopes = @(),
        [Switch]$DeviceCode
    )

    $key = $Audience.ToLower()
    if ($script:M365PTokens.ContainsKey($key)) { return $script:M365PTokens[$key] }

    $resource = switch ($Audience) {
        "graph" { "https://graph.microsoft.com" }
        "arm" { "https://management.azure.com" }
        default { $Audience }
    }
    $clientKey = switch ($Audience) {
        "graph" { "graph" }
        "arm" { "arm" }
        default { "spo" }
    }

    $token = $Null
    $tenantForSignIn = $(if ($script:M365PTenantId) { $script:M365PTenantId } else { "organizations" })

    #An existing sign in first, and in Cloud Shell that is the end of it. The Azure CLI session serves
    #every audience here; the Azure PowerShell one serves Graph and Azure but not SharePoint, because
    #that client holds no SharePoint delegated permission.
    if (!$DeviceCode) {
        $token = Get-M365PCliToken -Resource $resource
        if ($token) { Write-M365PDetail "Using your Azure CLI session for $resource" }

        if (!$token) {
            $token = Get-M365PAzToken -Resource $resource
            if ($token) { Write-M365PDetail "Using your Azure PowerShell session for $resource" }
        }
    }

    $client = $script:M365PClients[$clientKey]
    $askFor = if ($Scopes.Count -gt 0) { @($Scopes | ForEach-Object { "$resource/$_" }) } else { @("$resource/.default") }

    #The browser flow is the interactive fallback rather than the device code one, which conditional
    #access blocks in a lot of tenants. It cannot work in Cloud Shell, where there is no browser and
    #nothing can reach a listener inside the container.
    if (!$token -and !$DeviceCode -and !(Test-M365PIsCloudShell)) {
        Write-M365PDetail "No Azure session for $resource, signing in through $($client.name)"
        $token = Get-M365PBrowserToken -ClientId $client.clientId -Scopes $askFor -TenantId $tenantForSignIn
    }

    if (!$token -and $DeviceCode) {
        Write-M365PDetail "Signing in to $resource through $($client.name) with a device code"
        $token = Get-M365PDeviceCodeToken -ClientId $client.clientId -Scopes $askFor -TenantId $tenantForSignIn
    }

    if (!$token) {
        Throw "No way to get a token for $resource. Run 'az login' (or Connect-AzAccount) and try again, or add -DeviceCode if this environment allows that flow."
    }
    $script:M365PTokens[$key] = $token
    return $token
}

function Test-M365PTokenScopes {
    <#
        .SYNOPSIS
        Which of the required scopes a token does not carry.

        .DESCRIPTION
        An Az session's Graph token carries whatever the Azure PowerShell client holds, which is usually
        Directory.AccessAsUser.All: broad enough for directory writes, so it counts as covering the
        narrower scopes. Anything genuinely absent is returned so the caller can ask for a sign in that
        does cover it, before planning rather than halfway through applying.
    #>
    Param(
        [Parameter(Mandatory = $true)][String]$Token,
        [Parameter(Mandatory = $true)][String[]]$Required
    )

    $claims = Get-M365PTokenClaims -Token $Token
    if (!$claims) { return @($Required) }

    $held = @("$($claims.scp)" -split " " | Where-Object { $_ })
    #one broad delegated scope that genuinely covers the directory writes this script makes
    if ($held -contains "Directory.AccessAsUser.All") { return @() }

    return @($Required | Where-Object { $held -notcontains $_ })
}

# ------------------------------------------------------------------------------------------------
# Calls
# ------------------------------------------------------------------------------------------------

function Invoke-M365PCall {
    <#
        .SYNOPSIS
        One REST call against an audience, with the run's token.

        .DESCRIPTION
        Single place for headers, paging and error unwrapping, so a handler reads as the thing it is
        trying to do. Graph puts the useful part of a failure in the response body, never the exception
        message, so that is what is surfaced.
    #>
    Param(
        [Parameter(Mandatory = $true)][String]$Uri,
        [String]$Method = "GET",
        [Object]$Body,
        [String]$Audience = "graph",
        [Hashtable]$ExtraHeaders = @{},
        [String]$ContentType = "application/json",
        [Switch]$NoPaging
    )

    $token = Get-M365PToken -Audience $Audience
    $headers = @{ Authorization = "Bearer $token"; "Accept-Language" = "en-US" }

    #SharePoint answers Atom XML unless asked for json, which would arrive as unparseable text
    if ($Audience -notin @("graph", "arm")) { $headers["Accept"] = "application/json;odata=nometadata" }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }

    $results = [System.Collections.Generic.List[Object]]::new()
    $next = $Uri

    while ($next) {
        $splat = @{ Uri = $next; Method = $Method; Headers = $headers; ErrorAction = "Stop" }
        if ($Null -ne $Body) {
            $splat.Body = $(if ($Body -is [String]) { $Body } else { $Body | ConvertTo-Json -Depth 10 })
            $splat.ContentType = $ContentType
        }

        try {
            $response = Invoke-RestMethod @splat
        }catch {
            $reason = $Null
            try { $reason = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { $reason = $Null }
            if (!$reason) { $reason = $_.Exception.Message }
            Throw "$Method $next failed: $reason"
        }

        if ($Null -eq $response) { break }
        if ($response.PSObject.Properties.Name -contains "value") {
            foreach ($item in @($response.value)) { $results.Add($item) }
            $next = $(if ($NoPaging) { $Null } else { $response.'@odata.nextLink' })
        }else {
            $results.Add($response)
            $next = $Null
        }
    }

    return $results.ToArray()
}

# ------------------------------------------------------------------------------------------------
# Handler registry
# ------------------------------------------------------------------------------------------------

function Register-M365PRemediation {
    <#
        .SYNOPSIS
        Declares what a handler can remediate and how.

        .PARAMETER Reason
        The riskQueue reason string this handles, exactly as the scanner writes it.

        .PARAMETER Categories
        The categoryShortName values it supports. An item from any other category is reported as not
        supported rather than silently skipped, so the portal can stop offering it.

        .PARAMETER RequiredFields
        Item fields without which this handler cannot work. Checked before anything is planned, so a
        contract mismatch with the portal surfaces as one clear message.

        .PARAMETER Plan
        Script block: param($item, $context). Reads only. Returns zero or more action objects built
        with New-M365PAction.
    #>
    Param(
        [Parameter(Mandatory = $true)][String]$Reason,
        [Parameter(Mandatory = $true)][String[]]$Categories,
        [Parameter(Mandatory = $true)][ScriptBlock]$Plan,
        [String[]]$RequiredScopes = @(),
        [String[]]$RequiredFields = @("targetPath"),
        [String]$Description = ""
    )

    $script:M365PHandlers.Add([PSCustomObject]@{
            Reason         = $Reason
            Categories     = @($Categories)
            Plan           = $Plan
            RequiredScopes = @($RequiredScopes)
            RequiredFields = @($RequiredFields)
            Description    = $Description
        })
}

function Get-M365PHandler {
    Param([Parameter(Mandatory = $true)][String]$Reason)
    return @($script:M365PHandlers | Where-Object { $_.Reason -eq $Reason }) | Select-Object -First 1
}

function Get-M365PHandlers { return @($script:M365PHandlers) }

function New-M365PAction {
    <#
        .SYNOPSIS
        One change, described before it happens.

        .PARAMETER Summary
        One line, in the administrator's terms, of what will change. This is what they approve.

        .PARAMETER Apply
        Script block: param($action, $context). The only thing in this engine that writes.

        .PARAMETER Undo
        What it takes to put this back, as a plain object the rollback file can carry. Omit when the
        platform cannot restore it, and the plan will say the change is permanent.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][String]$Summary,
        [Parameter(Mandatory = $true)][ScriptBlock]$Apply,
        [String]$Target = "",
        [String[]]$Detail = @(),
        [Object]$Undo,
        [Object]$State
    )

    return [PSCustomObject]@{
        Item       = $Item
        Reason     = $Item.reason
        Summary    = $Summary
        Target     = $(if ($Target) { $Target } else { "$($Item.targetPath)" })
        Detail     = @($Detail)
        Apply      = $Apply
        Undo       = $Undo
        Reversible = ($Null -ne $Undo)
        State      = $State
    }
}

# ------------------------------------------------------------------------------------------------
# Self protection
# ------------------------------------------------------------------------------------------------

function Initialize-M365PProtection {
    <#
        .SYNOPSIS
        Builds the list of identities this script refuses to touch.

        .DESCRIPTION
        Removing the scanner's own Graph role or the portal's own access would leave the customer with a
        product that cannot see anything and a portal nobody can sign in to, and the finding that led to
        it would still be there. The caller passes the deployment's own ids; the display name match is a
        backstop for a caller that forgets.
    #>
    Param([String[]]$ProtectedAppIds = @())

    $protected = [System.Collections.Generic.HashSet[String]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($appId in @($ProtectedAppIds | Where-Object { $_ })) { $Null = $protected.Add($appId) }

    #the client this script itself is signed in with, so a run can never cut off its own hands
    $graphToken = Get-M365PToken -Audience "graph"
    $claims = Get-M365PTokenClaims -Token $graphToken
    if ($claims.appid) { $Null = $protected.Add($claims.appid) }

    $script:M365PProtectedAppIds = $protected
    $script:M365PProtectedNamePattern = "^(M365Permissions|m365vm|watcher|m365pf)"
    return $protected
}

function Test-M365PIsProtected {
    <#
        .SYNOPSIS
        Whether an identity belongs to the product itself.
    #>
    Param([String]$AppId, [String]$DisplayName, [String]$ObjectId)

    foreach ($candidate in @($AppId, $ObjectId)) {
        if ($candidate -and $script:M365PProtectedAppIds -and $script:M365PProtectedAppIds.Contains($candidate)) { return $True }
    }
    if ($DisplayName -and $script:M365PProtectedNamePattern -and $DisplayName -match $script:M365PProtectedNamePattern) { return $True }
    return $False
}

# ------------------------------------------------------------------------------------------------
# SharePoint helpers, shared by every sharing related handler
# ------------------------------------------------------------------------------------------------

function Split-M365PSharePointPath {
    <#
        .SYNOPSIS
        Breaks a scan targetPath into the pieces Graph needs: host, site path, library and item path.

        .DESCRIPTION
        The scan records a url. Graph addresses the same thing as a site, then a drive, then a path
        inside that drive, so the url has to be taken apart. Personal sites live under /personal/<user>
        and everything else under /sites/<name> or /teams/<name>, with the site collection root as the
        remaining case.
    #>
    Param([Parameter(Mandatory = $true)][String]$TargetPath)

    $uri = $Null
    try { $uri = [Uri]$TargetPath } catch { Throw "targetPath is not a url: $TargetPath" }

    $segments = @($uri.AbsolutePath.Trim("/") -split "/" | Where-Object { $_ })
    $decoded = @($segments | ForEach-Object { [Uri]::UnescapeDataString($_) })

    $sitePath = ""
    $rest = @()
    if ($decoded.Count -ge 2 -and $decoded[0] -in @("personal", "sites", "teams")) {
        $sitePath = "/$($decoded[0])/$($decoded[1])"
        $rest = @($decoded | Select-Object -Skip 2)
    }else {
        $rest = @($decoded)
    }

    #the first remaining segment is the document library, which Graph calls a drive. The default drive
    #covers Documents and Shared Documents, which is what the scanner reports on in practice.
    $library = $Null
    $itemPath = @()
    if ($rest.Count -gt 0) {
        $library = $rest[0]
        $itemPath = @($rest | Select-Object -Skip 1)
    }

    return [PSCustomObject]@{
        Host      = $uri.Host
        SitePath  = $sitePath
        Library   = $library
        ItemPath  = ($itemPath -join "/")
        IsSiteRoot = ($rest.Count -eq 0)
    }
}

function Get-M365PSiteId {
    Param([Parameter(Mandatory = $true)][String]$HostName, [String]$SitePath)
    $key = "site:$HostName$SitePath"
    if ($script:M365PCache.ContainsKey($key)) { return $script:M365PCache[$key] }

    $uri = if ($SitePath) { "https://graph.microsoft.com/v1.0/sites/$($HostName):$([Uri]::EscapeDataString($SitePath).Replace('%2F','/'))" }
           else { "https://graph.microsoft.com/v1.0/sites/$HostName" }
    $site = @(Invoke-M365PCall -Uri $uri -NoPaging) | Select-Object -First 1
    if (!$site.id) { Throw "No SharePoint site at $HostName$SitePath" }

    $script:M365PCache[$key] = $site.id
    return $site.id
}

function Get-M365PDriveId {
    Param([Parameter(Mandatory = $true)][String]$SiteId)
    $key = "drive:$SiteId"
    if ($script:M365PCache.ContainsKey($key)) { return $script:M365PCache[$key] }

    $drive = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drive" -NoPaging) | Select-Object -First 1
    if (!$drive.id) { Throw "No default document library on site $SiteId" }

    $script:M365PCache[$key] = $drive.id
    return $drive.id
}

function Resolve-M365PDriveItem {
    <#
        .SYNOPSIS
        The drive item a scan targetPath points at, with its permissions.

        .DESCRIPTION
        Returns $null for a site level target, which Graph cannot address as an item: those are the
        findings that need the SharePoint handler and its own sign in.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Item)

    $parts = Split-M365PSharePointPath -TargetPath $Item.targetPath
    if ($parts.IsSiteRoot) { return $Null }

    $siteId = Get-M365PSiteId -HostName $parts.Host -SitePath $parts.SitePath
    $driveId = Get-M365PDriveId -SiteId $siteId

    $itemUri = if ($parts.ItemPath) {
        "https://graph.microsoft.com/v1.0/drives/$driveId/root:/$(($parts.ItemPath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')"
    }else {
        "https://graph.microsoft.com/v1.0/drives/$driveId/root"
    }

    $driveItem = @(Invoke-M365PCall -Uri $itemUri -NoPaging) | Select-Object -First 1
    if (!$driveItem.id) { Throw "Could not find $($Item.targetPath) in the document library" }

    $permissions = @(Invoke-M365PCall -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/items/$($driveItem.id)/permissions")

    return [PSCustomObject]@{
        SiteId      = $siteId
        DriveId     = $driveId
        ItemId      = $driveItem.id
        Name        = $driveItem.name
        WebUrl      = $driveItem.webUrl
        Permissions = $permissions
    }
}

function Test-M365PHasGraphSharing {
    <#
        .SYNOPSIS
        Whether this run's Graph token can change sharing, which decides how sharing is remediated.

        .DESCRIPTION
        Graph's drive item permissions can expire a link or downgrade it in place, which is gentler and
        reversible, but it needs Sites or Files write scopes. A borrowed Azure CLI or Azure PowerShell
        session does not carry those, and asking for them means an interactive sign in. So when they are
        absent the sharing handlers use SharePoint's own API instead, which the same session can reach,
        at the cost of removing a link rather than adjusting it. The plan always states which it is.
    #>
    $claims = Get-M365PTokenClaims -Token (Get-M365PToken -Audience "graph")
    if (!$claims) { return $False }
    $held = @("$($claims.scp)" -split " " | Where-Object { $_ })
    return (@("Sites.ReadWrite.All", "Sites.FullControl.All", "Files.ReadWrite.All", "Sites.Manage.All") | Where-Object { $held -contains $_ }).Count -gt 0
}

function Resolve-M365PSharePointItem {
    <#
        .SYNOPSIS
        The list and item ids SharePoint needs for a scan targetPath, through SharePoint's own API.

        .DESCRIPTION
        The sharing endpoints address an item as a list plus an item id, so the url has to be turned into
        those. A file is tried first and then a folder, because the scan records both and the path alone
        does not say which it is. Returns $null for a site level target, which has no list item at all.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Item)

    $parts = Split-M365PSharePointPath -TargetPath $Item.targetPath
    if ($parts.IsSiteRoot) { return $Null }

    $siteUrl = "https://$($parts.Host)$($parts.SitePath)"
    $serverRelative = "$($parts.SitePath)/$($parts.Library)"
    if ($parts.ItemPath) { $serverRelative = "$serverRelative/$($parts.ItemPath)" }

    #a literal inside decodedurl('...'), so an apostrophe in a file name has to be doubled
    $literal = $serverRelative.Replace("'", "''")
    $select = "?`$expand=ParentList&`$select=Id,ParentList/Id,FileLeafRef"

    $listItem = $Null
    foreach ($accessor in @("GetFileByServerRelativePath", "GetFolderByServerRelativePath")) {
        try {
            $listItem = @(Invoke-M365PCall -Audience "https://$($parts.Host)" -NoPaging `
                    -Uri "$siteUrl/_api/web/$accessor(decodedurl='$literal')/ListItemAllFields$select") | Select-Object -First 1
            if ($listItem.Id) { break }
        }catch {
            $listItem = $Null
        }
    }

    if (!$listItem.Id) { Throw "Could not find $($Item.targetPath) in SharePoint" }

    return [PSCustomObject]@{
        Host              = $parts.Host
        SiteUrl           = $siteUrl
        ServerRelativeUrl = $serverRelative
        ListId            = "$($listItem.ParentList.Id)"
        ItemId            = [Int]$listItem.Id
        Name              = $(if ($listItem.FileLeafRef) { $listItem.FileLeafRef } else { @($serverRelative -split "/")[-1] })
        WebUrl            = "https://$($parts.Host)$serverRelative"
    }
}

function Get-M365PSharingInformation {
    <#
        .SYNOPSIS
        The sharing links and direct grants on one list item, as SharePoint reports them.

        .DESCRIPTION
        The expand is what makes it return the links and the people rather than only scalar settings.
        Every value needed to remove a link later (its kind and its share id) comes from here and is
        echoed back verbatim, so nothing depends on this script's idea of what the kind numbers mean.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Resolved)

    $uri = "$($Resolved.SiteUrl)/_api/web/Lists('$($Resolved.ListId)')/GetItemById($($Resolved.ItemId))/GetSharingInformation?`$Expand=permissionsInformation,pickerSettings"
    $info = @(Invoke-M365PCall -Audience "https://$($Resolved.Host)" -Uri $uri -Method "POST" -Body @{} -NoPaging) | Select-Object -First 1

    $links = @()
    foreach ($link in @($info.permissionsInformation.links)) {
        $detail = $link.linkDetails
        if (!$detail) { continue }
        $links += [PSCustomObject]@{
            ShareId     = "$($detail.ShareId)"
            LinkKind    = $detail.LinkKind
            Url         = "$($detail.Url)"
            IsEdit      = [Boolean]$detail.IsEditLink
            IsActive    = [Boolean]$detail.IsActive
            Anonymous   = ([Boolean]$detail.AllowsAnonymousAccess) -or ("$($detail.Scope)" -eq "1")
            Scope       = "$($detail.Scope)"
            Expiration  = "$($detail.Expiration)"
            Invitations = @($detail.Invitations)
            Raw         = $detail
        }
    }

    return [PSCustomObject]@{
        Links      = @($links | Where-Object { $_.IsActive -or !$_.PSObject.Properties.Name.Contains("IsActive") })
        Principals = @($info.permissionsInformation.principals)
        Raw        = $info
    }
}

function Get-M365PSharePointLinkDescription {
    <#
        .SYNOPSIS
        One readable line for a SharePoint sharing link.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Link)

    $audience = if ($Link.Anonymous) { "anyone with the link" }
                elseif ("$($Link.Scope)" -eq "2") { "everyone in the organisation" }
                elseif ("$($Link.Scope)" -eq "3") { "specific people" }
                else { "link" }
    $rights = if ($Link.IsEdit) { "edit" } else { "view" }
    $expiry = if ($Link.Expiration) { "expires $($Link.Expiration.Substring(0, [Math]::Min(10, $Link.Expiration.Length)))" } else { "never expires" }
    $shared = if (@($Link.Invitations).Count -gt 0) { ", shared with $(@($Link.Invitations).Count) named recipient(s)" } else { "" }

    return "$audience ($rights, $expiry$shared)"
}

function New-M365PUnshareLinkAction {
    <#
        .SYNOPSIS
        An action that deletes one SharePoint sharing link.

        .DESCRIPTION
        No inverse: a recreated link gets a new url, so anything holding the old one stays cut off even
        after a rollback. The detail lines carry what it takes to share it again deliberately.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][Object]$Resolved,
        [Parameter(Mandatory = $true)][Object]$Link,
        [Parameter(Mandatory = $true)][String]$Summary,
        [String[]]$Detail = @()
    )

    $lines = @("removing: $(Get-M365PSharePointLinkDescription -Link $Link)") + $Detail
    if ($Link.Url) { $lines += "link url: $($Link.Url)" }
    $lines += "recipients of this link lose access, and a new link would have a different url"

    return New-M365PAction -Item $Item -Summary $Summary -Target $Resolved.WebUrl -Detail $lines `
        -State @{
            Uri      = "$($Resolved.SiteUrl)/_api/web/Lists('$($Resolved.ListId)')/GetItemById($($Resolved.ItemId))/UnshareLink"
            Audience = "https://$($Resolved.Host)"
            Body     = @{ linkKind = $Link.LinkKind; shareId = $Link.ShareId }
        } `
        -Apply {
        Param($action, $context)
        $Null = Invoke-M365PCall -Audience $action.State.Audience -Uri $action.State.Uri -Method "POST" -Body $action.State.Body
    }
}

function New-M365PRemoveRoleAssignmentAction {
    <#
        .SYNOPSIS
        An action that removes one principal's direct grant on a SharePoint item.

        .DESCRIPTION
        Reversible: the same principal and role definition can be granted back, which is what the
        rollback file carries.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Item,
        [Parameter(Mandatory = $true)][Object]$Resolved,
        [Parameter(Mandatory = $true)][Object]$Principal,
        [Parameter(Mandatory = $true)][String]$Summary,
        [String[]]$Detail = @()
    )

    $base = "$($Resolved.SiteUrl)/_api/web/Lists('$($Resolved.ListId)')/items($($Resolved.ItemId))/roleassignments"
    $roleId = @($Principal.roleDefinitionIds) | Select-Object -First 1

    $undo = $Null
    if ($roleId) {
        $undo = @{
            type     = "sharePointPost"
            audience = "https://$($Resolved.Host)"
            uri      = "$base/addroleassignment(principalid=$($Principal.id),roledefid=$roleId)"
        }
    }

    return New-M365PAction -Item $Item -Summary $Summary -Target $Resolved.WebUrl -Detail $Detail `
        -State @{ Uri = "$base/removeroleassignment(principalid=$($Principal.id))"; Audience = "https://$($Resolved.Host)" } `
        -Apply {
        Param($action, $context)
        $Null = Invoke-M365PCall -Audience $action.State.Audience -Uri $action.State.Uri -Method "POST"
    } `
        -Undo $undo
}

function Get-M365PPermissionDescription {
    <#
        .SYNOPSIS
        One readable line for a drive item permission, for the plan the administrator approves.
    #>
    Param([Parameter(Mandatory = $true)][Object]$Permission)

    $roles = @($Permission.roles) -join "+"
    if (!$roles) { $roles = "none" }

    if ($Permission.link) {
        $expiry = if ($Permission.expirationDateTime) { "expires $((ConvertTo-M365PDate -Value $Permission.expirationDateTime).ToString('yyyy-MM-dd'))" } else { "never expires" }
        $password = if ($Permission.hasPassword) { ", password protected" } else { "" }
        return "$($Permission.link.scope) link ($roles, $expiry$password)"
    }

    $who = @(@($Permission.grantedToIdentitiesV2) | ForEach-Object {
            if ($_.user.displayName) { $_.user.displayName }
            elseif ($_.siteUser.displayName) { $_.siteUser.displayName }
            elseif ($_.group.displayName) { $_.group.displayName }
            else { "unknown" }
        })
    if (!$who -and $Permission.grantedToV2) {
        $who = @($Permission.grantedToV2.user.displayName, $Permission.grantedToV2.siteUser.displayName, $Permission.grantedToV2.group.displayName | Where-Object { $_ })
    }
    return "direct grant to $(($who | Select-Object -Unique) -join ', ') ($roles)"
}

function Test-M365PPermissionMatchesPrincipal {
    <#
        .SYNOPSIS
        Whether a drive item permission is the one the finding is about.

        .DESCRIPTION
        The scan identifies a principal by Entra id when it has one, and otherwise by the login name or
        e-mail SharePoint gave it, which is the only handle an external user or an anonymous link has.
        All three are compared, because which one is populated depends on the category.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object]$Permission,
        [Parameter(Mandatory = $true)][Object]$Item
    )

    $wanted = @($Item.principalId, $Item.principalName, $Item.principalUpn | Where-Object { $_ })
    if ($wanted.Count -eq 0) { return $False }

    $identities = @(@($Permission.grantedToIdentitiesV2) + @($Permission.grantedToV2) | Where-Object { $_ })
    foreach ($identity in $identities) {
        $candidates = @(
            $identity.user.id, $identity.user.email, $identity.user.displayName, $identity.user.userPrincipalName,
            $identity.siteUser.loginName, $identity.siteUser.email, $identity.siteUser.displayName,
            $identity.group.id, $identity.group.displayName
        ) | Where-Object { $_ }

        foreach ($candidate in $candidates) {
            foreach ($target in $wanted) {
                if ($candidate -eq $target) { return $True }
                #SharePoint login names carry a claims prefix and guests carry the #EXT# marker, so the
                #address the scan recorded is a substring rather than the whole value
                if ("$candidate" -like "*$target*") { return $True }
            }
        }
    }
    return $False
}

# ------------------------------------------------------------------------------------------------
# Plan, approve, apply
# ------------------------------------------------------------------------------------------------

function Show-M365PPlan {
    <#
        .SYNOPSIS
        Prints the plan and returns $true when the administrator approved it.

        .DESCRIPTION
        Grouped by reason, numbered, with the irreversible changes called out separately: approving
        twenty link expiries is a different decision from approving one permanent deletion, and the
        difference has to be visible without reading every line.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object[]]$Actions,
        [Switch]$Approve,
        [Switch]$PlanOnly
    )

    Write-M365PStep "This is what would change"

    $index = 0
    foreach ($group in ($Actions | Group-Object Reason | Sort-Object Name)) {
        Write-M365PLine ""
        Write-M365PLine "  $($group.Name) ($($group.Count))" -Colour White
        foreach ($action in $group.Group) {
            $index++
            $flag = if ($action.Reversible) { " " } else { "!" }
            Write-M365PLine "   $flag $index. $($action.Summary)"
            Write-M365PDetail "      on $($action.Target)"
            foreach ($line in @($action.Detail)) { Write-M365PDetail "      $line" }
        }
    }

    $skips = Get-M365PSkips
    if ($skips.Count -gt 0) {
        Write-M365PLine ""
        Write-M365PLine "  Not acted on ($($skips.Count))" -Colour DarkYellow
        foreach ($skip in $skips) {
            Write-M365PWarn "   - $($skip.Reason) on $($skip.Target)"
            Write-M365PDetail "      $($skip.Why)"
        }
    }

    $permanent = @($Actions | Where-Object { !$_.Reversible })
    Write-M365PLine ""
    Write-M365PLine "  $($Actions.Count) change(s), $($permanent.Count) of them marked ! because they cannot be undone automatically." -Colour White
    if ($permanent.Count -gt 0) {
        Write-M365PDetail "The log records everything needed to recreate them by hand."
    }
    Write-M365PDetail "Log:      $($script:M365PLogFile)"
    Write-M365PDetail "Actions:  $($script:M365PRecordFile)"
    Write-M365PDetail "Rollback: $($script:M365PRollbackFile) (written for the reversible ones)"

    if ($PlanOnly) {
        Write-M365PLine ""
        Write-M365PWarn "Plan only, nothing was changed. Run the same command without -WhatIf to apply it."
        return $False
    }

    if ($Approve) {
        Write-M365PLine ""
        Write-M365PWarn "-Approve was passed, so applying without asking."
        return $True
    }

    Write-M365PLine ""
    $answer = Read-Host "  Type yes to apply these $($Actions.Count) change(s), anything else to cancel"
    if ("$answer".Trim().ToLower() -in @("yes", "y")) { return $True }

    Write-M365PWarn "Cancelled, nothing was changed."
    return $False
}

function Invoke-M365PActions {
    <#
        .SYNOPSIS
        Applies an approved plan, one action at a time, recording each outcome before moving on.
    #>
    Param(
        [Parameter(Mandatory = $true)][Object[]]$Actions,
        [Parameter(Mandatory = $true)][Object]$Context
    )

    Write-M365PStep "Applying"

    $applied = 0
    $failed = 0
    $index = 0

    foreach ($action in $Actions) {
        $index++
        Write-M365PLine "  $index/$($Actions.Count) $($action.Summary)"

        $record = [Ordered]@{
            at         = [DateTime]::UtcNow.ToString("o")
            reason     = $action.Reason
            riskItemId = $action.Item.id
            target     = $action.Target
            summary    = $action.Summary
            reversible = $action.Reversible
            outcome    = "unknown"
        }

        try {
            $Null = & $action.Apply $action $Context
            $record.outcome = "applied"
            $applied++
            Write-M365PGood "   done"
            if ($action.Undo) {
                $script:M365PRollback.Add([Ordered]@{
                        at      = $record.at
                        reason  = $action.Reason
                        summary = "Undo: $($action.Summary)"
                        undo    = $action.Undo
                    })
            }
        }catch {
            $record.outcome = "failed"
            $record.error = "$($_.Exception.Message)"
            $failed++
            Write-M365PBad "   failed: $($_.Exception.Message)"
        }

        Write-M365PRecord -Record $record
    }

    if ($script:M365PRollback.Count -gt 0) {
        try {
            $script:M365PRollback | ConvertTo-Json -Depth 10 | Set-Content -Path $script:M365PRollbackFile -ErrorAction Stop
        }catch {
            Write-M365PWarn "Could not write the rollback file: $($_.Exception.Message)"
        }
    }

    Write-M365PLine ""
    Write-M365PLine "  $applied applied, $failed failed." -Colour $(if ($failed -gt 0) { "DarkYellow" } else { "Green" })
    return [PSCustomObject]@{ Applied = $applied; Failed = $failed }
}
