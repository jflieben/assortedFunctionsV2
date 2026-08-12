#Requires -Version 7.0
<#
.SYNOPSIS
    Onboards a tenant for M365Permissions Cloud. Idempotent, so re-running it is how you add or remove
    a surface later.

.DESCRIPTION
    Run this in Azure Cloud Shell. The portal composes the exact command for you, including the
    subscription, resource group and web app name of your deployment, so you should not need to type
    any of the parameters by hand.

    Why Cloud Shell rather than a consent link: the permissions this product needs reach past Entra
    into Exchange RBAC, Fabric tenant settings, Azure DevOps entitlements and Azure role assignments.
    A browser consent redirect can only consent one Entra resource at a time and cannot touch any of
    those. One Cloud Shell session can, using your own privileges, which is also why no vendor owned
    application holds standing write access in your tenant any more.

    Everything is applied through the shared permission definition at
    https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/permissions.json
    so this script has no permission list of its own to drift out of date.

    Nothing here hard fails. A surface that cannot be reached in your tenant is reported and skipped,
    the rest still gets applied.

.PARAMETER SubscriptionId
    The subscription your M365Permissions deployment lives in.

.PARAMETER ResourceGroup
    The resource group of the deployment. Naming it turns a sweep over every subscription you can see
    into a single lookup.

.PARAMETER FrontendName
    The name of the deployment's web app.

.PARAMETER ScannerAppId
    The application id of the scanner identity. Supply it to skip Azure discovery entirely, which lets
    an administrator with Entra privileges but no Azure access run this. The portal fills it in for you
    once the deployment is live.

.PARAMETER Surfaces
    Which systems to authorize scanning of, beyond the always included Entra, SharePoint and OneDrive.
    All, the default, selects every surface the definition knows about, including ones added after the
    command you are running was composed. This is the full desired state and not an addition:
    re-running without a surface removes its access again.

.PARAMETER MailMode
    None to disable scheduled report mails, Auto to create a dedicated shared mailbox to send them
    from, Existing to send from a mailbox you already have.

.PARAMETER Orchestration
    Enable this if your tenant has more than 3500 users. It lets the scanner spawn extra scan nodes,
    which needs a few write permissions it otherwise never asks for.

.PARAMETER MspOnboarding
    Cross tenant mode. Creates an application and certificate for the tenant instead of authorizing a
    deployed scanner, and prints what you need for the deployment wizard's MSP tab.

.PARAMETER Audit
    Report what is and is not in place, and change nothing.

