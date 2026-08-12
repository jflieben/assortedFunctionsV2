<#
    M365Permissions shared permission engine.

    Master copy: https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/permissions-lib.ps1
    Companion definition: permissions.json (same folder)

    Two consumers, one source:
      - authorize.ps1 fetches and dot-sources this at runtime (Azure Cloud Shell, PowerShell 7, Linux)
      - the scanner VM ships a vendored copy in the module so it never needs network access at scan time

    Constraints this file must keep honouring:
      - plain PowerShell 7, no module dependencies
      - callers supply tokens through a scriptblock
      - function definitions only at top level, no executable statements
      - nothing ever hard fails: a grant that cannot be evaluated degrades, it does not abort the run

    Grant states:
      granted        the permission is in place
      satisfied      absent, but a broader permission the tenant already holds covers it (audit only)
      missing        the permission is applicable but absent
      notApplicable  a condition excluded it (and it is pruned if it was previously granted)
      unavailable    no usable token for that resource in this context, so the answer is unknown
      error          the test or apply threw
#>

function Write-M365PLog {
    Param(
        [Parameter(Mandatory = $true)][String]$Message,
        [ValidateSet("Info", "Warning", "Error", "Verbose")][String]$Level = "Info"
    )

    # inside the scanner module we log through the product logger, everywhere else we just write to the host
    if (Get-Command -Name Write-LogMessage -ErrorAction SilentlyContinue) {
        $mapped = switch ($Level) { "Error" { 3 } "Warning" { 3 } "Verbose" { 5 } default { 4 } }
        Write-LogMessage -Message $Message -Level $mapped
        return
    }

    switch ($Level) {
        "Error"   { Write-Host $Message -ForegroundColor Red }
        "Warning" { Write-Host $Message -ForegroundColor DarkYellow }
        "Verbose" { Write-Verbose $Message }
        default   { Write-Host $Message }
    }
}

function Get-M365PDefinition {
    <#
        .SYNOPSIS
        Fetches and validates the permission definition.

        .DESCRIPTION
        -Path wins when supplied (the VM uses its bundled copy so scans never depend on the network).
        Otherwise the published copy is fetched, with -FallbackPath used when that fails.
    #>
    Param(
        [String]$Uri = "https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/permissions.json",
        [String]$Path,
        [String]$FallbackPath
    )

    $raw = $null

    if ($Path) {
        if (!(Test-Path -Path $Path)) { Throw "Permission definition not found at $Path" }
        $raw = Get-Content -Path $Path -Raw
    }
    else {
        try {
            $raw = Invoke-RestMethod -Uri $Uri -Method GET -ErrorAction Stop -Verbose:$false
            if ($raw -isnot [String]) { $raw = $raw | ConvertTo-Json -Depth 20 }
        }
        catch {
            Write-M365PLog -Level Warning -Message "Could not fetch the permission definition from $Uri : $($_.Exception.Message)"
            if ($FallbackPath -and (Test-Path -Path $FallbackPath)) {
                Write-M365PLog -Level Warning -Message "Falling back to the bundled copy at $FallbackPath"
                $raw = Get-Content -Path $FallbackPath -Raw
            }
            else {
                Throw "No permission definition available (fetch failed and no usable fallback)"
            }
        }
    }

    $definition = $raw | ConvertFrom-Json
    if (!$definition.grants -or !$definition.resources) { Throw "Permission definition is malformed: no grants or no resources" }
    if (!$definition.revision) { Throw "Permission definition is malformed: no revision" }

    Write-M365PLog -Level Verbose -Message "Loaded permission definition revision $($definition.revision) with $(@($definition.grants).Count) grants"
    return $definition
}

function New-M365PContext {
    <#
        .SYNOPSIS
        Builds the run context every other function in this file takes.

        .PARAMETER TokenProvider
        Scriptblock taking a single audience string and returning a bearer token string, or $null when
        that audience cannot be served. It is called lazily and its results are cached per audience.
    #>
    Param(
        [Parameter(Mandatory = $true)][ScriptBlock]$TokenProvider,
        [Parameter(Mandatory = $true)]$Definition,
        [String]$TenantId,
        [String]$ScannerAppId,
        [String]$ScannerSpnObjectId,
        [String]$ScannerDisplayName,
        [String]$FrontendAppId,
        [String]$FrontendAppObjectId,
        [String]$FrontendSpnObjectId,
        [String]$FrontendUrl,
        [String[]]$Surfaces = @(),
        [Boolean]$Orchestration = $false,
        [ValidateSet("ManagedIdentity", "ServicePrincipal")][String]$AuthMode = "ManagedIdentity",
        [ValidateSet("None", "Auto", "Existing")][String]$MailMode = "None",
        [String]$MailAddress,
        [String]$RunningUserId,
        [Boolean]$MspOnboarding = $false,
        [String]$SubscriptionId
    )

    return @{
        tokenProvider       = $TokenProvider
        definition          = $Definition
        tenantId            = $TenantId
        scannerAppId        = $ScannerAppId
        scannerSpnObjectId  = $ScannerSpnObjectId
        scannerDisplayName  = $ScannerDisplayName
        frontendAppId       = $FrontendAppId
        frontendAppObjectId = $FrontendAppObjectId
        frontendSpnObjectId = $FrontendSpnObjectId
        frontendUrl         = $FrontendUrl
        surfaces            = @($Surfaces)
        orchestration       = $Orchestration
        authMode            = $AuthMode
        mailMode            = $MailMode
        mailAddress         = $MailAddress
        runningUserId       = $RunningUserId
        mspOnboarding       = $MspOnboarding
        subscriptionId      = $SubscriptionId
        cache               = @{}
    }
}

function Get-M365PToken {
    <#
        .SYNOPSIS
        Resolves a token for a resource key from the definition, or for a literal audience.
        Returns $null when no audience for that resource can be served in this context.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [String]$ResourceKey,
        [String]$Audience
    )

    if (!$Context.cache.tokens) { $Context.cache.tokens = @{} }

    $audiences = @()
    if ($Audience) {
        $audiences = @($Audience)
    }
    elseif ($ResourceKey) {
        $resource = $Context.definition.resources.PSObject.Properties[$ResourceKey]
        if (!$resource) { Throw "Unknown resource key '$ResourceKey' in the permission definition" }
        $audiences = @($resource.Value.tokenResources)
    }

    if ($audiences.Count -eq 0) { return $null }

    foreach ($aud in $audiences) {
        if ($Context.cache.tokens.ContainsKey($aud)) {
            if ($Context.cache.tokens[$aud]) { return $Context.cache.tokens[$aud] }
            continue
        }
        $token = $null
        try { $token = & $Context.tokenProvider $aud } catch { $token = $null }
        $Context.cache.tokens[$aud] = $token
        if ($token) {
            Write-M365PLog -Level Verbose -Message "Acquired a token for $aud"
            return $token
        }
        Write-M365PLog -Level Verbose -Message "No token available for $aud"
    }

    return $null
}

function Invoke-M365PRest {
    <#
        .SYNOPSIS
        Minimal REST helper with paging, retries and a consistent 'unavailable' signal.
        Throws a message starting with M365PUNAVAILABLE when no token can be obtained.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$Uri,
        [ValidateSet("GET", "POST", "PATCH", "PUT", "DELETE")][String]$Method = "GET",
        [String]$ResourceKey = "graph",
        [String]$Audience,
        $Body,
        [Switch]$NoPagination,
        [Switch]$Raw,
        [Int]$MaxAttempts = 3,
        [Hashtable]$ExtraHeaders = @{}
    )

    $token = Get-M365PToken -Context $Context -ResourceKey $ResourceKey -Audience $Audience
    if (!$token) { Throw "M365PUNAVAILABLE: no token for resource '$(if($Audience){$Audience}else{$ResourceKey})'" }

    $headers = @{ "Authorization" = "Bearer $token"; "Accept" = "application/json" }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }

    if ($Body -and $Body -isnot [String]) { $Body = $Body | ConvertTo-Json -Depth 20 }

    $results = @()
    $nextUrl = $Uri

    while ($nextUrl) {
        $attempt = 0
        $data = $null
        $pageHeaders = $null
        while ($attempt -lt $MaxAttempts) {
            $attempt++
            try {
                if ($Method -in @("POST", "PATCH", "PUT") -and $Body) {
                    $data = Invoke-RestMethod -Uri $nextUrl -Method $Method -Headers $headers -Body $Body -ContentType "application/json; charset=utf-8" -ErrorAction Stop -Verbose:$false -ResponseHeadersVariable pageHeaders
                }
                else {
                    $data = Invoke-RestMethod -Uri $nextUrl -Method $Method -Headers $headers -ErrorAction Stop -Verbose:$false -ResponseHeadersVariable pageHeaders
                }
                break
            }
            catch {
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch {}
                # never retry a definitive answer, only transient ones
                if ($attempt -ge $MaxAttempts -or ($status -and $status -notin @(429, 500, 502, 503, 504))) { Throw $_ }
                Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(3, $attempt)))
            }
        }

        if ($Raw) { return $data }

        if ($null -ne $data -and $data.PSObject.Properties.Name -contains "value") {
            $results += @($data.value)
        }
        elseif ($null -ne $data) {
            $results += @($data)
        }

        if ($NoPagination) { break }

        # Azure DevOps does not put its continuation token in the body like the others do, it comes
        # back as a response header and is fed to the next call as a query parameter
        $continuationToken = $null
        if ($pageHeaders -and $pageHeaders["X-MS-ContinuationToken"]) { $continuationToken = @($pageHeaders["X-MS-ContinuationToken"])[0] }

        $nextUrl = $null
        if ($data.PSObject.Properties.Name -contains "@odata.nextLink") { $nextUrl = $data.'@odata.nextLink' }
        elseif ($data.PSObject.Properties.Name -contains "continuationUri") { $nextUrl = $data.continuationUri }
        elseif (![String]::IsNullOrWhiteSpace($continuationToken)) {
            $encoded = [System.Uri]::EscapeDataString($continuationToken)
            if ($Uri -like "*continuationToken=*") { $nextUrl = $Uri -replace "continuationToken=[^&]*", "continuationToken=$encoded" }
            else { $nextUrl = "$($Uri)$(if($Uri.Contains("?")){'&'}else{'?'})continuationToken=$encoded" }
        }
    }

    return $results
}

function Invoke-M365PExoCommand {
    <#
        .SYNOPSIS
        Runs an Exchange Online cmdlet over the REST InvokeCommand endpoint.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$Cmdlet,
        [Hashtable]$Parameters = @{}
    )

    $token = Get-M365PToken -Context $Context -ResourceKey "exo"
    if (!$token) { Throw "M365PUNAVAILABLE: no Exchange Online token in this context" }
    if (!$Context.tenantId) { Throw "Exchange Online calls need a tenantId on the context" }

    $headers = @{
        "Authorization"         = "Bearer $token"
        "Accept-Charset"        = "UTF-8"
        "X-ResponseFormat"      = "json"
        "Accept"                = "application/json"
        "X-ClientApplication"   = "ExoManagementModule"
        "Prefer"                = "odata.maxpagesize=1000"
        "X-CmdletName"          = $Cmdlet
        "X-SerializationLevel"  = "Partial"
        "X-ClientModuleVersion" = "3.9.0"
        "X-AnchorMailbox"       = "APP:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$($Context.tenantId)"
        "Content-Type"          = "application/json"
    }

    $body = @{ CmdletInput = @{ CmdletName = $Cmdlet; Parameters = $Parameters } } | ConvertTo-Json -Depth 15
    $nextUrl = "https://outlook.office365.com/adminapi/beta/$($Context.tenantId)/InvokeCommand"
    $results = @()

    while ($nextUrl) {
        $data = $null
        $attempt = 0
        while ($attempt -lt 3) {
            $attempt++
            try {
                $data = Invoke-RestMethod -Uri $nextUrl -Method POST -Body $body -Headers $headers -ErrorAction Stop -Verbose:$false
                break
            }
            catch {
                # A body that cannot be decompressed is not the cmdlet refusing. Exchange's adminapi
                # intermittently answers with content that does not match the Content-Encoding it
                # declares, which fails while the response is still being read and so carries no
                # verdict at all: the cmdlet may well have run. Retrying is the only way to find out,
                # and this is the one failure here worth retrying, because every other one is Exchange
                # objecting on purpose and will object identically the second time.
                $unreadable = ($_.Exception -is [System.IO.InvalidDataException]) -or
                              ($_.Exception.Message -like "*unsupported compression method*") -or
                              ($_.Exception.Message -like "*archive entry*")
                if (!$unreadable -or $attempt -ge 3) {
                    # the status line on its own is useless here: every rejected cmdlet reads
                    # "400 (Bad Request)" and the reason Exchange refused is only ever in the body
                    Throw "$Cmdlet failed: $(Get-M365PErrorDetail -ErrorRecord $_)"
                }
                Write-M365PLog -Level Verbose -Message "Could not read Exchange's answer to $Cmdlet, retrying"
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
        if ($null -ne $data -and $data.PSObject.Properties.Name -contains "value") { $results += @($data.value) } elseif ($null -ne $data) { $results += @($data) }
        $nextUrl = $null
        if ($data.PSObject.Properties.Name -contains "@odata.nextLink") { $nextUrl = $data.'@odata.nextLink' }
    }

    return $results
}

function Get-M365PResourceSpn {
    <#
        .SYNOPSIS
        Resolves (and in Apply mode registers) the service principal of an API resource in this tenant.
        Pre-registering is what prevents AADSTS650052 in tenants that never used the API before.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$ResourceKey,
        [Switch]$CreateIfMissing
    )

    if (!$Context.cache.resourceSpns) { $Context.cache.resourceSpns = @{} }
    if ($Context.cache.resourceSpns.ContainsKey($ResourceKey)) { return $Context.cache.resourceSpns[$ResourceKey] }

    $resource = $Context.definition.resources.PSObject.Properties[$ResourceKey]
    if (!$resource) { Throw "Unknown resource key '$ResourceKey'" }
    $appId = $resource.Value.appId

    $spn = $null
    try {
        $spn = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$appId'") | Select-Object -First 1
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        $spn = $null
    }

    if (!$spn -and $CreateIfMissing) {
        Write-M365PLog -Message "Resource '$($resource.Value.name)' is not registered in this tenant, registering it (non destructively)..."
        try {
            $spn = Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Method POST -Body @{ appId = $appId } -Raw
            Start-Sleep -Seconds 5
            Write-M365PLog -Message "Registered $($resource.Value.name) as $($spn.id)"
        }
        catch {
            Write-M365PLog -Level Warning -Message "Could not register resource '$($resource.Value.name)': $($_.Exception.Message)"
            $spn = $null
        }
    }

    $Context.cache.resourceSpns[$ResourceKey] = $spn
    return $spn
}

function Get-M365PScannerAppRoleAssignments {
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Switch]$Refresh
    )
    if ($Refresh) { $Context.cache.Remove("scannerAppRoles") }
    if ($Context.cache.scannerAppRoles) { return $Context.cache.scannerAppRoles }
    $Context.cache.scannerAppRoles = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.scannerSpnObjectId)/appRoleAssignments")
    return $Context.cache.scannerAppRoles
}

function Get-M365PGroup {
    <#
        .SYNOPSIS
        Resolves a security group by its definition alias, optionally creating it.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$GroupRef,
        [Switch]$CreateIfMissing
    )

    $groupName = $Context.definition.groups.PSObject.Properties[$GroupRef].Value
    if (!$groupName) { Throw "Unknown group alias '$GroupRef' in the permission definition" }

    if (!$Context.cache.groups) { $Context.cache.groups = @{} }
    if ($Context.cache.groups.ContainsKey($GroupRef) -and $Context.cache.groups[$GroupRef]) { return $Context.cache.groups[$GroupRef] }

    $group = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'") | Select-Object -First 1

    if (!$group -and $CreateIfMissing) {
        Write-M365PLog -Message "Creating security group $groupName..."
        $group = Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Raw -Body @{
            displayName     = $groupName
            mailEnabled     = $false
            mailNickname    = $groupName.Replace("-", "_")
            securityEnabled = $true
            groupTypes      = @()
        }
        Start-Sleep -Seconds 5
        Write-M365PLog -Message "Created $groupName ($($group.id))"
    }

    $Context.cache.groups[$GroupRef] = $group
    return $group
}

function Get-M365PDirectoryObjectIds {
    <#
        .SYNOPSIS
        Reads the object ids out of a directory object collection such as a group's owners or members.

        .DESCRIPTION
        Uses beta, deliberately. The v1.0 owners and members navigations do not return service principal
        entries, they silently come back as if the service principal were not there at all. Since the
        scanner identity IS a service principal, reading these on v1.0 reports every group as unowned
        and produces a confident wrong answer with no error to notice. The product's own group scanning
        code hit this years ago and settled on beta for the same reason.

        v1.0 is kept as a fallback only for the case where beta is unavailable, where a missing service
        principal is still better than no answer.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$CollectionUri
    )

    if ($CollectionUri -notlike "*?*") { $CollectionUri = "$($CollectionUri)?`$select=id" }

    try {
        return @((Invoke-M365PRest -Context $Context -Uri ($CollectionUri -replace "/v1\.0/", "/beta/")).id)
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        Write-M365PLog -Level Verbose -Message "beta read of $CollectionUri failed ($($_.Exception.Message)), falling back to v1.0"
        return @((Invoke-M365PRest -Context $Context -Uri $CollectionUri).id)
    }
}

function Get-M365PErrorDetail {
    <#
        .SYNOPSIS
        The reason Graph gave for a failed call.

        .DESCRIPTION
        Invoke-RestMethod puts nothing usable in the exception message: every rejected call reads
        "Response status code does not indicate success: 400 (Bad Request)" regardless of what went
        wrong. The actual reason is in the response body, which lands on ErrorDetails and survives a
        rethrow, so anything matching on why a call failed has to read that instead.
    #>
    Param(
        [Parameter(Mandatory = $true)]$ErrorRecord
    )

    $detail = $ErrorRecord.ErrorDetails.Message
    if ([String]::IsNullOrWhiteSpace($detail)) { return "$($ErrorRecord.Exception.Message)" }

    $parsed = $null
    try { $parsed = $detail | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    if (!$parsed) { return "$detail" }

    # Exchange answers every failure with error.message = "Error executing cmdlet" and buries the
    # cmdlet's actual objection in a JSON string nested inside error.details, so the outer message is
    # worthless on its own and has to be unwrapped one level further
    foreach ($item in @($parsed.error.details)) {
        if (!$item.message) { continue }
        $inner = $null
        try { $inner = $item.message | ConvertFrom-Json -ErrorAction Stop } catch { $inner = $null }
        if ($inner.Message) { return "$($inner.Message)" }
        return "$($item.message)"
    }

    if ($parsed.error.message) { return "$($parsed.error.message)" }
    # ARM does not always use the error envelope, some providers answer with code/message at the root
    if ($parsed.message) { return "$($parsed.message)" }
    return "$detail"
}

function Add-M365PDirectoryObjectRef {
    <#
        .SYNOPSIS
        Adds an owner or member reference, treating "already there" as success.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$CollectionUri,
        [Parameter(Mandatory = $true)][String]$ObjectId
    )
    try {
        $null = Invoke-M365PRest -Context $Context -Uri $CollectionUri -Method POST -Raw -Body @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$ObjectId" }
        return $true
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        $detail = Get-M365PErrorDetail -ErrorRecord $_
        # the reference already existing is the normal idempotent path. Graph answers that with a 400
        # whose body reads "One or more added object references already exist", so it only looks like
        # a failure until you read the body
        if ($detail -like "*already exist*") { return $true }
        Write-M365PLog -Level Warning -Message "Could not add $ObjectId to $($CollectionUri): $detail"
        return $false
    }
}

function Test-M365PCondition {
    <#
        .SYNOPSIS
        Evaluates a grant's condition against the run context. No condition means always applicable.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Grant,
        [Parameter(Mandatory = $true)]$Context
    )

    if (!$Grant.condition) { return $true }

    foreach ($property in $Grant.condition.PSObject.Properties) {
        $expected = $property.Value
        switch ($property.Name) {
            "surfaces" {
                $wanted = @($expected)
                $intersect = @($wanted | Where-Object { $Context.surfaces -contains $_ })
                if ($intersect.Count -eq 0) { return $false }
            }
            "orchestration" {
                if ([Boolean]$expected -ne [Boolean]$Context.orchestration) { return $false }
            }
            "msp" {
                if ([Boolean]$expected -ne [Boolean]$Context.mspOnboarding) { return $false }
            }
            "mailMode" {
                if (@($expected) -notcontains $Context.mailMode) { return $false }
            }
            "authMode" {
                if (@($expected) -notcontains $Context.authMode) { return $false }
            }
            default {
                Write-M365PLog -Level Warning -Message "Grant $($Grant.key) uses unknown condition '$($property.Name)', treating it as not applicable"
                return $false
            }
        }
    }

    return $true
}

function Resolve-M365PGrants {
    <#
        .SYNOPSIS
        Filters the definition against the run context and stamps each grant with applicability.
        Also derives the sender address when mail is set to Auto but no address was supplied.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)]$Context
    )

    if ($Context.mailMode -eq "Auto" -and !$Context.mailAddress) {
        try {
            $org = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/organization") | Select-Object -First 1
            $defaultDomain = ($org.verifiedDomains | Where-Object { $_.isDefault } | Select-Object -First 1).name
            if ($defaultDomain) {
                $Context.mailAddress = "m365permissions-reports@$defaultDomain"
                Write-M365PLog -Message "Mail mode is Auto with no address supplied, using $($Context.mailAddress)"
            }
        }
        catch {
            Write-M365PLog -Level Warning -Message "Could not derive a default sender address: $($_.Exception.Message)"
        }
    }

    $resolved = @()
    foreach ($grant in $Definition.grants) {
        $applicable = Test-M365PCondition -Grant $grant -Context $Context
        $resolved += [PSCustomObject]@{
            grant      = $grant
            key        = $grant.key
            applicable = $applicable
        }
    }

    return $resolved
}

#region providers

function Test-M365PGrant_entraAppRole {
    Param($Grant, $Context)

    $spn = Get-M365PResourceSpn -Context $Context -ResourceKey $Grant.resource
    if (!$spn) { return @{ state = "unavailable"; detail = "The $($Grant.resource) service principal is not present in this tenant" } }

    $appRole = $spn.appRoles | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1
    if (!$appRole) { return @{ state = "unavailable"; detail = "The API does not expose an app role named $($Grant.value)" } }

    $assignments = Get-M365PScannerAppRoleAssignments -Context $Context
    $match = $assignments | Where-Object { $_.appRoleId -eq $appRole.id -and $_.resourceId -eq $spn.id } | Select-Object -First 1

    if ($match) { return @{ state = "granted"; detail = $null } }
    return @{ state = "missing"; detail = "$($Grant.value) on $($spn.displayName) is not assigned" }
}

function Set-M365PGrant_entraAppRole {
    Param($Grant, $Context)

    $spn = Get-M365PResourceSpn -Context $Context -ResourceKey $Grant.resource -CreateIfMissing
    if (!$spn) { Throw "M365PUNAVAILABLE: the $($Grant.resource) service principal could not be resolved or registered" }

    $appRole = $spn.appRoles | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1
    if (!$appRole) { Throw "M365PUNAVAILABLE: the API does not expose an app role named $($Grant.value)" }

    $null = Invoke-M365PRest -Context $Context -Method POST -Raw -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.scannerSpnObjectId)/appRoleAssignments" -Body @{
        principalId = $Context.scannerSpnObjectId
        resourceId  = $spn.id
        appRoleId   = $appRole.id
    }
    $null = Get-M365PScannerAppRoleAssignments -Context $Context -Refresh
}