.EXAMPLE
    & ([scriptblock]::Create((irm https://m365permissions.com/authorize.ps1))) -SubscriptionId 'x' -ResourceGroup 'y' -FrontendName 'z' -Surfaces Exchange,PowerBI -MailMode Auto

.NOTES
    Author: Jos Lieben
    Docs:   https://m365permissions.com/docs/onboarding
#>
[CmdletBinding()]
Param(
    [String]$SubscriptionId,
    [String]$ResourceGroup,
    [String]$FrontendName,
    [String]$ScannerAppId,
    [ValidateSet("All", "Exchange", "PowerBI", "PowerPlatform", "AzureDevOps", "Azure")]
    [String[]]$Surfaces = @("All"),
    [ValidateSet("None", "Auto", "Existing")]
    [String]$MailMode = "None",
    [String]$MailAddress,
    [Switch]$Orchestration,
    [Switch]$MspOnboarding,
    [Switch]$Audit,
    [String]$DefinitionUri = "https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/permissions.json",
    [String]$LibraryUri = "https://raw.githubusercontent.com/jflieben/assortedFunctionsV2/main/M365PermissionsCloud/permissions-lib.ps1",
    [String]$CertificatePath
)

$ErrorActionPreference = "Stop"

function Write-Step { Param([String]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Detail { Param([String]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Problem { Param([String]$Message) Write-Host "    $Message" -ForegroundColor DarkYellow }

function Wait-Close {
    <#
        .SYNOPSIS
        Blocks until the user actually presses a key, so the window never closes before its final
        message can be read. Read-Host is not used for the pause because a leftover newline in the
        input buffer (from pasting the command, or from an irm | iex style invocation) makes it
        return instantly without waiting. We drain any buffered input first, then wait for a real
        key press, and only fall back to Read-Host when there is no interactive console at all.
    #>
    Param([String]$Message = "Press any key to close this terminal...")
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
    try {
        if (-not [Console]::IsInputRedirected) {
            while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
            $null = [Console]::ReadKey($true)
            return
        }
    }catch {
        # no interactive console (e.g. some hosts) - fall through to a line read
    }
    $null = Read-Host
}

function Stop-WithReason {
    Param([String]$Reason)
    Write-Host ""
    Write-Host "Cannot continue: $Reason" -ForegroundColor Red
    Write-Host "If you are stuck, the documentation is at https://m365permissions.com/docs/onboarding" -ForegroundColor DarkGray
    Wait-Close
    Exit 1
}

function Get-TokenTenantId {
    <#
        .SYNOPSIS
        The tenant a token was issued for, from its tid claim, or $null when it cannot be read.
    #>
    Param([Parameter(Mandatory = $true)][String]$Token)

    try {
        $payload = $Token.Split(".")[1]
        switch ($payload.Length % 4) {
            1 { $payload = $payload.Substring(0, $payload.Length - 1) }
            2 { $payload += "==" }
            3 { $payload += "=" }
        }
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace("-", "+").Replace("_", "/")))
        return ($json | ConvertFrom-Json).tid
    }
    catch {
        return $null
    }
}

function Get-PlainAccessToken {
    <#
        .SYNOPSIS
        Normalises Get-AzAccessToken, whose return shape changed across Az versions, and returns $null
        rather than throwing when a resource cannot be served in this session.
    #>
    Param([Parameter(Mandatory = $true)][String]$Resource)

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
            $lastError = $_
        }
    }

    Write-Verbose "No token for $($Resource): $($lastError.Exception.Message)"
    return $null
}

# ------------------------------------------------------------------------------------------------
# 1. Session
# ------------------------------------------------------------------------------------------------

Write-Step "Checking your Azure session"

if (!(Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue)) {
    Stop-WithReason "The Az PowerShell module is not available. Azure Cloud Shell has it preinstalled, which is why we recommend running this there: https://shell.azure.com"
}

$context = Get-AzContext
if (!$context) {
    Stop-WithReason "You are not signed in. Run Connect-AzAccount first, or use Azure Cloud Shell where you already are."
}

if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
    try {
        $null = Set-AzContext -SubscriptionId $SubscriptionId -Force -ErrorAction Stop
        $context = Get-AzContext
    }    catch {
        # an Entra only administrator has no subscription access at all, which is fine when -ScannerAppId was given
        if (!$ScannerAppId -and !$MspOnboarding) {
            Stop-WithReason "Could not switch to subscription $SubscriptionId ($($_.Exception.Message)). If you do not have Azure access, ask for the command with -ScannerAppId in it, which needs no Azure access at all."
        }
        Write-Problem "No access to subscription $SubscriptionId, continuing without Azure discovery"
    }
}

$graphToken = Get-PlainAccessToken -Resource "https://graph.microsoft.com"
if (!$graphToken) { Stop-WithReason "Could not get a Microsoft Graph token for your account." }

# The tenant is taken from the token rather than from the Azure context, because it is the token that
# every API validates against and the two are not always the same. A session that was pointed at another
# tenant, or that switched subscription across a tenant boundary, can keep reporting one tenant while
# handing out tokens for another. Exchange is addressed per organization, /adminapi/beta/<tenant>/, so a
# mismatch there is not a warning, it is a 403 with an empty body on every Exchange permission while
# Graph carries on working normally. That combination is almost impossible to read from the outside.
$tokenTenantId = Get-TokenTenantId -Token $graphToken
$tenantId = if ($tokenTenantId) { $tokenTenantId } else { $context.Tenant.Id }

Write-Detail "Tenant:       $tenantId"
Write-Detail "Signed in as: $($context.Account.Id)"

if ($tokenTenantId -and $context.Tenant.Id -and $tokenTenantId -ne $context.Tenant.Id) {
    Write-Problem "Your session reports tenant $($context.Tenant.Id) but issues tokens for $tokenTenantId. Going with $tokenTenantId, which is the tenant these tokens can actually address. If that is not the tenant you meant to authorize, stop and run Connect-AzAccount -TenantId <the right one> first."
}

if ($context.Account.Type -and "$($context.Account.Type)" -ne "User") {
    Write-Problem "This session is signed in as $($context.Account.Type) ($($context.Account.Id)) rather than as an administrator. Onboarding applies permissions with your own privileges, so unless that identity holds them this will not do what you expect."
}
$graphHeaders = @{ "Authorization" = "Bearer $graphToken"; "Content-Type" = "application/json" }

# ------------------------------------------------------------------------------------------------
# 2. Shared engine and definition
# ------------------------------------------------------------------------------------------------

Write-Step "Loading the shared permission definition"

try {
    . ([scriptblock]::Create((Invoke-RestMethod -Uri $LibraryUri -ErrorAction Stop)))
}catch {
    Stop-WithReason "Could not load the permission engine from $($LibraryUri): $($_.Exception.Message)"
}

try {
    $definition = Get-M365PDefinition -Uri $DefinitionUri
}catch {
    Stop-WithReason "Could not load the permission definition from $($DefinitionUri): $($_.Exception.Message)"
}

Write-Detail "Definition revision $($definition.revision), $(@($definition.grants).Count) grants"

# All is expanded from the definition rather than from the ValidateSet, so a surface added to
# permissions.json is picked up by everyone already running with the default
if ($Surfaces -contains "All") {
    $Surfaces = @($definition.surfaces | ForEach-Object { $_.key })
    Write-Detail "Surfaces: All ($($Surfaces -join ', '))"
}else {
    Write-Detail "Surfaces: $($Surfaces -join ', ')"
}

# ------------------------------------------------------------------------------------------------
# 3. Find, or in MSP mode create, the principal being authorized
# ------------------------------------------------------------------------------------------------

$scannerSpn = $null
$frontendApp = $null
$frontendSpn = $null
$frontendUrl = $null
$mspOutput = $null

if ($MspOnboarding) {
    Write-Step "Cross tenant mode: creating the application this tenant will be scanned with"

    $backendName = "M365Permissions-CrossTenant-Backend"
    $backendApp = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$backendName'").value | Select-Object -First 1

    $isNewApp = $false
    if ($backendApp) {
        Write-Detail "Reusing the existing application $($backendApp.appId)"
    }else {
        $isNewApp = $true
        $backendApp = Invoke-RestMethod -Headers $graphHeaders -Method POST -Uri "https://graph.microsoft.com/v1.0/applications" -Body (@{ displayName = $backendName; signInAudience = "AzureADMyOrg" } | ConvertTo-Json)
        Write-Detail "Created application $($backendApp.appId)"
        Start-Sleep -Seconds 5
    }

    $scannerSpn = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($backendApp.appId)'").value | Select-Object -First 1
    if (!$scannerSpn) {
        $scannerSpn = Invoke-RestMethod -Headers $graphHeaders -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body (@{ appId = $backendApp.appId } | ConvertTo-Json)
        Start-Sleep -Seconds 5
    }
    Write-Detail "Service principal $($scannerSpn.id)"

    if ($isNewApp) {
        Write-Step "Generating the certificate this tenant will be scanned with"

        # written to a temporary folder rather than the working directory, and removed on the way out,
        # so a certificate never ends up committed alongside whatever you happened to be standing in
        $certificateFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "m365permissions-$([guid]::NewGuid())"
        $null = New-Item -Path $certificateFolder -ItemType Directory -Force
        if ($CertificatePath) { $certificateFolder = $CertificatePath }

        $pfxPath = Join-Path -Path $certificateFolder -ChildPath "$($backendApp.appId).pfx"
        $pfxPassword = ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString())) -replace '[/+=]', '').Substring(0, 24)

        $certificate = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            "CN=$($backendApp.appId)",
            [System.Security.Cryptography.RSA]::Create(2048),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        ).CreateSelfSigned([System.DateTimeOffset]::UtcNow.AddDays(-1), [System.DateTimeOffset]::UtcNow.AddYears(10))

        [System.IO.File]::WriteAllBytes($pfxPath, $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxPassword))
        Write-Detail "Thumbprint $($certificate.Thumbprint)"

        $publicCertificate = [System.Convert]::ToBase64String($certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        $null = Invoke-RestMethod -Headers $graphHeaders -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($backendApp.id)" -Body (@{
                keyCredentials = @(@{ type = "AsymmetricX509Cert"; usage = "Verify"; key = $publicCertificate; displayName = "M365Permissions Cross-Tenant Certificate" })
            } | ConvertTo-Json -Depth 5)
        Write-Detail "Certificate uploaded to the application"

        $mspOutput = @{ pfxPath = $pfxPath; pfxPassword = $pfxPassword; certificateFolder = $certificateFolder }
    }

    $feName = "M365Permissions-CrossTenant-Frontend"
}else {
    Write-Step "Finding your deployment"

    if ($ScannerAppId) {
        Write-Detail "Using the scanner application id you supplied, no Azure access needed"
        $scannerSpn = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ScannerAppId'").value | Select-Object -First 1
        if (!$scannerSpn) { Stop-WithReason "No service principal found for application id $ScannerAppId in this tenant." }
    }else {
        if (!$ResourceGroup) { Stop-WithReason "Either -ResourceGroup or -ScannerAppId is required. The portal puts one of them in the command for you." }

        $vm = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.Compute/virtualMachines" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "m365vm*" } | Select-Object -First 1
        if (!$vm) { Stop-WithReason "No M365Permissions scanner found in resource group '$ResourceGroup'. Check that the subscription and resource group in the command match your deployment." }

        $scannerSpn = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=displayName eq '$($vm.Name)'").value | Select-Object -First 1
        if (!$scannerSpn) { Stop-WithReason "Found the scanner VM $($vm.Name) but not its managed identity in Entra. Wait a minute for the deployment to finish and try again." }
        Write-Detail "Scanner: $($vm.Name)"
    }

    if (!$FrontendName -and $ResourceGroup) {
        $webApp = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.Web/sites" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "m365pf*" } | Select-Object -First 1
        if ($webApp) { $FrontendName = $webApp.Name }
    }
    if (!$FrontendName) { Stop-WithReason "The name of the deployment's web app is required. The portal puts it in the command for you." }

    $frontendUrl = "https://$($FrontendName).azurewebsites.net"
    $feName = "M365PermissionsPortal-$FrontendName (Single Sign-On)"
    Write-Detail "Portal:  $frontendUrl"
}