function Remove-M365PGrant_entraAppRole {
    Param($Grant, $Context)

    $spn = Get-M365PResourceSpn -Context $Context -ResourceKey $Grant.resource
    if (!$spn) { return }
    $appRole = $spn.appRoles | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1
    if (!$appRole) { return }

    $assignments = Get-M365PScannerAppRoleAssignments -Context $Context
    foreach ($assignment in ($assignments | Where-Object { $_.appRoleId -eq $appRole.id -and $_.resourceId -eq $spn.id })) {
        $null = Invoke-M365PRest -Context $Context -Method DELETE -Raw -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.scannerSpnObjectId)/appRoleAssignments/$($assignment.id)"
    }
    $null = Get-M365PScannerAppRoleAssignments -Context $Context -Refresh
}

function Test-M365PGrant_entraDirectoryRole {
    Param($Grant, $Context)

    $memberOf = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.scannerSpnObjectId)/transitiveMemberOf") |
        Where-Object { $_.'@odata.type' -eq "#microsoft.graph.directoryRole" }

    if ($memberOf.roleTemplateId -contains $Grant.roleTemplateId) { return @{ state = "granted"; detail = $null } }
    return @{ state = "missing"; detail = "The $($Grant.displayName) role is not assigned" }
}

function Set-M365PGrant_entraDirectoryRole {
    Param($Grant, $Context)

    try {
        $null = Invoke-M365PRest -Context $Context -Method POST -Raw -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments" -Body @{
            "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
            roleDefinitionId = $Grant.roleTemplateId
            principalId      = $Context.scannerSpnObjectId
            directoryScopeId = "/"
        }
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        # the assignment already being there is success, not failure. Graph answers a duplicate with a
        # conflict whose reason is only in the response body, so the status line cannot be matched on
        $detail = Get-M365PErrorDetail -ErrorRecord $_
        if ($detail -notlike "*already exist*" -and $detail -notlike "*conflicting object*") { Throw $_ }
    }
}

function Remove-M365PGrant_entraDirectoryRole {
    Param($Grant, $Context)

    $assignments = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($Context.scannerSpnObjectId)'")
    foreach ($assignment in ($assignments | Where-Object { $_.roleDefinitionId -eq $Grant.roleTemplateId })) {
        $null = Invoke-M365PRest -Context $Context -Method DELETE -Raw -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments/$($assignment.id)"
        Write-M365PLog -Message "Removed the $($Grant.displayName) directory role, its replacement is verified"
    }
}

function Test-M365PGrant_entraGroup {
    Param($Grant, $Context)

    $group = Get-M365PGroup -Context $Context -GroupRef $Grant.groupRef
    if (!$group) { return @{ state = "missing"; detail = "Group $($Context.definition.groups.PSObject.Properties[$Grant.groupRef].Value) does not exist" } }

    # Only the scanner's own membership is testable: the VM has no idea who ran the onboarding script.
    # These go through Get-M365PDirectoryObjectIds because v1.0 omits service principals from owners and
    # members, and the scanner is one, so v1.0 would report every group as unowned with no error at all.
    if ($Grant.scannerIsOwner) {
        $owners = Get-M365PDirectoryObjectIds -Context $Context -CollectionUri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners"
        if ($owners -notcontains $Context.scannerSpnObjectId) { return @{ state = "missing"; detail = "The scanner is not an owner of $($group.displayName) ($($group.id))" } }
    }
    if ($Grant.scannerIsMember) {
        $members = Get-M365PDirectoryObjectIds -Context $Context -CollectionUri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members"
        if ($members -notcontains $Context.scannerSpnObjectId) { return @{ state = "missing"; detail = "The scanner is not a member of $($group.displayName) ($($group.id))" } }
    }

    return @{ state = "granted"; detail = $group.id }
}

function Set-M365PGrant_entraGroup {
    Param($Grant, $Context)

    $group = Get-M365PGroup -Context $Context -GroupRef $Grant.groupRef -CreateIfMissing
    if (!$group) { Throw "Could not create or resolve the group for $($Grant.key)" }

    if ($Grant.scannerIsOwner) { $null = Add-M365PDirectoryObjectRef -Context $Context -CollectionUri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners/`$ref" -ObjectId $Context.scannerSpnObjectId }
    if ($Grant.scannerIsMember) { $null = Add-M365PDirectoryObjectRef -Context $Context -CollectionUri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -ObjectId $Context.scannerSpnObjectId }

    if ($Context.runningUserId) {
        if ($Grant.runningUserIsOwner) { $null = Add-M365PDirectoryObjectRef -Context $Context -CollectionUri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners/`$ref" -ObjectId $Context.runningUserId }
        if ($Grant.runningUserIsMember) { $null = Add-M365PDirectoryObjectRef -Context $Context -CollectionUri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -ObjectId $Context.runningUserId }
    }
}

function Test-M365PGrant_entraDelegatedScope {
    <#
        .SYNOPSIS
        Checks that a delegated scope is declared on the single sign-on application.

        .DESCRIPTION
        Declaring it is the whole test for a user consentable scope. Tenant wide admin consent is nice
        to have, because it saves every user a consent prompt on first sign in, but it is not required:
        without it each user simply consents for themselves. Treating a missing consent grant as a
        missing permission would put the portal into a re-authorization loop over something that works.

        Whether a scope needs an administrator is not hardcoded here, it is read from the scope's own
        'type' as Entra reports it. So an admin only delegated scope added later is handled correctly
        without anyone having to remember this distinction.
    #>
    Param($Grant, $Context)

    if (!$Context.frontendAppObjectId -or !$Context.frontendSpnObjectId) {
        return @{ state = "unavailable"; detail = "The single sign-on application has not been created yet" }
    }

    $spn = Get-M365PResourceSpn -Context $Context -ResourceKey $Grant.resource
    if (!$spn) { return @{ state = "unavailable"; detail = "The $($Grant.resource) service principal is not present in this tenant" } }

    $scope = $spn.oauth2PermissionScopes | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1
    if (!$scope) { return @{ state = "unavailable"; detail = "The API does not expose a delegated scope named $($Grant.value)" } }

    $app = Invoke-M365PRest -Context $Context -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)"
    $declared = ($app.requiredResourceAccess | Where-Object { $_.resourceAppId -eq $spn.appId }).resourceAccess
    if ($declared.id -notcontains $scope.id) { return @{ state = "missing"; detail = "$($Grant.value) is not declared on the single sign-on application" } }

    $consents = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($Context.frontendSpnObjectId)'")
    $consent = $consents | Where-Object { $_.resourceId -eq $spn.id } | Select-Object -First 1
    $isConsented = ($consent -and ($consent.scope -split "\s+") -contains $Grant.value)

    if ($isConsented) { return @{ state = "granted"; detail = $null } }

    if ($scope.type -eq "User") {
        return @{ state = "granted"; detail = "Declared. No tenant wide consent, so each user consents at first sign in." }
    }

    return @{ state = "missing"; detail = "$($Grant.value) needs administrator consent and has not been consented" }
}

function Set-M365PGrant_entraDelegatedScope {
    Param($Grant, $Context)

    # converge the whole set in one go rather than one call per scope, so a run issues at most one PATCH
    $spn = Get-M365PResourceSpn -Context $Context -ResourceKey $Grant.resource -CreateIfMissing
    if (!$spn) { Throw "M365PUNAVAILABLE: the $($Grant.resource) service principal could not be resolved" }

    $siblings = $Context.definition.grants | Where-Object {
        $_.provider -eq "entraDelegatedScope" -and $_.resource -eq $Grant.resource -and $_.principal -eq $Grant.principal -and (Test-M365PCondition -Grant $_ -Context $Context)
    }

    $resourceAccess = @()
    $scopeNames = @()
    foreach ($sibling in $siblings) {
        $scope = $spn.oauth2PermissionScopes | Where-Object { $_.value -eq $sibling.value } | Select-Object -First 1
        if (!$scope) { continue }
        $resourceAccess += @{ id = $scope.id; type = "Scope" }
        $scopeNames += $sibling.value
    }
    if ($resourceAccess.Count -eq 0) { Throw "None of the requested delegated scopes exist on $($spn.displayName)" }

    $app = Invoke-M365PRest -Context $Context -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)"
    $required = @($app.requiredResourceAccess | Where-Object { $_.resourceAppId -ne $spn.appId })
    $required += @{ resourceAppId = $spn.appId; resourceAccess = $resourceAccess }

    $patch = @{ requiredResourceAccess = $required }
    if ($Context.frontendUrl) { $patch.publicClient = @{ redirectUris = @("$($Context.frontendUrl)/api/entra/response") } }
    $null = Invoke-M365PRest -Context $Context -Method PATCH -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)" -Body $patch

    # Tenant wide consent is a courtesy, not a requirement: these are user consentable scopes, so
    # without it each user simply consents for themselves at first sign in. Best effort on purpose,
    # since a tenant that restricts who may grant consent must not fail the whole onboarding run.
    $desiredScope = ($scopeNames | Sort-Object -Unique) -join " "
    try {
        $consents = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($Context.frontendSpnObjectId)'")
        $consent = $consents | Where-Object { $_.resourceId -eq $spn.id } | Select-Object -First 1

        if ($consent) {
            $null = Invoke-M365PRest -Context $Context -Method PATCH -Raw -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($consent.id)" -Body @{ scope = $desiredScope }
        }
        else {
            $null = Invoke-M365PRest -Context $Context -Method POST -Raw -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" -Body @{
                clientId    = $Context.frontendSpnObjectId
                consentType = "AllPrincipals"
                resourceId  = $spn.id
                scope       = $desiredScope
            }
        }
    }
    catch {
        Write-M365PLog -Level Warning -Message "Could not grant tenant wide consent for the portal sign-in scopes ($($_.Exception.Message)). This is not a problem: users will be asked to consent once each, at their first sign in."
    }
}

function Test-M365PGrant_entraAppRoleDefinition {
    Param($Grant, $Context)

    if (!$Context.frontendAppObjectId -or !$Context.frontendSpnObjectId) {
        return @{ state = "unavailable"; detail = "The single sign-on application has not been created yet" }
    }

    $app = Invoke-M365PRest -Context $Context -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)"
    $appRole = $app.appRoles | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1
    if (!$appRole -or !$appRole.isEnabled) { return @{ state = "missing"; detail = "The $($Grant.value) application role is not defined" } }

    $group = Get-M365PGroup -Context $Context -GroupRef $Grant.groupRef
    if (!$group) { return @{ state = "missing"; detail = "The group that should hold $($Grant.value) does not exist" } }

    # beta, for the same reason as the group reads and to match how setup.ps1 already reads this
    $assignments = @(Invoke-M365PRest -Context $Context -Uri "https://graph.microsoft.com/beta/servicePrincipals/$($Context.frontendSpnObjectId)/appRoleAssignedTo")
    $match = $assignments | Where-Object { $_.appRoleId -eq $appRole.id -and $_.principalId -eq $group.id } | Select-Object -First 1
    if (!$match) { return @{ state = "missing"; detail = "$($group.displayName) is not assigned to the $($Grant.value) role" } }

    return @{ state = "granted"; detail = $null }
}

function Set-M365PGrant_entraAppRoleDefinition {
    Param($Grant, $Context)

    $app = Invoke-M365PRest -Context $Context -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)"
    $appRole = $app.appRoles | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1

    if (!$appRole) {
        $appRole = @{
            allowedMemberTypes = @("User")
            description        = $Grant.description
            displayName        = $Grant.displayName
            id                 = [guid]::NewGuid().ToString()
            isEnabled          = $true
            value              = $Grant.value
        }
        $null = Invoke-M365PRest -Context $Context -Method PATCH -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)" -Body @{
            appRoles = @($app.appRoles) + @($appRole)
        }
        Write-M365PLog -Message "Defined the $($Grant.value) application role, waiting for it to replicate..."
        Start-Sleep -Seconds 20
        $app = Invoke-M365PRest -Context $Context -Raw -Uri "https://graph.microsoft.com/v1.0/applications/$($Context.frontendAppObjectId)"
        $appRole = $app.appRoles | Where-Object { $_.value -eq $Grant.value } | Select-Object -First 1
    }
    if (!$appRole) { Throw "The $($Grant.value) application role could not be created" }

    $group = Get-M365PGroup -Context $Context -GroupRef $Grant.groupRef -CreateIfMissing
    if (!$group) { Throw "The group that should hold $($Grant.value) could not be created" }

    try {
        $null = Invoke-M365PRest -Context $Context -Method POST -Raw -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.frontendSpnObjectId)/appRoleAssignments" -Body @{
            principalId = $group.id
            resourceId  = $Context.frontendSpnObjectId
            appRoleId   = $appRole.id
        }
    }
    catch {
        if ((Get-M365PErrorDetail -ErrorRecord $_) -notlike "*already exist*") { Throw $_ }
    }
}

function Find-M365PExoServicePrincipal {
    <#
        .SYNOPSIS
        The scanner's Exchange side service principal, or null.

        .DESCRIPTION
        Exchange mirrors these objects under its own identifiers and -Identity is documented against
        several of them, so a miss on the app id is not proof the identity is absent. Acting on that
        would report every Exchange grant missing in a tenant that has them, and on the apply path
        would try to register an identity that is already there. Exchange only holds the few identities
        that were explicitly registered with it, so listing them and matching the app id here settles
        it. The first lookup is kept because it is the cheap answer in the common case.
    #>
    Param($Context)

    $found = $null
    try {
        $found = @(Invoke-M365PExoCommand -Context $Context -Cmdlet "Get-ServicePrincipal" -Parameters @{ Identity = $Context.scannerAppId }) | Select-Object -First 1
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        $found = $null
    }
    if ($found) { return $found }

    try {
        $found = @(Invoke-M365PExoCommand -Context $Context -Cmdlet "Get-ServicePrincipal") |
            Where-Object { @($_.AppId, $_.ObjectId, $_.ServiceId) -contains $Context.scannerAppId } |
            Select-Object -First 1
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        $found = $null
    }

    return $found
}

function Get-M365PExoServicePrincipal {
    <#
        .SYNOPSIS
        Resolves (and optionally creates) the Exchange side service principal object for the scanner.
        Exchange keeps its own copy of the identity, which is what -App role assignments bind to.
    #>
    Param($Context, [Switch]$CreateIfMissing)

    # A miss is remembered as well as a hit. The definition carries an Exchange grant per role and each
    # one asks for this, so in a tenant where the scanner has not been registered in Exchange yet the
    # same failing lookup was repeated once per grant, and every one of them logs Exchange's rather
    # alarming looking ManagementObjectNotFoundException. CreateIfMissing still gets a real attempt,
    # since that is the path meant to change the answer.
    if ($Context.cache.exoSpn) { return $Context.cache.exoSpn }
    if ($Context.cache.exoSpnChecked -and !$CreateIfMissing) { return $null }

    $existing = Find-M365PExoServicePrincipal -Context $Context

    if (!$existing -and $CreateIfMissing) {
        Write-M365PLog -Message "Registering the scanner identity in Exchange Online..."
        try {
            $existing = @(Invoke-M365PExoCommand -Context $Context -Cmdlet "New-ServicePrincipal" -Parameters @{
                    AppId       = $Context.scannerAppId
                    ObjectId    = $Context.scannerSpnObjectId
                    DisplayName = if ($Context.scannerDisplayName) { $Context.scannerDisplayName } else { "M365Permissions" }
                }) | Select-Object -First 1
        }
        catch {
            if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
            # Registering is meant to be idempotent, and the two ways this call fails in practice both
            # tend to leave the object in place: Exchange objecting that the identity already exists,
            # and an answer that could not be read at all (its adminapi intermittently returns a body
            # that does not match the Content-Encoding it declares, which surfaces as a decompression
            # failure carrying no verdict whatsoever). Failing every Exchange grant on the strength of
            # that would be wrong, so read the state back instead of believing the exception.
            Write-M365PLog -Level Warning -Message "New-ServicePrincipal did not confirm, checking whether the identity is registered anyway: $($_.Exception.Message)"
            $existing = $null
        }

        Start-Sleep -Seconds 5
        if (!$existing) { $existing = Find-M365PExoServicePrincipal -Context $Context }
    }

    $Context.cache.exoSpn = $existing
    $Context.cache.exoSpnChecked = $true
    return $existing
}

function Get-M365PExoRoleAssignmentsForScanner {
    <#
        .SYNOPSIS
        The scanner's Exchange role assignments, read back the way Exchange actually supports.

        .DESCRIPTION
        New-ManagementRoleAssignment takes -App, but Get-ManagementRoleAssignment does not, and asking
        it for -App fails the entire cmdlet with "Parameter set cannot be resolved using the specified
        named parameters". Assignments made to a service principal are read back through -RoleAssignee
        instead, keyed on the Exchange side identity rather than the Entra application id.

        Callers still filter on Role themselves, so Role is only passed to the fallback: combining it
        with RoleAssignee is another parameter set to get wrong for no gain.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ExoSpn,
        [String]$Role
    )

    $identity = @($ExoSpn.Identity, $ExoSpn.ObjectId, $Context.scannerSpnObjectId) | Where-Object { $_ } | Select-Object -First 1

    try {
        return @(Invoke-M365PExoCommand -Context $Context -Cmdlet "Get-ManagementRoleAssignment" -Parameters @{ RoleAssignee = "$identity" })
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        if (!$Role) { Throw $_ }
        Write-M365PLog -Level Verbose -Message "Reading assignments for $identity failed ($($_.Exception.Message)), listing $Role and matching the assignee instead"
    }

    $names = @($ExoSpn.DisplayName, $ExoSpn.ServicePrincipalName, $identity, $Context.scannerAppId, $Context.scannerDisplayName) | Where-Object { $_ }
    return @(Invoke-M365PExoCommand -Context $Context -Cmdlet "Get-ManagementRoleAssignment" -Parameters @{ Role = $Role } |
        Where-Object { $names -contains $_.RoleAssigneeName -or $names -contains $_.RoleAssignee })
}

function Test-M365PScopeRestrictsTo {
    <#
        .SYNOPSIS
        Whether a management scope restricts to exactly one mailbox.
    #>
    Param($Scope, [String]$MailAddress)

    if (!$Scope -or [String]::IsNullOrWhiteSpace($MailAddress)) { return $false }
    if ($Scope.Exclusive -eq $true) { return $false }
    if ($Scope.ScopeRestrictionType -and "$($Scope.ScopeRestrictionType)" -ne "RecipientScope") { return $false }
    # Exchange rewrites RecipientRestrictionFilter into a normalised RecipientFilter, so match on the
    # address rather than on the expression that was sent
    return ("$($Scope.RecipientFilter)" -like "*$MailAddress*")
}

function Get-M365PExoManagementScopes {
    <#
        .SYNOPSIS
        Every management scope in the tenant, cached for the run.
    #>
    Param($Context, [Switch]$Refresh)

    if (!$Refresh -and $Context.cache.exoScopes) { return $Context.cache.exoScopes }

    $scopes = @()
    try { $scopes = @(Invoke-M365PExoCommand -Context $Context -Cmdlet "Get-ManagementScope" -Parameters @{}) } catch { $scopes = @() }
    $Context.cache.exoScopes = $scopes
    return $scopes
}

function Resolve-M365PExoManagementScope {
    <#
        .SYNOPSIS
        The name of a management scope restricted to one mailbox, reusing whatever the tenant already has.

        .DESCRIPTION
        Exchange refuses to create a scope whose RecipientRoot, RecipientFilter, ServerFilter,
        ScopeRestrictionType and Exclusive all match an existing one, whatever that one happens to be
        called, and answers with "Use the existing management scope instead of creating a new one". A
        tenant can therefore already hold exactly the scope needed under a name we would never guess,
        so match on what a scope does rather than on what it is called and adopt whatever is there.

        Returns the name to assign against, which is not necessarily the name in the definition.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][String]$Name,
        [Parameter(Mandatory = $true)][String]$MailAddress
    )

    $filter = "PrimarySmtpAddress -eq '$MailAddress'"
    $scopes = @(Get-M365PExoManagementScopes -Context $Context -Refresh)

    $ours = $scopes | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($ours) {
        if (Test-M365PScopeRestrictsTo -Scope $ours -MailAddress $MailAddress) { return $ours.Name }

        Write-M365PLog -Message "Repointing the $Name management scope at $MailAddress..."
        $null = Invoke-M365PExoCommand -Context $Context -Cmdlet "Set-ManagementScope" -Parameters @{
            Identity                   = $Name
            RecipientRestrictionFilter = $filter
        }
        $null = Get-M365PExoManagementScopes -Context $Context -Refresh
        return $Name
    }

    $equivalent = $scopes | Where-Object { Test-M365PScopeRestrictsTo -Scope $_ -MailAddress $MailAddress } | Select-Object -First 1
    if ($equivalent) {
        Write-M365PLog -Message "Reusing the existing management scope $($equivalent.Name), which already restricts to $MailAddress"
        return $equivalent.Name
    }

    Write-M365PLog -Message "Creating the $Name management scope for $MailAddress..."
    try {
        $null = Invoke-M365PExoCommand -Context $Context -Cmdlet "New-ManagementScope" -Parameters @{
            Name                       = $Name
            RecipientRestrictionFilter = $filter
        }
        Start-Sleep -Seconds 5
        $null = Get-M365PExoManagementScopes -Context $Context -Refresh
        return $Name
    }
    catch {
        # Exchange says an equivalent exists but not which one, and its idea of equivalent is broader
        # than a string comparison of the filter, so look again and adopt what it was objecting about
        if ($_.Exception.Message -notlike "*existing management scope*") { Throw $_ }
        $equivalent = @(Get-M365PExoManagementScopes -Context $Context -Refresh) |
            Where-Object { Test-M365PScopeRestrictsTo -Scope $_ -MailAddress $MailAddress } | Select-Object -First 1
        if (!$equivalent) { Throw $_ }
        Write-M365PLog -Message "Reusing the existing management scope $($equivalent.Name), which already restricts to $MailAddress"
        return $equivalent.Name
    }
}

function Test-M365PGrant_exoRoleAssignment {
    Param($Grant, $Context)

    $exoSpn = Get-M365PExoServicePrincipal -Context $Context
    if (!$exoSpn) { return @{ state = "missing"; detail = "The scanner identity is not registered in Exchange Online" } }

    $assignments = @(Get-M365PExoRoleAssignmentsForScanner -Context $Context -ExoSpn $exoSpn -Role $Grant.role)
    $match = $assignments | Where-Object { $_.Role -eq $Grant.role }

    if ($Grant.scope) {
        if (!$Context.mailAddress) { return @{ state = "missing"; detail = "No sender address has been determined" } }

        # the scope in use will not always carry the name from the definition: Exchange refuses to
        # create a duplicate of an equivalent scope, so an existing one gets adopted under its own name
        $acceptable = @(Get-M365PExoManagementScopes -Context $Context |
            Where-Object { Test-M365PScopeRestrictsTo -Scope $_ -MailAddress $Context.mailAddress } |
            ForEach-Object { $_.Name })

        if ($acceptable.Count -eq 0) { return @{ state = "missing"; detail = "No management scope restricts to $($Context.mailAddress)" } }

        $match = $match | Where-Object { $acceptable -contains $_.CustomResourceScope -or $acceptable -contains $_.CustomRecipientWriteScope }
        if (!$match) { return @{ state = "missing"; detail = "$($Grant.role) is not assigned within a scope restricted to $($Context.mailAddress)" } }
        return @{ state = "granted"; detail = "Scoped to $($Context.mailAddress)" }
    }

    if (!$match) { return @{ state = "missing"; detail = "$($Grant.role) is not assigned to the scanner" } }
    return @{ state = "granted"; detail = $null }
}