Write-Detail "Identity being authorized: $($scannerSpn.displayName) ($($scannerSpn.appId))"

# ------------------------------------------------------------------------------------------------
# 4. The single sign-on application
# ------------------------------------------------------------------------------------------------

if (!$Audit) {
    Write-Step "Setting up single sign-on for the portal"

    $frontendApp = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$feName'").value | Select-Object -First 1
    if ($frontendApp) {
        Write-Detail "Reusing the existing application $($frontendApp.appId)"
    }else {
        $frontendApp = Invoke-RestMethod -Headers $graphHeaders -Method POST -Uri "https://graph.microsoft.com/v1.0/applications" -Body (@{ displayName = $feName; signInAudience = "AzureADMyOrg" } | ConvertTo-Json)
        Write-Detail "Created application $($frontendApp.appId)"
        Start-Sleep -Seconds 5
    }

    $frontendSpn = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($frontendApp.appId)'").value | Select-Object -First 1
    if (!$frontendSpn) {
        $frontendSpn = Invoke-RestMethod -Headers $graphHeaders -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body (@{ appId = $frontendApp.appId } | ConvertTo-Json)
        Start-Sleep -Seconds 5
    }

    # only assigned users and groups may open the portal
    try {
        $null = Invoke-RestMethod -Headers $graphHeaders -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($frontendSpn.id)" -Body '{"appRoleAssignmentRequired": true}'
    }catch {
        Write-Problem "Could not require assignment on the portal application: $($_.Exception.Message)"
    }

    # the scanner owns both objects so it can keep the reply URL and role assignments in sync by itself,
    # which is what lets Application.ReadWrite.OwnedBy stay in place of the tenant wide equivalent
    $ownerBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($scannerSpn.id)" } | ConvertTo-Json
    foreach ($uri in @("https://graph.microsoft.com/v1.0/applications/$($frontendApp.id)/owners/`$ref", "https://graph.microsoft.com/v1.0/servicePrincipals/$($frontendSpn.id)/owners/`$ref")) {
        try { $null = Invoke-RestMethod -Headers $graphHeaders -Method POST -Uri $uri -Body $ownerBody } catch { }
    }
}else {
    $frontendApp = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$feName'").value | Select-Object -First 1
    if ($frontendApp) {
        $frontendSpn = @(Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($frontendApp.appId)'").value | Select-Object -First 1
    }
}

# ------------------------------------------------------------------------------------------------
# 5. Apply the definition
# ------------------------------------------------------------------------------------------------

Write-Step "Working out which tokens this session can provide"

$tokenProvider = { Param($audience) Get-PlainAccessToken -Resource $audience }

# report up front which surfaces are reachable, so nobody is surprised half way through a run
foreach ($surfaceKey in $Surfaces) {
    $resourceKey = switch ($surfaceKey) {
        "Exchange" { "exo" }
        "PowerBI" { "fabric" }
        "AzureDevOps" { "devops" }
        "Azure" { "arm" }
        "PowerPlatform" { $null }   # authorized by hand, see the documentation
        default { $null }
    }
    if (!$resourceKey) { continue }
    $audiences = @($definition.resources.PSObject.Properties[$resourceKey].Value.tokenResources)
    $reachable = $false
    foreach ($audience in $audiences) { if (Get-PlainAccessToken -Resource $audience) { $reachable = $true; break } }
    if ($reachable) { Write-Detail "$surfaceKey is reachable from this session" } else { Write-Problem "$surfaceKey cannot be reached from this session, its permissions will be reported as unavailable and skipped" }
}

$me = $null
try { $me = Invoke-RestMethod -Headers $graphHeaders -Method GET -Uri "https://graph.microsoft.com/v1.0/me" } catch { }
if (!$me) { Write-Problem "Could not work out who you are, so you will have to add yourself to SEC-APP-M365Permissions-Admins by hand" }

$engineContext = New-M365PContext -TokenProvider $tokenProvider `
    -Definition $definition `
    -TenantId $tenantId `
    -ScannerAppId $scannerSpn.appId `
    -ScannerSpnObjectId $scannerSpn.id `
    -ScannerDisplayName $scannerSpn.displayName `
    -FrontendAppId $frontendApp.appId `
    -FrontendAppObjectId $frontendApp.id `
    -FrontendSpnObjectId $frontendSpn.id `
    -FrontendUrl $frontendUrl `
    -Surfaces $Surfaces `
    -Orchestration ([Boolean]$Orchestration) `
    -AuthMode $(if ($MspOnboarding) { "ServicePrincipal" } else { "ManagedIdentity" }) `
    -MailMode $MailMode `
    -MailAddress $MailAddress `
    -RunningUserId $me.id `
    -MspOnboarding ([Boolean]$MspOnboarding) `
    -SubscriptionId $SubscriptionId

if ($Audit) {
    Write-Step "Auditing (nothing will be changed)"
    $results = Invoke-M365PSync -Context $engineContext -Mode Audit
}else {
    Write-Step "Applying permissions"
    # pruning is what makes re-running with a surface unticked actually remove that surface's access.
    # MSP onboarding never prunes: the tenant may be scanned by more than one thing.
    $results = Invoke-M365PSync -Context $engineContext -Mode Apply -Prune:(!$MspOnboarding)
}

Write-M365PResultTable -Results $results

# ------------------------------------------------------------------------------------------------
# 6. Outcome
# ------------------------------------------------------------------------------------------------

$requiredPresent = Test-M365PRequiredGrantsPresent -Results $results
$unavailable = @($results | Where-Object { $_.state -eq "unavailable" })
$manual = @($results | Where-Object { $_.manual -and $_.state -ne "granted" -and $_.state -ne "notApplicable" })

if ($manual.Count -gt 0) {
    Write-Host "These need a manual step, they cannot be done from here:" -ForegroundColor Yellow
    foreach ($item in $manual) {
        Write-Host "  $($item.displayName)" -ForegroundColor Yellow
        Write-Host "    Your application id is $($scannerSpn.appId)" -ForegroundColor DarkGray
        Write-Host "    $($item.docsUrl)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($unavailable.Count -gt 0) {
    Write-Host "These could not be determined from this session and were skipped:" -ForegroundColor DarkYellow
    foreach ($item in $unavailable) { Write-Host "  $($item.displayName): $($item.detail)" -ForegroundColor DarkGray }
    Write-Host ""
}

if ($MspOnboarding) {
    Write-Host "Cross tenant onboarding complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "In the M365Permissions deployment wizard, on the MSP / Cross-Tenant tab:" -ForegroundColor Cyan
    Write-Host "  Tenant ID          : $tenantId"
    Write-Host "  Backend Client ID  : $($scannerSpn.appId)"
    Write-Host "  Frontend Client ID : $($frontendApp.appId)"
    if ($mspOutput) {
        Write-Host "  Certificate        : $($mspOutput.pfxPath)"
        Write-Host "  Certificate secret : $($mspOutput.pfxPassword)"
        Write-Host ""
        Write-Host "Download the certificate now, this folder is temporary:" -ForegroundColor Yellow
        Write-Host "  download $($mspOutput.pfxPath)" -ForegroundColor Yellow
        Write-Host "Then remove it with: Remove-Item -Recurse -Force '$($mspOutput.certificateFolder)'" -ForegroundColor DarkGray
    }else {
        Write-Host ""
        Write-Host "The application already existed, so no new certificate was generated." -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "https://m365permissions.com/docs/msp-cross-tenant" -ForegroundColor DarkGray
    Wait-Close
    Exit 0
}

if (!$requiredPresent) {
    Write-Host "Some required permissions are still missing, see the table above." -ForegroundColor Red
    Write-Host "Re-running this command is safe and is usually all that is needed, since permissions sometimes take a moment to replicate." -ForegroundColor DarkGray
    Wait-Close
    Exit 1
}

Write-Host "Done. Every required permission is in place." -ForegroundColor Green
Write-Host ""
Write-Host "Now go back to the portal and press the confirmation button." -ForegroundColor Cyan
Write-Host "  $frontendUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "That button is not a formality: the scanner has no other way to find out that it has been" -ForegroundColor DarkGray
Write-Host "authorized, so it will keep waiting until you press it." -ForegroundColor DarkGray
Write-Host ""
Wait-Close
Exit 0