function Set-M365PGrant_exoRoleAssignment {
    Param($Grant, $Context)

    $exoSpn = Get-M365PExoServicePrincipal -Context $Context -CreateIfMissing
    if (!$exoSpn) { Throw "The scanner identity could not be registered in Exchange Online" }

    $parameters = @{ App = $Context.scannerAppId; Role = $Grant.role }

    if ($Grant.scope) {
        if (!$Context.mailAddress) { Throw "A scoped assignment needs a mail address on the context" }

        $scopeName = Resolve-M365PExoManagementScope -Context $Context -Name $Grant.scope.name -MailAddress $Context.mailAddress

        $parameters.CustomResourceScope = $scopeName
        # a stale assignment on the same role but the wrong scope would otherwise shadow the new one
        $existing = @(Get-M365PExoRoleAssignmentsForScanner -Context $Context -ExoSpn $exoSpn -Role $Grant.role) |
            Where-Object { $_.Role -eq $Grant.role -and $_.CustomResourceScope -ne $scopeName -and $_.CustomRecipientWriteScope -ne $scopeName }
        foreach ($stale in $existing) {
            Write-M365PLog -Level Warning -Message "Removing the differently scoped $($Grant.role) assignment $($stale.Name)"
            try { $null = Invoke-M365PExoCommand -Context $Context -Cmdlet "Remove-ManagementRoleAssignment" -Parameters @{ Identity = $stale.Name; Confirm = $false } } catch {}
        }
    }

    $null = Invoke-M365PExoCommand -Context $Context -Cmdlet "New-ManagementRoleAssignment" -Parameters $parameters
}

function Remove-M365PGrant_exoRoleAssignment {
    Param($Grant, $Context)

    $exoSpn = Get-M365PExoServicePrincipal -Context $Context
    if (!$exoSpn) { return }

    $assignments = @(Get-M365PExoRoleAssignmentsForScanner -Context $Context -ExoSpn $exoSpn -Role $Grant.role) | Where-Object { $_.Role -eq $Grant.role }
    foreach ($assignment in $assignments) {
        $null = Invoke-M365PExoCommand -Context $Context -Cmdlet "Remove-ManagementRoleAssignment" -Parameters @{ Identity = $assignment.Name; Confirm = $false }
        Write-M365PLog -Message "Removed the Exchange role assignment $($assignment.Name)"
    }
}

function Test-M365PGrant_exoMailbox {
    Param($Grant, $Context)

    if (!$Context.mailAddress) { return @{ state = "missing"; detail = "No sender address has been determined" } }

    $mailbox = $null
    try { $mailbox = @(Invoke-M365PExoCommand -Context $Context -Cmdlet "Get-Mailbox" -Parameters @{ Identity = $Context.mailAddress }) | Select-Object -First 1 } catch { $mailbox = $null }

    if (!$mailbox) { return @{ state = "missing"; detail = "$($Context.mailAddress) does not exist" } }

    # This grant is the dedicated mailbox the product creates for itself, which only exists in Auto
    # mode. In every other mail mode the address is one the customer already had, and the fact that it
    # exists says nothing about this grant: answering "granted" there tells the prune we created it and
    # are therefore free to delete it, which must not happen to a real mailbox.
    if ($Context.mailMode -ne "Auto") {
        return @{ state = "missing"; detail = "$($Context.mailAddress) is an existing mailbox rather than one created for reporting" }
    }

    return @{ state = "granted"; detail = "$($mailbox.RecipientTypeDetails) $($Context.mailAddress)" }
}

function Set-M365PGrant_exoMailbox {
    Param($Grant, $Context)

    if (!$Context.mailAddress) { Throw "No sender address has been determined" }

    Write-M365PLog -Message "Creating shared mailbox $($Context.mailAddress)..."
    $null = Invoke-M365PExoCommand -Context $Context -Cmdlet "New-Mailbox" -Parameters @{
        Shared             = $true
        Name               = "M365Permissions Reports"
        DisplayName        = "M365Permissions Reports"
        Alias              = ($Context.mailAddress -split "@")[0]
        PrimarySmtpAddress = $Context.mailAddress
    }
    Start-Sleep -Seconds 10
}

$Script:M365PUserAccessAdminRoleId = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"

function Get-M365PArmScopeUri {
    <#
        .SYNOPSIS
        Turns an ARM scope into the URI it hangs off. The root scope is the empty prefix, everything else
        is the scope itself.
    #>
    Param([Parameter(Mandatory = $true)][String]$Scope)

    if ($Scope -eq "/") { return "https://management.azure.com" }
    return "https://management.azure.com$Scope"
}

function Get-M365PAzureScopePreference {
    <#
        .SYNOPSIS
        The scopes to assign at, best first.

        .DESCRIPTION
        The root scope is what the manual instructions use and is the only place from which assignments
        made directly at the root are visible, which the tenant wide report needs. The root management
        group is the next best thing and still covers every current and future subscription. Individual
        subscriptions are the last resort and miss anything above them.
    #>
    Param($Context)

    return @("/", "/providers/Microsoft.Management/managementGroups/$($Context.tenantId)")
}

function Get-M365PRootElevationAssignment {
    <#
        .SYNOPSIS
        The User Access Administrator assignment at the root scope held by the account running this, if
        any. That assignment is what elevateAccess creates, and it is the only thing that makes a root
        management group role assignment possible for a Global Administrator.
    #>
    Param($Context)

    $assignments = @(Invoke-M365PRest -Context $Context -ResourceKey "arm" -Uri "https://management.azure.com/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$($Context.runningUserId)'")
    return $assignments |
        Where-Object { $_.properties.scope -eq "/" -and $_.properties.roleDefinitionId -like "*$($Script:M365PUserAccessAdminRoleId)" } |
        Select-Object -First 1
}

function Enable-M365PAzureElevation {
    <#
        .SYNOPSIS
        Grants the running Global Administrator access to Azure at the root scope, the manual equivalent
        of the elevateAccess button in the portal.

        .DESCRIPTION
        A Global Administrator has no Azure permissions at all until they elevate, so a tenant that has
        never done this cannot assign anything above the resource group the product was deployed to.
        Returns whether elevation is in place and whether we are the ones who put it there, because
        access that was already standing is not ours to hand back.
    #>
    Param($Context)

    if (!$Context.runningUserId) {
        Throw "M365PUNAVAILABLE: cannot elevate Azure access without knowing which account is running this"
    }

    try {
        if (Get-M365PRootElevationAssignment -Context $Context) {
            Write-M365PLog -Level Verbose -Message "Root scope access is already in place, leaving it alone"
            return @{ elevated = $true; revoke = $false }
        }
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        Write-M365PLog -Level Verbose -Message "Could not read root scope assignments before elevating: $($_.Exception.Message)"
    }

    Write-M365PLog -Message "Elevating your access to the Azure root scope, this is undone again at the end"

    $elevated = $false
    $lastError = $null
    # the api-version for this endpoint differs between the documentation and what tenants actually accept
    foreach ($apiVersion in @("2016-07-01", "2017-05-01")) {
        try {
            $null = Invoke-M365PRest -Context $Context -ResourceKey "arm" -Method POST -Raw -Body "{}" -Uri "https://management.azure.com/providers/Microsoft.Authorization/elevateAccess?api-version=$apiVersion"
            $elevated = $true
            break
        }
        catch {
            if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
            $lastError = $_.Exception.Message
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            # a refusal here means the account is not a Global Administrator, which no other api-version fixes
            if ($status -eq 403 -or $lastError -like "*AuthorizationFailed*" -or $lastError -like "*Forbidden*") {
                Throw "M365PUNAVAILABLE: elevating access to the Azure root scope needs a Global Administrator, and the account running this is not one. Either re-run this as a Global Administrator or assign the role by hand, see the documentation link."
            }
        }
    }

    if (!$elevated) { Throw "M365PUNAVAILABLE: could not elevate access to the Azure root scope: $lastError" }

    # the assignment is created asynchronously, so it is not usable the instant the call returns
    foreach ($attempt in 1..12) {
        Start-Sleep -Seconds 5
        try {
            if (Get-M365PRootElevationAssignment -Context $Context) {
                Write-M365PLog -Level Verbose -Message "Root scope access became readable after $($attempt * 5) seconds"
                return @{ elevated = $true; revoke = $true }
            }
        }
        catch {}
    }

    # elevation was accepted, so hand it back afterwards regardless of whether we could read it back
    Write-M365PLog -Level Warning -Message "Elevation was accepted but has not replicated yet, continuing anyway"
    return @{ elevated = $true; revoke = $true }
}

function Disable-M365PAzureElevation {
    <#
        .SYNOPSIS
        Hands back the root scope access that Enable-M365PAzureElevation took, so nobody is left standing
        with more Azure privilege than they started the run with.
    #>
    Param($Context)

    try {
        $assignment = Get-M365PRootElevationAssignment -Context $Context
        if (!$assignment) {
            Write-M365PLog -Level Verbose -Message "No root scope assignment left to remove"
            return
        }
        $null = Invoke-M365PRest -Context $Context -ResourceKey "arm" -Method DELETE -Raw -Uri "https://management.azure.com$($assignment.id)?api-version=2022-04-01"
        Write-M365PLog -Message "Handed your root scope access back again"
    }
    catch {
        Write-M365PLog -Level Warning -Message "Could not hand back your root scope access ($($_.Exception.Message)). Remove it by hand with: Remove-AzRoleAssignment -ObjectId $($Context.runningUserId) -Scope '/' -RoleDefinitionName 'User Access Administrator'"
    }
}

function Test-M365PGrant_azureRbac {
    Param($Grant, $Context)

    # Reading role assignments needs Azure permissions of its own, which a Global Administrator loses
    # again the moment the elevation this run took is handed back. Anything assigned during this run is
    # therefore answered from what the assignment call itself confirmed, not from a read that cannot work.
    if ($Context.cache.azureRbacAssigned -and $Context.cache.azureRbacAssigned.ContainsKey($Grant.key)) {
        return @{ state = "granted"; detail = $Context.cache.azureRbacAssigned[$Grant.key] }
    }

    $scopes = @(Get-M365PAzureScopePreference -Context $Context)
    try {
        $subscriptions = @(Invoke-M365PRest -Context $Context -ResourceKey "arm" -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01")
        foreach ($subscription in $subscriptions) { $scopes += "/subscriptions/$($subscription.subscriptionId)" }
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
    }

    $lastError = $null
    foreach ($scope in $scopes) {
        try {
            $assignments = @(Invoke-M365PRest -Context $Context -ResourceKey "arm" -Uri "$(Get-M365PArmScopeUri -Scope $scope)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$($Context.scannerSpnObjectId)'")
            $match = $assignments | Where-Object { $_.properties.roleDefinitionId -like "*$($Grant.roleDefinitionId)" } | Select-Object -First 1
            if ($match) { return @{ state = "granted"; detail = "$($Grant.displayName) at $scope" } }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    return @{ state = "missing"; detail = "The scanner has no $($Grant.displayName) assignment$(if($lastError){" (last error: $lastError)"})" }
}

function Set-M365PAzureRbacAssigned {
    <#
        .SYNOPSIS
        Records that this run made the assignment, which is the only evidence left once the elevation
        that made it possible has been handed back again.
    #>
    Param($Context, $Grant, [String]$Detail)

    if (!$Grant.key) { return }
    if (!$Context.cache.azureRbacAssigned) { $Context.cache.azureRbacAssigned = @{} }
    $Context.cache.azureRbacAssigned[$Grant.key] = $Detail
}

function Invoke-M365PAzureRbacAssignment {
    <#
        .SYNOPSIS
        One attempt at assigning the role, at the root scope first, the root management group next and
        per subscription last. Returns the number of scopes it landed on, so the caller can decide
        whether elevating is worth it.
    #>
    Param($Grant, $Context)

    $body = @{
        properties = @{
            roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$($Grant.roleDefinitionId)"
            principalId      = $Context.scannerSpnObjectId
            principalType    = "ServicePrincipal"
        }
    }

    foreach ($scope in (Get-M365PAzureScopePreference -Context $Context)) {
        $label = if ($scope -eq "/") { "the root scope" } else { "the root management group" }

        # nothing but the call itself belongs in here, so that bookkeeping afterwards can never be
        # mistaken for the assignment having failed
        $done = $false
        try {
            $null = Invoke-M365PRest -Context $Context -ResourceKey "arm" -Method PUT -Raw -Body $body -Uri "$(Get-M365PArmScopeUri -Scope $scope)/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())?api-version=2022-04-01"
            $done = $true
            Write-M365PLog -Message "Assigned $($Grant.displayName) at $label"
        }
        catch {
            if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
            $detail = Get-M365PErrorDetail -ErrorRecord $_
            if ($detail -like "*RoleAssignmentExists*") {
                $done = $true
                Write-M365PLog -Message "$($Grant.displayName) was already assigned at $label"
            }
            else {
                Write-M365PLog -Level Verbose -Message "Could not assign at $($label): $detail"
            }
        }

        if ($done) {
            Set-M365PAzureRbacAssigned -Context $Context -Grant $Grant -Detail "$($Grant.displayName) at $scope"
            return 1
        }
    }

    Write-M365PLog -Level Verbose -Message "Falling back to individual subscriptions"
    $subscriptions = @(Invoke-M365PRest -Context $Context -ResourceKey "arm" -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01")

    $assigned = 0
    foreach ($subscription in $subscriptions) {
        try {
            $null = Invoke-M365PRest -Context $Context -ResourceKey "arm" -Method PUT -Raw -Body $body -Uri "https://management.azure.com/subscriptions/$($subscription.subscriptionId)/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())?api-version=2022-04-01"
            $assigned++
        }
        catch {
            if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
            $detail = Get-M365PErrorDetail -ErrorRecord $_
            if ($detail -like "*RoleAssignmentExists*") { $assigned++; continue }
            Write-M365PLog -Level Verbose -Message "Could not assign $($Grant.displayName) on $($subscription.displayName): $detail"
        }
    }

    if ($assigned -gt 0) {
        Write-M365PLog -Message "Assigned $($Grant.displayName) on $assigned subscription(s), which does not cover assignments made above them"
        Set-M365PAzureRbacAssigned -Context $Context -Grant $Grant -Detail "$($Grant.displayName) on $assigned subscription(s)"
    }
    return $assigned
}

function Set-M365PGrant_azureRbac {
    Param($Grant, $Context)

    if ((Invoke-M365PAzureRbacAssignment -Grant $Grant -Context $Context) -gt 0) { return }

    # Nothing landed, which for a Global Administrator normally means they have never elevated: the role
    # gives them no Azure access at all until they do. Elevate, retry, and hand the access straight back,
    # so the run leaves the person who ran it exactly as privileged as it found them.
    Write-M365PLog -Level Verbose -Message "No scope accepted the assignment, trying again with elevated access"

    $elevation = $null
    try {
        $elevation = Enable-M365PAzureElevation -Context $Context

        if ((Invoke-M365PAzureRbacAssignment -Grant $Grant -Context $Context) -gt 0) { return }

        Throw "$($Grant.displayName) could not be assigned at the root management group or on any subscription, even with elevated access"
    }
    finally {
        if ($elevation -and $elevation.revoke) { Disable-M365PAzureElevation -Context $Context }
    }
}

function Invoke-M365PAzureRbacRemoval {
    <#
        .SYNOPSIS
        One pass at removing the role from every scope it is held at. Reports what it saw as well as what
        it managed to delete, so the caller can tell 'nothing to do' apart from 'not allowed to do it'.
    #>
    Param($Grant, $Context)

    $scopes = @(Get-M365PAzureScopePreference -Context $Context)
    try {
        foreach ($subscription in @(Invoke-M365PRest -Context $Context -ResourceKey "arm" -Uri "https://management.azure.com/subscriptions?api-version=2022-12-01")) {
            $scopes += "/subscriptions/$($subscription.subscriptionId)"
        }
    }
    catch {}

    $found = 0
    $removed = 0
    foreach ($scope in $scopes) {
        try {
            $assignments = @(Invoke-M365PRest -Context $Context -ResourceKey "arm" -Uri "$(Get-M365PArmScopeUri -Scope $scope)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$($Context.scannerSpnObjectId)'")
            foreach ($assignment in ($assignments | Where-Object { $_.properties.roleDefinitionId -like "*$($Grant.roleDefinitionId)" -and $_.properties.scope -eq $scope })) {
                $found++
                try {
                    $null = Invoke-M365PRest -Context $Context -ResourceKey "arm" -Method DELETE -Raw -Uri "https://management.azure.com$($assignment.id)?api-version=2022-04-01"
                    $removed++
                    Write-M365PLog -Message "Removed $($Grant.displayName) at $scope"
                }
                catch {
                    Write-M365PLog -Level Verbose -Message "Could not remove $($Grant.displayName) at $($scope): $($_.Exception.Message)"
                }
            }
        }
        catch {}
    }

    return @{ found = $found; removed = $removed }
}

function Remove-M365PGrant_azureRbac {
    Param($Grant, $Context)

    if ($Context.cache.azureRbacAssigned) { $Context.cache.azureRbacAssigned.Remove($Grant.key) }

    $result = Invoke-M365PAzureRbacRemoval -Grant $Grant -Context $Context
    if ($result.found -eq 0 -or $result.removed -eq $result.found) { return }

    # same story as assigning: without elevated access a Global Administrator cannot touch role
    # assignments above the deployment's own resource group, so unticking the surface would otherwise
    # leave the scanner's access quietly in place
    $elevation = $null
    try {
        $elevation = Enable-M365PAzureElevation -Context $Context
        $null = Invoke-M365PAzureRbacRemoval -Grant $Grant -Context $Context
    }
    catch {
        Write-M365PLog -Level Warning -Message "Could not remove $($Grant.displayName): $($_.Exception.Message)"
    }
    finally {
        if ($elevation -and $elevation.revoke) { Disable-M365PAzureElevation -Context $Context }
    }
}

function Test-M365PDevOpsOrgName {
    <#
        .SYNOPSIS
        Whether a string can be an Azure DevOps organization name.

        .DESCRIPTION
        Whatever comes back from the catalog goes straight into the path of every call below, so it
        gets checked here rather than at the far end where the failure is unrecognisable. Azure DevOps
        allows letters, digits and hyphens in a name, which a header cell, a url and an error body all
        fail, and those are exactly the three things the catalog has been seen to hand back.
    #>
    Param([String]$Name)

    if ([String]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9\-_\.]{0,62}$')
}

function Get-M365PDevOpsOrganizations {
    <#
        .SYNOPSIS
        The Azure DevOps organizations backed by this tenant.

        .DESCRIPTION
        The catalog endpoint answers in CSV rather than JSON, and its response carries a UTF-8 BOM.
        Reading it by splitting each line on commas and taking a fixed column went wrong twice over:
        the BOM sits in front of the header, so the anchored header test never matched and
        "Organization Name" was read as an organization, and a row whose id cell is empty shifts the
        url into the column the name was expected in. Both then went into the path of every membership
        probe, where a name with a space in it answers 404 and a url is rejected outright because a
        path may not contain a colon.

        Reading columns by name and refusing anything that cannot be an organization name keeps a
        surprise in the response from turning into a call. A tenant with no organizations answers with
        the header alone, which is now correctly read as none rather than as one.
    #>
    Param($Context)

    if ($Context.cache.devOpsOrgsChecked) { return $Context.cache.devOpsOrgs }

    $csv = Invoke-M365PRest -Context $Context -ResourceKey "devops" -NoPagination -Raw -Uri "https://vsaex.dev.azure.com/_apis/EnterpriseCatalog/Organizations?tenantId=$($Context.tenantId)&api-version=7.1-preview.1"

    $orgs = @()
    if ($csv -is [String]) {
        $lines = @($csv.TrimStart([Char]0xFEFF) -split "`r?`n" | Where-Object { ![String]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -gt 1) {
            $rows = @()
            try {
                $rows = @($lines | ConvertFrom-Csv)
            }
            catch {
                Write-M365PLog -Level Warning -Message "Could not read the Azure DevOps organization catalog: $($_.Exception.Message)"
            }

            foreach ($row in $rows) {
                $name = "$($row.'Organization Name')".Trim()
                if (!(Test-M365PDevOpsOrgName -Name $name)) {
                    # a row that carries the url and not the name still names the organization, in the
                    # last segment of a dev.azure.com url or the first label of a visualstudio.com one
                    $url = @($row.PSObject.Properties.Value | Where-Object { "$_" -match "^https?://" }) | Select-Object -First 1
                    $name = "$url".TrimEnd([Char]'/').Split([Char]'/')[-1].Split([Char]'.')[0].Trim()
                }

                if (Test-M365PDevOpsOrgName -Name $name) {
                    if ($orgs -notcontains $name) { $orgs += $name }
                }
                else {
                    Write-M365PLog -Level Warning -Message "Skipping a row in the Azure DevOps organization catalog that does not name an organization"
                }
            }
        }
    }

    $Context.cache.devOpsOrgs = $orgs
    $Context.cache.devOpsOrgsChecked = $true
    return $orgs
}

#A managed identity is a service principal, and Azure DevOps keeps those in their own entitlement
#collection rather than alongside users. Both are tried, newest first, so an organization that only
#answers on the older endpoint still works.
$script:M365PDevOpsEntitlementEndpoints = @(
    "serviceprincipalentitlements?api-version=7.1-preview.1",
    "userentitlements?api-version=7.1-preview.3"
)

function Get-M365PDevOpsEntitlementFailure {
    <#
        .SYNOPSIS
        Why an entitlement call did nothing, or $null when it worked.

        .DESCRIPTION
        vsaex answers 200 OK even when it refused: the verdict is isSuccess inside operationResult, so
        a successful HTTP call is not the same as an added member and has to be read out of the body.
        Posting a service principal body to the user endpoint fails exactly this way, silently.
    #>
    Param($Response)

    if (!$Response) { return "Azure DevOps returned an empty response" }

    $result = $Response.operationResult
    if (!$result) { return $null }
    # absent rather than false means this API version does not report it, which is not a failure
    if ($null -eq $result.isSuccess) { return $null }
    if ($result.isSuccess) { return $null }

    $messages = @(@($result.errors) | ForEach-Object { if ($_.value) { "$($_.value)" } elseif ($_.message) { "$($_.message)" } } | Where-Object { $_ })
    if ($messages.Count -gt 0) { return ($messages -join "; ") }
    if ($result.result) { return "Azure DevOps declined the entitlement: $($result.result)" }
    return "Azure DevOps declined the entitlement"
}

function Get-M365PDevOpsMembership {
    <#
        .SYNOPSIS
        Whether the scanner identity is present in one organization, and what was looked at.

        .DESCRIPTION
        Azure DevOps exposes an added service principal through more than one collection depending on
        the organization and the API version it answers on, and none of them is guaranteed to be
        present, so every candidate is tried and any hit counts. When nothing matches, what each probe
        actually returned is handed back: a bare "not a member" is indistinguishable from a lookup that
        was never able to see the identity in the first place, which is the more likely of the two.
    #>
    Param($Context, [String]$Organization)

    # the entitlement collections take a page size, the graph one only pages by continuation token,
    # which Invoke-M365PRest follows for us as long as it is not asked for the raw first page
    $probes = @(
        @{ label = "serviceprincipalentitlements"; uri = "https://vsaex.dev.azure.com/$Organization/_apis/serviceprincipalentitlements?api-version=7.1-preview.1&`$top=10000"; paginate = $false }
        @{ label = "graph/serviceprincipals"; uri = "https://vssps.dev.azure.com/$Organization/_apis/graph/serviceprincipals?api-version=7.1-preview.1"; paginate = $true }
        @{ label = "userentitlements"; uri = "https://vsaex.dev.azure.com/$Organization/_apis/userentitlements?api-version=7.1-preview.3&`$top=10000"; paginate = $false }
    )

    $notes = @()
    foreach ($probe in $probes) {
        try {
            if ($probe.paginate) {
                $items = @(Invoke-M365PRest -Context $Context -ResourceKey "devops" -Uri $probe.uri)
            }
            else {
                $response = Invoke-M365PRest -Context $Context -ResourceKey "devops" -NoPagination -Raw -Uri $probe.uri

                # every collection wraps its rows differently, and the identity sits under a different
                # property in each, so read all the shapes rather than betting on one
                $items = @()
                foreach ($property in @("members", "value", "items")) {
                    if ($response.PSObject.Properties.Name -contains $property) { $items += @($response.$property) }
                }
                if ($items.Count -eq 0 -and $response -is [Array]) { $items = @($response) }
            }

            foreach ($item in $items) {
                $originIds = @($item.servicePrincipal.originId, $item.user.originId, $item.originId) | Where-Object { $_ }
                if ($originIds -contains $Context.scannerSpnObjectId) { return @{ found = $true; notes = @() } }
            }
            $notes += "$($probe.label) returned $($items.Count) entries without $($Context.scannerSpnObjectId)"
        }
        catch {
            $notes += "$($probe.label): $(Get-M365PErrorDetail -ErrorRecord $_)"
        }
    }

    return @{ found = $false; notes = $notes }
}

function Test-M365PGrant_azureDevOpsOrgUser {
    Param($Grant, $Context)

    $orgs = Get-M365PDevOpsOrganizations -Context $Context
    if ($orgs.Count -eq 0) { return @{ state = "unavailable"; detail = "No Azure DevOps organizations are linked to this tenant" } }

    $present = @()
    $absent = @()
    $notes = @()
    foreach ($org in $orgs) {
        $membership = Get-M365PDevOpsMembership -Context $Context -Organization $org
        if ($membership.found) {
            $present += $org
        }
        else {
            $absent += $org
            foreach ($note in @($membership.notes)) { $notes += "$($org): $note" }
        }
    }

    if ($absent.Count -eq 0) { return @{ state = "granted"; detail = "Member of $($present -join ", ")" } }

    $detail = "Not a member of $($absent -join ", ")"
    if ($notes.Count -gt 0) { $detail = "$detail. $($notes -join " | ")" }
    return @{ state = "missing"; detail = $detail }
}

function Set-M365PGrant_azureDevOpsOrgUser {
    Param($Grant, $Context)

    $orgs = Get-M365PDevOpsOrganizations -Context $Context
    if ($orgs.Count -eq 0) { Throw "M365PUNAVAILABLE: no Azure DevOps organizations are linked to this tenant" }

    $added = 0
    $errors = @()
    foreach ($org in $orgs) {
        # stakeholder is the cheapest entitlement that can still read project membership
        $body = @{
            accessLevel          = @{ accountLicenseType = "stakeholder" }
            servicePrincipal     = @{ origin = "aad"; originId = $Context.scannerSpnObjectId; subjectKind = "servicePrincipal" }
            projectEntitlements  = @()
        }
        $accepted = $false
        $failures = @()
        foreach ($endpoint in $script:M365PDevOpsEntitlementEndpoints) {
            try {
                $response = Invoke-M365PRest -Context $Context -ResourceKey "devops" -Method POST -Raw -Body $body -Uri "https://vsaex.dev.azure.com/$org/_apis/$endpoint"
                $failure = Get-M365PDevOpsEntitlementFailure -Response $response
                if (!$failure -or $failure -like "*already*") { $accepted = $true; break }
                $failures += $failure
            }
            catch {
                $detail = Get-M365PErrorDetail -ErrorRecord $_
                if ($detail -like "*already*") { $accepted = $true; break }
                $failures += $detail
            }
        }

        if ($accepted) { $added++ } else { $errors += "$($org): $($failures -join " / ")" }
    }

    if ($added -eq 0) { Throw "Could not add the scanner to any organization. $($errors -join " | ")" }
    if ($errors.Count -gt 0) { Write-M365PLog -Level Warning -Message "Partially added to Azure DevOps: $($errors -join " | ")" }
}

function Remove-M365PGrant_azureDevOpsOrgUser {
    Param($Grant, $Context)

    foreach ($org in (Get-M365PDevOpsOrganizations -Context $Context)) {
        # whichever collection the entitlement lives in is the one it has to be deleted from, so the
        # endpoint that found it is the endpoint that removes it
        foreach ($endpoint in $script:M365PDevOpsEntitlementEndpoints) {
            $collection = ($endpoint -split "\?")[0]
            $apiVersion = ($endpoint -split "\?")[1]
            try {
                $entitlements = Invoke-M365PRest -Context $Context -ResourceKey "devops" -NoPagination -Raw -Uri "https://vsaex.dev.azure.com/$org/_apis/$($endpoint)&`$top=10000"
                $member = @($entitlements.members) | Where-Object {
                    @($_.servicePrincipal.originId, $_.user.originId) -contains $Context.scannerSpnObjectId
                } | Select-Object -First 1
                if (!$member) { continue }

                $null = Invoke-M365PRest -Context $Context -ResourceKey "devops" -Method DELETE -Raw -Uri "https://vsaex.dev.azure.com/$org/_apis/$collection/$($member.id)?$apiVersion"
                Write-M365PLog -Message "Removed the scanner from Azure DevOps organization $org"
                break
            }
            catch {
                Write-M365PLog -Level Warning -Message "Could not remove the scanner from $($org): $(Get-M365PErrorDetail -ErrorRecord $_)"
            }
        }
    }
}

function Get-M365PFabricTenantSetting {
    <#
        .SYNOPSIS
        Finds a Fabric tenant setting by its stable name, falling back to matching on its title.
    #>
    Param($Grant, $Context)

    $settings = @(Invoke-M365PRest -Context $Context -ResourceKey "fabric" -NoPagination -Raw -Uri "https://api.fabric.microsoft.com/v1/admin/tenantsettings")
    $all = @($settings.tenantSettings)

    $match = $all | Where-Object { $_.settingName -eq $Grant.settingName } | Select-Object -First 1
    if ($match) { return $match }

    # the setting is renamed from time to time, so fall back to matching on its title
    foreach ($needle in @($Grant.settingMatch)) {
        $match = $all | Where-Object { $_.title -and $_.title.ToLower().Contains($needle.ToLower()) } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

function Test-M365PGrant_fabricTenantSetting {
    Param($Grant, $Context)

    $setting = Get-M365PFabricTenantSetting -Grant $Grant -Context $Context
    if (!$setting) { return @{ state = "unavailable"; detail = "The tenant setting could not be found in this tenant" } }
    if (!$setting.enabled) { return @{ state = "missing"; detail = "'$($setting.title)' is switched off" } }

    if ($setting.canSpecifySecurityGroups) {
        $group = Get-M365PGroup -Context $Context -GroupRef $Grant.groupRef
        if (!$group) { return @{ state = "missing"; detail = "The service group does not exist yet" } }
        $enabled = @($setting.enabledSecurityGroups)
        if ($enabled.Count -gt 0 -and $enabled.graphId -notcontains $group.id) {
            return @{ state = "missing"; detail = "'$($setting.title)' is on, but not for $($group.displayName)" }
        }
    }

    return @{ state = "granted"; detail = $setting.title }
}

function Set-M365PGrant_fabricTenantSetting {
    <#
        .SYNOPSIS
        Switches a Fabric tenant setting on and delegates it to the service group.
    #>
    Param($Grant, $Context)

    $setting = Get-M365PFabricTenantSetting -Grant $Grant -Context $Context
    if (!$setting) { Throw "M365PUNAVAILABLE: the tenant setting could not be found in this tenant" }

    # carry the rest of the setting forward untouched, an update replaces the whole object
    $body = @{ enabled = $true }
    if ($null -ne $setting.PSObject.Properties["delegateToWorkspace"]) { $body.delegateToWorkspace = $setting.delegateToWorkspace }
    if (@($setting.excludedSecurityGroups).Count -gt 0) {
        $body.excludedSecurityGroups = @(foreach ($excluded in @($setting.excludedSecurityGroups)) { @{ graphId = $excluded.graphId; name = $excluded.name } })
    }

    if ($setting.canSpecifySecurityGroups) {
        $group = Get-M365PGroup -Context $Context -GroupRef $Grant.groupRef -CreateIfMissing
        if (!$group) { Throw "The service group could not be created" }
        # merge rather than overwrite: other groups may already be delegated this setting, and taking
        # somebody else's Power BI automation offline while onboarding ours would be a poor trade
        $groups = @()
        foreach ($existing in @($setting.enabledSecurityGroups)) { $groups += @{ graphId = $existing.graphId; name = $existing.name } }
        if ($groups.graphId -notcontains $group.id) { $groups += @{ graphId = $group.id; name = $group.displayName } }
        $body.enabledSecurityGroups = $groups
    }

    try {
        $null = Invoke-M365PRest -Context $Context -ResourceKey "fabric" -Method POST -Raw -Body $body -Uri "https://api.fabric.microsoft.com/v1/admin/tenantsettings/$($setting.settingName)/update"
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -in @(401, 403)) {
            Throw "M365PUNAVAILABLE: changing '$($setting.title)' needs a Fabric administrator, and the account running this is not one. Either re-run this as a Fabric administrator or set it by hand, see the documentation link."
        }
        Throw $_
    }

    # Fabric can take a while to act on a changed tenant setting even though it reads back immediately,
    Write-M365PLog -Message "Switched on '$($setting.title)'. Fabric can take up to 15 minutes to apply it."
}

function Test-M365PGrant_manualProbe {
    <#
        .SYNOPSIS
        Surfaces are that cannot be automated still get a state, by probing them as the scanner.
        From Cloud Shell there is no scanner token, so the honest answer there is 'unavailable'.
    #>
    Param($Grant, $Context)

    try {
        $null = Invoke-M365PRest -Context $Context -ResourceKey $Grant.probe.resource -Uri $Grant.probe.uri -NoPagination -Raw -MaxAttempts 2
        return @{ state = "granted"; detail = $null }
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") { Throw $_ }
        return @{ state = "missing"; detail = "Not authorized yet. This is a manual step, see the documentation link." }
    }
}

function Set-M365PGrant_manualProbe {
    Param($Grant, $Context)
    Throw "M365PUNAVAILABLE: $($Grant.key) is a documented manual step and cannot be granted by script"
}

#endregion providers

function Test-M365PGrant {
    Param(
        [Parameter(Mandatory = $true)]$Grant,
        [Parameter(Mandatory = $true)]$Context
    )

    $function = "Test-M365PGrant_$($Grant.provider)"
    if (!(Get-Command -Name $function -ErrorAction SilentlyContinue)) {
        return @{ state = "error"; detail = "No provider named $($Grant.provider)" }
    }

    try {
        return (& $function -Grant $Grant -Context $Context)
    }
    catch {
        if ($_.Exception.Message -like "M365PUNAVAILABLE*") {
            return @{ state = "unavailable"; detail = ($_.Exception.Message -replace "^M365PUNAVAILABLE:\s*", "") }
        }
        return @{ state = "error"; detail = $_.Exception.Message }
    }
}

function Test-M365PSatisfiedBy {
    <#
        .SYNOPSIS
        Whether a broader permission the tenant already holds covers a grant that tested as missing.
        Returns the explanation when one does, and $null when none do.

        .DESCRIPTION
        Narrowing a permission is a privilege reduction, but it lands on installs that are already
        running: 1.4.9 replaced Sites.ReadWrite.All with Sites.Read.All and tenant wide Mail.Send with a
        single scoped mailbox. The scanner still reads everything it did the day before, because what it
        holds is a superset of what is now asked for, so reporting those as missing takes SharePoint,
        OneDrive, Teams and Groups offline over permissions that demonstrably work.

        Audit only, and Invoke-M365PSync is what enforces that. In Apply mode the narrow permission has
        to actually be granted before the prune removes the wide one, and short circuiting here would
        leave the deployment holding neither.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Grant,
        [Parameter(Mandatory = $true)]$Context
    )

    foreach ($alternative in @($Grant.satisfiedBy)) {
        if (!$alternative) { continue }

        # the alternative is a patch over the grant rather than a grant of its own, so it only has to
        # name what differs. An explicit null clears a field, which is how the unscoped form of a
        # scoped role assignment is expressed.
        $probe = [PSCustomObject]@{}
        foreach ($property in $Grant.PSObject.Properties) {
            $probe | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
        }
        foreach ($property in $alternative.PSObject.Properties) {
            $probe | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
        }
        # satisfiedBy is not transitive: an alternative may not bring its own alternatives along
        $probe | Add-Member -MemberType NoteProperty -Name "satisfiedBy" -Value $null -Force

        $result = Test-M365PGrant -Grant $probe -Context $Context
        if ($result.state -ne "granted") { continue }

        # displayName last, which is the only name a directory role alternative has: it clears the
        # role of the assignment it stands in for, so without it the message names nothing at all
        $held = @($probe.value, $probe.role, $probe.displayName) | Where-Object { $_ } | Select-Object -First 1
        return "Covered by $held, which this tenant already holds and which includes everything this permission asks for. Re-authorize to move to the narrower permission."
    }

    return $null
}

function Set-M365PGrant {
    Param(
        [Parameter(Mandatory = $true)]$Grant,
        [Parameter(Mandatory = $true)]$Context
    )

    $function = "Set-M365PGrant_$($Grant.provider)"
    if (!(Get-Command -Name $function -ErrorAction SilentlyContinue)) { Throw "No provider named $($Grant.provider)" }
    & $function -Grant $Grant -Context $Context
}

function Remove-M365PGrant {
    Param(
        [Parameter(Mandatory = $true)]$Grant,
        [Parameter(Mandatory = $true)]$Context
    )

    $function = "Remove-M365PGrant_$($Grant.provider)"
    if (!(Get-Command -Name $function -ErrorAction SilentlyContinue)) {
        Write-M365PLog -Level Verbose -Message "Provider $($Grant.provider) has nothing to remove for $($Grant.key)"
        return
    }
    & $function -Grant $Grant -Context $Context
}

function Invoke-M365PPrune {
    <#
        .SYNOPSIS
        Removes app role assignments the definition does not ask for.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Resolved
    )

    $removed = @()
    $assignments = Get-M365PScannerAppRoleAssignments -Context $Context -Refresh
    if ($assignments.Count -eq 0) { return $removed }

    # map every resource the definition names, by service principal object id
    $knownResources = @{}
    foreach ($property in $Context.definition.resources.PSObject.Properties) {
        $spn = $null
        try { $spn = Get-M365PResourceSpn -Context $Context -ResourceKey $property.Name } catch { $spn = $null }
        if ($spn) { $knownResources[$spn.id] = @{ key = $property.Name; spn = $spn } }
    }

    $wanted = @{}
    foreach ($item in ($Resolved | Where-Object { $_.applicable -and $_.grant.provider -eq "entraAppRole" -and $_.grant.principal -eq "scanner" })) {
        $wanted["$($item.grant.resource)|$($item.grant.value)"] = $true
    }

    foreach ($assignment in $assignments) {
        $resource = $knownResources[$assignment.resourceId]
        if (!$resource) {
            Write-M365PLog -Level Verbose -Message "Leaving an assignment on $($assignment.resourceDisplayName) alone, that API is not managed by this definition"
            continue
        }
        $appRole = $resource.spn.appRoles | Where-Object { $_.id -eq $assignment.appRoleId } | Select-Object -First 1
        if (!$appRole) { continue }
        if ($wanted.ContainsKey("$($resource.key)|$($appRole.value)")) { continue }

        try {
            $null = Invoke-M365PRest -Context $Context -Method DELETE -Raw -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($Context.scannerSpnObjectId)/appRoleAssignments/$($assignment.id)"
            Write-M365PLog -Message "Removed the no longer needed permission $($appRole.value) on $($resource.spn.displayName)"
            $removed += "$($resource.key)/$($appRole.value)"
        }
        catch {
            Write-M365PLog -Level Warning -Message "Could not remove $($appRole.value) on $($resource.spn.displayName): $($_.Exception.Message)"
        }
    }

    if ($removed.Count -gt 0) { $null = Get-M365PScannerAppRoleAssignments -Context $Context -Refresh }
    return $removed
}

function Invoke-M365PSync {
    <#
        .SYNOPSIS
        Audits (and in Apply mode converges) every grant in the definition against the tenant.

        .DESCRIPTION
        Never throws for an individual grant. Returns one result object per grant
    #>
    Param(
        [Parameter(Mandatory = $true)]$Context,
        [ValidateSet("Audit", "Apply")][String]$Mode = "Audit",
        [Switch]$Prune,
        [Switch]$OnlyNodeScoped,
        $Definition
    )

    if (!$Definition) { $Definition = $Context.definition }
    $resolved = Resolve-M365PGrants -Definition $Definition -Context $Context

    if ($OnlyNodeScoped) {
        # scale-out nodes get their own managed identity, so they need everything the scanner needs to
        # read a tenant, but nothing that belongs to the deployment as a whole (the portal application,
        # the access groups, the one mailbox reports are sent from)
        $resolved = @($resolved | Where-Object {
                $_.grant.principal -eq "scanner" -and ($null -eq $_.grant.PSObject.Properties["nodeScoped"] -or $_.grant.nodeScoped)
            })
    }

    $results = @()

    foreach ($item in $resolved) {
        $grant = $item.grant
        $state = "error"
        $detail = $null

        if (!$item.applicable) {
            $state = "notApplicable"
            $detail = "Excluded by the selected options"
            if ($Mode -eq "Apply" -and $Prune) {
                # only bother removing it when it is actually there, so a no-op run stays a no-op
                $current = Test-M365PGrant -Grant $grant -Context $Context
                if ($current.state -eq "granted") {
                    Write-M365PLog -Message "$($grant.key) is no longer wanted, removing it..."
                    try { Remove-M365PGrant -Grant $grant -Context $Context; $detail = "Removed, no longer selected" }
                    catch { $detail = "Could not remove: $($_.Exception.Message)" }
                }
            }elseif ($Mode -eq "Audit") {
                # A surface being unselected says nothing about whether the permission is actually
                # there. Upgrades in particular start from a conservative surface list, so reporting
                # notApplicable without looking would take working categories offline and hide the
                # fact that the customer is already entitled to them. Report what is true, and let
                # the caller decide whether to widen the surfaces.
                $current = Test-M365PGrant -Grant $grant -Context $Context
                if ($current.state -eq "granted") {
                    $state = "granted"
                    $detail = "Granted, but the surface it belongs to is not selected"
                }
            }
        }else {
            $result = Test-M365PGrant -Grant $grant -Context $Context
            $state = $result.state
            $detail = $result.detail

            # Audit only. In Apply the narrow permission must actually be granted before the prune takes
            # the wide one away, so short circuiting here would leave the deployment holding neither.
            if ($state -eq "missing" -and $Mode -eq "Audit") {
                $covered = Test-M365PSatisfiedBy -Grant $grant -Context $Context
                if ($covered) {
                    $state = "satisfied"
                    $detail = $covered
                }
            }

            if ($state -eq "missing" -and $Mode -eq "Apply") {
                if ($grant.manual) {
                    $detail = "This is a manual step, see the documentation link"
                }
                else {
                    Write-M365PLog -Message "Granting $($grant.key)..."
                    try {
                        Set-M365PGrant -Grant $grant -Context $Context
                        $verify = Test-M365PGrant -Grant $grant -Context $Context
                        $state = $verify.state
                        $detail = $verify.detail
                        if ($state -eq "granted") { Write-M365PLog -Message "Granted $($grant.key)" }
                    }
                    catch {
                        if ($_.Exception.Message -like "M365PUNAVAILABLE*") {
                            $state = "unavailable"
                            $detail = ($_.Exception.Message -replace "^M365PUNAVAILABLE:\s*", "")
                        }
                        else {
                            $state = "error"
                            $detail = $_.Exception.Message
                        }
                        Write-M365PLog -Level Warning -Message "Could not grant $($grant.key): $detail"
                    }
                }
            }
        }

        $results += [PSCustomObject]@{
            key          = $grant.key
            principal    = $grant.principal
            provider     = $grant.provider
            necessity    = $grant.necessity
            displayName  = if ($grant.docs.title) { $grant.docs.title } else { $grant.key }
            why          = $grant.docs.why
            docsUrl      = $grant.docs.url
            categories   = @($grant.categories)
            capabilities = @($grant.capabilities)
            manual       = [Boolean]$grant.manual
            # Whether missing this grant stops its categories being scanned, as opposed to leaving
            # them with less detail. Necessity cannot express it: the Fabric tenant switch is
            # recommended and is the only way into Power BI, while the audit log reads are recommended
            # and merely enrich eight categories. Absent means blocking, so an older definition gates
            # exactly as it did before.
            blocking     = ($null -eq $grant.PSObject.Properties["blocksCategories"] -or [Boolean]$grant.blocksCategories)
            state        = $state
            detail       = $detail
            revision     = $Definition.revision
        }
    }

    if ($Mode -eq "Apply" -and $Prune) {
        # a replacement that verified means the mechanism it replaces can go
        foreach ($result in ($results | Where-Object { $_.state -eq "granted" })) {
            $grant = ($Definition.grants | Where-Object { $_.key -eq $result.key } | Select-Object -First 1)
            if (!$grant.replaces) { continue }
            $replaced = $Definition.grants | Where-Object { $_.key -eq $grant.replaces } | Select-Object -First 1
            if (!$replaced) { continue }
            $replacedResult = $results | Where-Object { $_.key -eq $replaced.key } | Select-Object -First 1
            if (!$replacedResult -or $replacedResult.state -ne "granted") { continue }
            # every replacement of this mechanism must be in place before it is safe to drop
            $allReplacements = @($Definition.grants | Where-Object { $_.replaces -eq $replaced.key })
            $allVerified = $true
            foreach ($candidate in $allReplacements) {
                $candidateResult = $results | Where-Object { $_.key -eq $candidate.key } | Select-Object -First 1
                if (!$candidateResult -or $candidateResult.state -ne "granted") { $allVerified = $false }
            }
            if (!$allVerified) { continue }

            Write-M365PLog -Message "$($replaced.key) is fully replaced, removing it..."
            try {
                Remove-M365PGrant -Grant $replaced -Context $Context
                $replacedResult.state = "notApplicable"
                $replacedResult.detail = "Replaced by $($grant.key)"
            }
            catch {
                Write-M365PLog -Level Warning -Message "Could not remove $($replaced.key): $($_.Exception.Message)"
            }
        }

        try {
            $null = Invoke-M365PPrune -Context $Context -Resolved $resolved
        }
        catch {
            Write-M365PLog -Level Warning -Message "Pruning was skipped: $($_.Exception.Message)"
        }
    }

    return $results
}

function Test-M365PRequiredGrantsPresent {
    <#
        .SYNOPSIS
        Returns $true when every grant marked 'required' is granted.

        .DESCRIPTION
        Recommended grants never gate at this level, they only gate their own categories.
    #>
    Param(
        [Parameter(Mandatory = $true)]$Results
    )

    $candidates = @($Results | Where-Object { $_.necessity -eq "required" })

    # 'satisfied' counts as present here: this gates whether the product can run, and a grant covered by
    # a broader permission the tenant already holds can run. That it should still be re-authorized onto
    # the narrower permission is reported separately, and is not a reason to refuse to work.
    $missing = @($candidates | Where-Object { $_.state -notin @("granted", "satisfied", "notApplicable") })
    if ($missing.Count -eq 0) { return $true }
    Write-M365PLog -Level Warning -Message "Missing required permissions: $(($missing.key) -join ", ")"
    return $false
}

function Write-M365PResultTable {
    Param([Parameter(Mandatory = $true)]$Results)

    Write-Host ""
    Write-Host "Permission state" -ForegroundColor Cyan
    Write-Host "----------------" -ForegroundColor Cyan
    foreach ($result in ($Results | Sort-Object necessity, key)) {
        $colour = switch ($result.state) {
            "granted"       { "Green" }
            "satisfied"     { "DarkGreen" }
            "notApplicable" { "DarkGray" }
            "unavailable"   { "DarkYellow" }
            default         { if ($result.necessity -eq "required") { "Red" } else { "DarkYellow" } }
        }
        $line = "{0,-13} {1,-12} {2}" -f $result.state, $result.necessity, $result.displayName
        Write-Host $line -ForegroundColor $colour
        if ($result.detail -and $result.state -notin @("granted", "notApplicable")) {
            Write-Host "              $($result.detail)" -ForegroundColor DarkGray
            if ($result.docsUrl) { Write-Host "              $($result.docsUrl)" -ForegroundColor DarkGray }
        }
    }
    Write-Host ""
}
