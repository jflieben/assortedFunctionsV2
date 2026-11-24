<#
.SYNOPSIS
Finishes the setup of an M365Permissions instance: read permissions for its scan identity and the sign-in app.

.DESCRIPTION
Run once by a Global Administrator in PowerShell 7 on their own computer (Azure Cloud Shell cannot do the Exchange and
Power Platform steps). Marketplace: the command the instance's start page shows, with -ManagedApplicationId; the script
reads the deployment's values (identities, setup code, network, alert mailbox) from the managed application with your
Azure sign-in, raising a Global Administrator's Azure access for that read when needed (not with -NoElevate or -Audit),
and ends with the instance's short link (m365permissions.com/name), which it asks JSolve for. Other deployments: the
command from their outputs. When your computer cannot reach the instance (private network), download this script from
it and run it from its folder. Besides that last question (and, for an older command without -TenantId, the instance's
public sign-in address) it talks only to Microsoft, never to the instance.
Safe to run again: everything that exists already is kept, missing parts are added (re-authorization after an update).

1. Grants the scan identity (the instance's managed identity) read permissions: Microsoft Graph and SharePoint
   application roles, Exchange.ManageAsApp, the Global Reader directory role. The Graph list includes read permissions
   for features to come, so they need no new consent. One write right: Application.ReadWrite.OwnedBy, limited to the
   app registrations the scan identity owns (the instance's sign-in app and AI clients app, step 6), so the instance
   keeps their addresses up to date itself.
2. Gives the scan identity Reader on Azure (tenant root management group, else each subscription you can manage). A
   Global Administrator without Azure access gets it for this step only (Entra "Access management for Azure
   resources"); the script sets it back afterwards. -NoElevate leaves your access alone.
3. Puts the scan identity in the security group "M365Permissions scanners" and switches on the Fabric tenant setting
   "Service principals can use read-only admin APIs" for that group (needs a Fabric administrator; a Global
   Administrator is one). Groups the setting was already on for stay on.
4. Peering with the customer's network (-PeerVirtualNetworkId, any subscription of the tenant): gives the scan identity
   Network Contributor on that virtual network only, so the instance peers with it and then, without allowed IP ranges,
   closes itself to the internet. The customer's own privatelink.azurewebsites.net zone (-PrivateDnsZoneId, for peering or
   their own private endpoint): Private DNS Zone Contributor on that zone only, so the instance keeps its web app's two A
   records there.
5. Registers the scan identity as a Power Platform management app.
6. Creates the single-tenant sign-in app (first run, with -SetupCode): roles Admin, Reader, Auditor, Self, Reviewer and Staff
   (sign-in only, for MSP staff who serve customer tenants), the groups assigned to the app in its tokens,
   a federated credential for the web app's identity (no secret), consent for sign-in, and Admin for you. A later run
   adds roles of a newer version (Reviewer, Staff) and the groups setting, and brings the descriptions up to date; the ids and values of existing roles stay. The app carries
   a tag derived from the setup code; the instance finds it there and configures its sign-in within a few minutes.
   Every run makes the scan identity an owner of the sign-in app (and of the AI clients app when it exists). A
   deployment of your own (the command from its outputs) also gives the web identity Website Contributor on the
   instance's resource group, which App Service managed certificates for a custom domain need, when you may assign it.
   It comes after the steps above, so nobody signs in before they are done.
7. Mail alerts (-AlertSenderMailbox): lets the scan identity send as that mailbox and no other (Exchange application
   RBAC: the service principal, a management scope of its own for the mailbox's primary address, Application Mail.Send
   in that scope). What exists is checked and corrected: a service principal that points at another object, a scope for
   another address, an assignment in another scope. Exchange's own test (Test-ServicePrincipalAuthorization) confirms it;
   Exchange applies changes within 2 hours. With no mailbox, or one that does not exist yet, a run in a console asks at
   the end (before the version 1 clean-up) whether to create a shared mailbox, and its name (default M365Permissions).
8. Adds the scan identity to every Azure DevOps organization of the tenant as a Stakeholder, and to the Readers group
   of each project (needs a Project Collection Administrator of each organization). An organization this account is not
   an administrator of (often one a user made for themselves) names its owner and the command they run as themselves,
   with -DevOpsOrganization, which needs no Entra role; one whose owner is no longer active an Azure DevOps
   Administrator can claim first (https://dev.azure.com/<organization>, Claim Ownership).
9. Makes the scan identity an application user of each Dataverse environment with a role that only reads: the organization settings (the guest access setting), security roles, users,
   teams and business units (who holds which role), and Copilot Studio agents with their knowledge, actions and
   connection references where the environment has them. A role from an earlier run gets what it misses. Microsoft does not make
   Global and Power Platform Administrators System Administrator of an environment: where you are not one, the script
   makes you one for this step (one more browser sign-in, shown as Power Platform CLI, for all environments), waits, and
   removes the role afterwards. Where that does not work it asks you to use Membership, Add me (S skips the
   environment); -NoElevate does neither. Dataverse for Teams environments are skipped: they take no reader role. Optional: where it is missing, guest access counts as allowed and
   the environment's security roles are not read.
10. Prints what this account could not do. Problems in the Azure DevOps and Dataverse steps are listed but stop nothing
   and do not hold back the version 1 clean-up.

Use -Audit to only report what is missing.

Version 1: at the end of a full run without problems, in a console, the script looks for version 1 of M365Permissions in
this tenant (its managed application, sign-in app and groups) and offers to delete what it can tie to a version 1
managed application, after one y/n question (default No). -Audit only lists it; -KeepVersion1 skips it.

AI assistants (-EnableMcp with a full run, or -Only Mcp alone, also with -ManagedApplicationId): adds the delegated scope
MCP.Read and the identifier URI https://<instance>/mcp to the sign-in app, pre-authorises Visual Studio Code, and creates
the public client app "M365Permissions AI clients" (no secret; redirects for Claude Code on port 41730 and Claude) with
admin consent. Settings, AI assistants in M365Permissions shows the command and switches access on.
The app is single-tenant; on an instance with customer tenants M365Permissions makes it multi-tenant itself once the
custom domain is secured, and each customer tenant consents to it with a link (Settings, Tenants).

Custom domain: once the scan identity owns the sign-in app and holds Application.ReadWrite.OwnedBy (any full run adds
both), the instance adds and removes the custom domain's sign-in addresses itself. Without them, the fallback is
-Only CustomDomain, and CustomDomainMcp for AI assistants, with -CustomDomain <host> (Settings, Access in M365Permissions
shows the command): adds the redirect URIs https://<host>/signin-oidc and /signout-callback-oidc to the sign-in app, and
with CustomDomainMcp the identifier URI https://<host>/mcp and the AI client app's redirect there. -RemoveCustomDomain
takes them off again once the domain is removed.

-ScanAppId with -Only fixes what a scan could not read (the GUI's "How to fix" fills it in): only the named grants of the
scan identity, nothing else. Values: Graph:<permission>, SharePoint:Sites.FullControl.All, Exchange:Exchange.ManageAsApp,
GlobalReader, AzureReader, PowerBiGroup, PowerBiSetting, PowerPlatformApp, DataverseUser, AzureDevOps, Network (with
-PeerVirtualNetworkId), DnsZone (with -PrivateDnsZoneId), MailSender (with -AlertSenderMailbox), CustomDomain and CustomDomainMcp (with -CustomDomain), or ScanIdentity for all the
scan identity's grants.

Every step calls the services' REST APIs directly (Graph, Azure, Power BI, Power Platform, Azure DevOps) with your
Azure sign-in; only the mail alert step uses a module, ExchangeOnlineManagement, because Exchange takes no Azure token.

Signs in with Azure PowerShell (Az) when it has a session, else with the Azure CLI's account (az login); with
neither, it installs Az.Accounts for you and signs in with it. -AzureCli uses the Azure CLI. Every command the instance
shows names its tenant (-TenantId, an id or a domain) and, where a step works in Azure, the subscription (-SubscriptionId;
-ManagedApplicationId holds it). The script first makes sure the session is in that tenant: a context the account
already has there, else the module's own sign-in to it (Connect-AzAccount -Tenant, az login --tenant
--allow-no-subscriptions), and it stops when the session still is in another tenant. Every token it gets is checked for
that tenant too. A tenant without any Azure subscription works: the Azure steps then say so. An older command without
-TenantId: the tenant of a subscription it names, else the tenant the instance's own sign-in names, else the script asks
once whether the session's tenant is the right one (without a console it stops and asks for -TenantId).
A service that asks for a fresh sign-in (multi-factor authentication, Conditional Access) gets one browser sign-in per
run; for the optional services (Azure DevOps, Power Platform, Dataverse, Fabric) that sign-in has a time limit, and a
refusal, no access or a time-out skips the step with the reason and the command for that step alone. Exchange takes no
Azure sign-in: the mail alert step uses Connect-ExchangeOnline (installed when missing) for the tenant, once per run,
which reuses your sign-in or asks once in the browser; an open Exchange connection to the tenant is reused. No device
codes.

Hosted instances (JSolve runs them, -ScanAppId and -SignInAppId from JSolve) and customer tenants of an MSP instance
(the command its Settings, Tenants shows, also as a download for the customer): the scan identity is the enterprise app
of the instance's scan app in this tenant and the sign-in app lives in the instance's own tenant (JSolve's, or the
MSP's); the script creates both enterprise apps when admin consent did not (the sign-in app's with assignment
required, also on one consent made), then does the same steps. It first checks that -ScanAppId and -SignInAppId are apps
the instance at -WebUrl names (the script it serves names them), and grants nothing otherwise; so does -Only with
-ScanAppId. Run by an account of another tenant (an MSP's delegated GDAP admin, or a guest), it
gives that account no role here, raises no access for it, connects to Exchange with -DelegatedOrganization and says at
each step Microsoft may refuse such an account (Azure, Fabric, Power Platform, Dataverse, Azure DevOps, mail) how an
account of this tenant runs that step alone.
#>
[CmdletBinding(DefaultParameterSetName = 'Marketplace')]
param(
    # Marketplace: everything else comes from the managed application's outputs, read with your Azure sign-in.
    [Parameter(Mandatory, ParameterSetName = 'ManagedApplication')]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Solutions/applications/[^/]+$')][string]$ManagedApplicationId,
    [Parameter(Mandatory, ParameterSetName = 'Marketplace')][Parameter(Mandatory, ParameterSetName = 'Hosted')][Parameter(Mandatory, ParameterSetName = 'Fix')][string]$WebUrl,
    [Parameter(Mandatory, ParameterSetName = 'Marketplace')][string]$ScanIdentityPrincipalId,
    [Parameter(Mandatory, ParameterSetName = 'Marketplace')][string]$WebIdentityPrincipalId,
    [Parameter(ParameterSetName = 'Marketplace')][string]$SetupCode,
    # The customer's virtual network the instance peers with (any subscription of the tenant).
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$')][string]$PeerVirtualNetworkId,
    # The customer's own privatelink.azurewebsites.net zone the instance keeps its records in (any subscription of the tenant).
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/privateDnsZones/privatelink\.azurewebsites\.net$')][string]$PrivateDnsZoneId,
    # The mailbox alert mails are sent from: the scan identity may send as it, and as no other mailbox.
    [ValidatePattern('^[^\s@'']+@[^\s@'']+\.[^\s@'']+$')][string]$AlertSenderMailbox,
    [Parameter(Mandatory, ParameterSetName = 'Hosted')][Parameter(Mandatory, ParameterSetName = 'Fix')][string]$ScanAppId,
    # Hosted: JSolve's sign-in app. With -Only Mcp also for the AI assistant step of a hosted instance.
    [Parameter(Mandatory, ParameterSetName = 'Hosted')][Parameter(ParameterSetName = 'Fix')][string]$SignInAppId,
    [Parameter(ParameterSetName = 'ManagedApplication')][Parameter(Mandatory, ParameterSetName = 'Fix')][string[]]$Only,
    # Also registers AI assistants with Entra ID (the step -Only Mcp runs alone).
    [switch]$EnableMcp,
    # -Only CustomDomain, CustomDomainMcp: the web app's custom domain (a host name below a domain of yours).
    [ValidatePattern('^(?=.{4,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$')][string]$CustomDomain,
    # With -Only CustomDomain, CustomDomainMcp: takes that host's addresses off the apps instead.
    [switch]$RemoveCustomDomain,
    [switch]$SkipAzureReader,
    [switch]$NoElevate,
    [switch]$Audit,
    # Leaves version 1 of M365Permissions alone: the end of the run does not look for it.
    [switch]$KeepVersion1,
    [switch]$AzureCli,
    # The tenant this runs for: its id or a domain of it. Without it the script finds it, or asks.
    [string]$TenantId,
    # With -Only AzureDevOps: only these organizations, also when this account cannot list the tenant's (their owner runs it).
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')][string[]]$DevOpsOrganization,
    # The Azure subscription to select (an own deployment's). -ManagedApplicationId holds its own.
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string]$SubscriptionId
)

# Windows PowerShell 5.1 lacks .NET APIs and cmdlet parameters used below. Before anything changes, the same command
# goes to PowerShell 7 when it is installed; otherwise the script stops.
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 7 -or ($psVersion.Major -eq 7 -and $psVersion.Minor -lt 4)) {
    $pwsh = if ($PSVersionTable.PSEdition -eq 'Desktop') { Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($pwsh -and $MyInvocation.Line) {
        Write-Host "This is Windows PowerShell $psVersion; the setup runs in PowerShell 7. Running the same command in $($pwsh.Source)." -ForegroundColor Yellow
        & $pwsh.Source -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($MyInvocation.Line)))
        return
    }
    throw "The setup needs PowerShell 7.4 or later; this is PowerShell $psVersion. Nothing was changed. Install PowerShell 7 (winget install Microsoft.PowerShell, or https://aka.ms/powershell), open it and run the same command again."
}

$ErrorActionPreference = 'Stop'
$hosted = $PSCmdlet.ParameterSetName -eq 'Hosted'
$fix = $Only.Count -gt 0
# The app ids the instance names: it fills them in when it serves this script (a copy from elsewhere asks the instance).
$instanceApps = @()
$graphApp = '00000003-0000-0000-c000-000000000000'
$grants = [ordered]@{
    $graphApp                              = @(
        'Directory.Read.All', 'Application.Read.All', 'AuditLog.Read.All', 'AuditLogsQuery.Read.All', 'CrossTenantInformation.ReadBasic.All',
        'DeviceManagementConfiguration.Read.All', 'DeviceManagementServiceConfig.Read.All', 'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementRBAC.Read.All', 'Policy.Read.All', 'EntitlementManagement.Read.All', 'RoleManagement.Read.All',
        'RoleEligibilitySchedule.Read.Directory', 'PrivilegedAccess.Read.AzureAD', 'PrivilegedEligibilitySchedule.Read.AzureADGroup', 'CloudPC.Read.All',
        'SharePointTenantSettings.Read.All', 'Sites.FullControl.All',
        'UserAuthenticationMethod.Read.All', # passkeys of users (fido2Methods)
        'Application.ReadWrite.OwnedBy', # the instance keeps the addresses of its own app registrations; only apps it owns (not hosted)
        # Read only and not read yet: granted now so later features need no new consent (Maester 2 and 3 use most of them)
        'AccessReview.Read.All', 'AgentIdentity.Read.All', 'AgentIdentityBlueprint.Read.All', 'AgentIdentityBlueprintPrincipal.Read.All', 'AppCatalog.Read.All',
        'AttackSimulation.Read.All', 'CopilotPackages.Read.All', 'CustomSecAttributeAssignment.Read.All', 'DeviceManagementApps.Read.All', 'DeviceManagementScripts.Read.All',
        'DirectoryRecommendations.Read.All', 'Domain-InternalFederation.Read.All', 'ExternalConnection.Read.All', 'IdentityRiskEvent.Read.All',
        'IdentityRiskyServicePrincipal.Read.All', 'IdentityRiskyUser.Read.All', 'LifecycleWorkflows.Read.All', 'NetworkAccess.Read.All',
        'OnPremDirectorySynchronization.Read.All', 'OrgSettings-AppsAndServices.Read.All', 'OrgSettings-Forms.Read.All', 'Policy.Read.PermissionGrant',
        'PrivilegedAssignmentSchedule.Read.AzureADGroup', 'Reports.Read.All', 'ReportSettings.Read.All', 'RoleManagementAlert.Read.Directory',
        'RoleManagementPolicy.Read.AzureADGroup', 'SecurityAlert.Read.All', 'SecurityEvents.Read.All', 'SecurityIdentitiesHealth.Read.All',
        'SecurityIdentitiesSensors.Read.All', 'SecurityIncident.Read.All', 'TeamsAppInstallation.ReadForTeam.All', 'ThreatHunting.Read.All'
    )
    '00000003-0000-0ff1-ce00-000000000000' = @('Sites.FullControl.All') # SharePoint: role assignments need FullControl; nothing is written
    '00000002-0000-0ff1-ce00-000000000000' = @('Exchange.ManageAsApp') # Exchange admin API, read with Global Reader
}
$globalReader = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
$resourceNames = @{ $graphApp = 'Graph'; '00000003-0000-0ff1-ce00-000000000000' = 'SharePoint'; '00000002-0000-0ff1-ce00-000000000000' = 'Exchange' }
$askedMail = $Only -contains 'MailSender'
$mcpStep = $EnableMcp -or $Only -contains 'Mcp'
$domainSteps = @('CustomDomain', 'CustomDomainMcp')
$domainStep = @($Only | Where-Object { $_ -in $domainSteps }).Count -gt 0
if ($fix) {
    $known = @(foreach ($resourceApp in $grants.Keys) { foreach ($name in $grants[$resourceApp]) { "$($resourceNames[$resourceApp]):$name" } }) + 'GlobalReader', 'AzureReader', 'PowerBiGroup', 'PowerBiSetting', 'PowerPlatformApp', 'DataverseUser', 'AzureDevOps', 'Network', 'DnsZone', 'MailSender', 'Mcp' + $domainSteps
    if ($Only -contains 'ScanIdentity') { $Only = @($known | Where-Object { $_ -ne 'Mcp' -and $_ -notin $domainSteps }) + @($Only | Where-Object { $_ -eq 'Mcp' -or $_ -in $domainSteps }) }
    $unknown = @($Only | Where-Object { $_ -notin $known })
    if ($unknown) { throw "Unknown grant: $($unknown -join ', '). Known: $($known -join ', '), ScanIdentity." }
}
# Every step outside -Only is skipped.
function Test-Step([string]$Name) { -not $fix -or $Only -contains $Name }
$signInScopes = 'openid profile offline_access User.Read'
$missing = [System.Collections.Generic.List[string]]::new()

# Whether this run can ask questions: a console, not redirected, not -NonInteractive.
function Test-InteractiveConsole {
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $false }
    -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^[-/]noni' })
}

# The tenant this runs for: -TenantId, else the tenant of a subscription the command names (the managed application's;
# Azure names a subscription's tenant to anyone who asks), else the tenant the instance's own sign-in names. An older
# command that names none of these: the session's tenant, after one question (Confirm-SessionTenant).
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
function Get-SubscriptionTenant([string]$Subscription) {
    $challenge = try { (Invoke-WebRequest -Uri "https://management.azure.com/subscriptions/$($Subscription)?api-version=2022-12-01" -SkipHttpErrorCheck -TimeoutSec 30).Headers['WWW-Authenticate'] } catch { $null }
    if ("$challenge" -match 'login\.(?:windows\.net|microsoftonline\.com)/([0-9a-fA-F-]{36})') { return $Matches[1].ToLowerInvariant() }
    $null
}
# The tenant the instance's sign-in sends people to (/auth/signin, public), or $null: a hosted instance's sign-in names no
# tenant, and an instance on a private network does not answer.
function Get-InstanceTenant([string]$Url) {
    $answer = try { Invoke-WebRequest -Uri "$($Url.TrimEnd('/'))/auth/signin" -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 15 -ErrorAction Stop } catch { $_.Exception.Response }
    if ("$($answer.Headers.Location)" -match '^https://login\.microsoftonline\.com/([0-9a-fA-F-]{36})/') { return $Matches[1].ToLowerInvariant() }
    $null
}
# A tenant id, or the id of the tenant a domain belongs to (Entra's public sign-in metadata).
function Resolve-TenantId([string]$Name) {
    if ($Name -match $guidPattern) { return $Name.ToLowerInvariant() }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') { throw "-TenantId $Name is neither a tenant id nor a domain." }
    $metadata = try { Invoke-RestMethod -Uri "https://login.microsoftonline.com/$Name/v2.0/.well-known/openid-configuration" -TimeoutSec 30 } catch { $null }
    if ("$($metadata.token_endpoint)" -match '^https://login\.microsoftonline\.com/([0-9a-fA-F-]{36})/') { return $Matches[1].ToLowerInvariant() }
    throw "-TenantId $Name is neither a tenant id nor a domain of a tenant."
}

$targetSubscription = if ($ManagedApplicationId) { ($ManagedApplicationId -split '/')[2].ToLowerInvariant() } elseif ($SubscriptionId) { $SubscriptionId.ToLowerInvariant() } else { $null }
if ($ManagedApplicationId -and $SubscriptionId -and $SubscriptionId -ne $targetSubscription) { throw "-SubscriptionId $SubscriptionId is not the managed application's subscription ($targetSubscription): leave it out." }
$targetTenant = if ($TenantId) { Resolve-TenantId $TenantId } else { $null }
$tenantSource = 'named by the command'
if ($ManagedApplicationId) {
    $owner = Get-SubscriptionTenant $targetSubscription
    if ($owner -and $targetTenant -and $owner -ne $targetTenant) {
        throw "The managed application's subscription $targetSubscription is in tenant $owner, not in tenant $targetTenant (-TenantId): copy the command from the instance's start page again."
    }
    if ($owner) { $targetTenant = $owner; $tenantSource = "the managed application's" }
}
if (-not $targetTenant) {
    foreach ($resourceId in @($SubscriptionId, $PeerVirtualNetworkId, $PrivateDnsZoneId) | Where-Object { $_ }) {
        $subscriptionPart = if ($resourceId -match '^/subscriptions/([^/]+)') { $Matches[1] } else { $resourceId }
        $owner = Get-SubscriptionTenant $subscriptionPart
        if ($owner) { $targetTenant = $owner; $tenantSource = "the tenant of subscription $subscriptionPart"; break }
    }
}
if (-not $targetTenant -and $WebUrl) {
    $owner = Get-InstanceTenant $WebUrl
    if ($owner) { $targetTenant = $owner; $tenantSource = "named by the instance's sign-in" }
}
if ($targetTenant) { Write-Host "Tenant $targetTenant ($tenantSource)$(if ($targetSubscription) { ", subscription $targetSubscription" })" }

# Consent phishing (docs/msp.md 10): -ScanAppId and -SignInAppId must be apps the instance at -WebUrl names, so an edited
# command cannot have an admin grant rights to someone else's app. The names come with the script the instance served,
# else from the instance itself; without them nothing is granted.
function Get-InstanceAppId([string]$Url) {
    if (@($instanceApps).Count) { return @($instanceApps | ForEach-Object { "$_".ToLowerInvariant() }) }
    $served = try { Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/setup/initialize.ps1" -TimeoutSec 30 } catch { $null }
    if ("$served" -match '(?m)^\$instanceApps = @\(([^)\r\n]*)\)') {
        return @([regex]::Matches($Matches[1], '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLowerInvariant() })
    }
    @()
}
if ($hosted -or ($fix -and $ScanAppId)) {
    $named = @(Get-InstanceAppId $WebUrl)
    foreach ($appId in @($ScanAppId, $SignInAppId) | Where-Object { $_ }) {
        if (-not $named) { throw "Could not ask $WebUrl which apps it names, so this command grants nothing. Copy the command from the instance again, or download the script from it and run that." }
        if ("$appId".ToLowerInvariant() -notin $named) {
            throw "App $appId is not an app of the instance at $WebUrl (it names $($named -join ', ')): this command was changed or not made by that instance. Copy it from the instance again, and grant nothing to an app you do not know."
        }
    }
}

# The sign-in that is already there: Az PowerShell, else the Azure CLI. With neither, Az.Accounts (installed for you when
# missing) and its own sign-in. No device codes. Each ends in the target tenant, or the run stops.
$hasAzModule = [bool](Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)
$hasCli = [bool](Get-Command az -ErrorAction SilentlyContinue)
$useAz = -not $AzureCli -and $hasAzModule -and (Get-AzContext -ErrorAction SilentlyContinue)
function Get-CliAccount { & az account show -o json 2>$null | ConvertFrom-Json }
# Stops the run when a sign-in is in another tenant than this setup is for, naming both.
function Assert-SessionTenant([string]$Actual, [string]$What) {
    if (-not $targetTenant -or "$Actual".ToLowerInvariant() -eq $targetTenant) { return }
    $how = if ($useAz) { "Connect-AzAccount -Tenant $targetTenant" } else { "az login --tenant $targetTenant --allow-no-subscriptions" }
    throw "$What is signed in to tenant $(if ($Actual) { $Actual } else { '(none)' }), but this setup is for tenant $targetTenant. Sign in with an account of tenant $targetTenant ($how), then run the command again."
}
# Az's own sign-in, to the target tenant when known. A tenant without any Azure subscription works too. The subscription
# list Az shows after an interactive sign-in is off for this session, so nothing waits for an answer there.
function Connect-AzTenant {
    if (Get-Command Update-AzConfig -ErrorAction SilentlyContinue) {
        try { Update-AzConfig -LoginExperienceV2 Off -Scope Process -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null } catch { Write-Verbose "$_" }
    }
    $connect = @{ WarningAction = 'SilentlyContinue'; ErrorAction = 'Stop' }
    if ($targetTenant) { $connect.Tenant = $targetTenant }
    # Az signs in to DefaultSubscriptionForLogin (Get-AzConfig) when no subscription is named, and fails when that one is
    # of another tenant: name the target subscription instead.
    $default = try { "$((Get-AzConfig -DefaultSubscriptionForLogin -WarningAction SilentlyContinue -ErrorAction Stop | Select-Object -First 1).Value)" } catch { '' }
    if ($default -and $targetSubscription -and $default -ne $targetSubscription) { $connect.Subscription = $targetSubscription }
    try { Connect-AzAccount @connect | Out-Null }
    catch {
        if (-not $default) { throw }
        $tried = if ($connect.Subscription) { "subscription $targetSubscription is not one this account may use, and " } else { '' }
        throw "Az PowerShell could not sign in: $($tried)Az signs in to subscription $default by default (Get-AzConfig, DefaultSubscriptionForLogin), which this account may not use$(if ($targetTenant) { " in tenant $targetTenant" }). Run Clear-AzConfig -DefaultSubscriptionForLogin, then run the command again. ($_)"
    }
}
# Best effort: the target subscription (a Global Administrator may have no Azure access yet, a tenant no subscription).
$noSubscription = "Subscription $targetSubscription is not one this account may use (yet): the Azure steps say what that means."
function Select-TargetSubscription {
    if (-not $targetSubscription -or "$((Get-AzContext).Subscription.Id)" -eq $targetSubscription) { return }
    try { Set-AzContext -Tenant $targetTenant -Subscription $targetSubscription -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null }
    catch { Write-Host $noSubscription -ForegroundColor DarkGray }
}

$account = if (-not $useAz -and $hasCli) { Get-CliAccount } else { $null }
if (-not $useAz -and $hasCli -and ($AzureCli -or $account -or -not $hasAzModule)) {
    if ($targetTenant -and $account -and "$($account.tenantId)" -ne $targetTenant) {
        # An account this sign-in already has in that tenant.
        $knownAccount = & az account list --query "[?tenantId=='$targetTenant'] | [0].id" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $knownAccount) { & az account set --subscription "$knownAccount" 2>$null; $account = Get-CliAccount }
    }
    if (-not $account -or ($targetTenant -and "$($account.tenantId)" -ne $targetTenant)) {
        Write-Host "Signing in with the Azure CLI$(if ($targetTenant) { " to tenant $targetTenant" })."
        $login = @('login', '--allow-no-subscriptions', '-o', 'none')
        if ($targetTenant) { $login += '--tenant', $targetTenant }
        & az @login
        if ($LASTEXITCODE -ne 0) { throw 'The Azure CLI sign-in did not finish.' }
        $account = Get-CliAccount
    }
    Assert-SessionTenant "$($account.tenantId)" 'The Azure CLI'
    if ($targetSubscription -and "$($account.id)" -ne $targetSubscription) {
        & az account set --subscription $targetSubscription 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host $noSubscription -ForegroundColor DarkGray }
    }
}
elseif (-not $useAz) {
    if (-not $hasAzModule) {
        Write-Host 'Installing Az.Accounts for the current user (sign-in only).'
        Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
        Import-Module Az.Accounts
    }
    Connect-AzTenant
    $useAz = $true
}
# A session in another tenant (a guest account, another customer) is switched first: to a context this account already
# has there (the target subscription's first), else with Az's own sign-in.
if ($useAz) {
    $current = "$((Get-AzContext).Tenant.Id)".ToLowerInvariant()
    if ($targetTenant -and $current -ne $targetTenant) {
        Write-Host "This session is signed in to tenant $current; switching to $targetTenant, the tenant of this instance."
        $inTenant = @(Get-AzContext -ListAvailable | Where-Object { "$($_.Tenant.Id)" -eq $targetTenant })
        $knownContext = @(@($inTenant | Where-Object { $targetSubscription -and "$($_.Subscription.Id)" -eq $targetSubscription }) + $inTenant) | Select-Object -First 1
        if ($knownContext) { Set-AzContext -Context $knownContext -WarningAction SilentlyContinue | Out-Null }
        else { Connect-AzTenant }
    }
    Assert-SessionTenant "$((Get-AzContext).Tenant.Id)" 'Azure PowerShell (Az)'
    Select-TargetSubscription
}

function Get-TokenOnce([string]$Resource) {
    if ($useAz) {
        $tokenArguments = @{ ResourceUrl = $Resource; WarningAction = 'SilentlyContinue' }
        if ($targetTenant) { $tokenArguments.TenantId = $targetTenant }
        $token = (Get-AzAccessToken @tokenArguments -ErrorAction Stop).Token
        if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
        return $token
    }
    $arguments = @('account', 'get-access-token', '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv')
    if ($targetTenant) { $arguments += '--tenant', $targetTenant }
    $output = & az @arguments 2>&1
    $token = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join ''
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        $reason = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
        throw "No Azure CLI token for $Resource. $reason"
    }
    $token
}

# The tenant a token was issued in (its tid claim), or $null when it cannot be read.
function Get-TokenClaim([string]$Token) {
    $parts = "$Token".Split('.')
    if ($parts.Count -lt 3) { return $null }
    try {
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - $payload.Length % 4) % 4)
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    }
    catch { Write-Verbose "$_" }
    $null
}
function Get-TokenTenant([string]$Token) {
    $claims = Get-TokenClaim $Token
    if ($claims.tid) { return "$($claims.tid)".ToLowerInvariant() }
    $null
}

# A sign-in in a thread of its own with a time limit: a browser page that never answers ("you don't have access to
# this") would otherwise hold the run for good. Az keeps its sign-in per process, so the thread's counts here as well. A
# thread that runs out of time is left: stopping it would wait for the browser too.
function Invoke-TimedSignIn([scriptblock]$SignIn, [hashtable]$Arguments, [int]$Seconds) {
    $job = Start-ThreadJob -ScriptBlock $SignIn -ArgumentList $Arguments
    if (-not (Wait-Job $job -Timeout $Seconds)) { throw "The sign-in did not finish within $Seconds seconds." }
    try { Receive-Job $job -ErrorAction Stop | Out-Null } finally { Remove-Job $job -Force }
}
# The Azure CLI's sign-in as a process of its own, ended after $Seconds.
function Invoke-TimedCliSignIn([string[]]$Arguments, [int]$Seconds) {
    $process = Start-Process -FilePath (Get-Command az).Source -ArgumentList $Arguments -NoNewWindow -PassThru
    $null = $process.Handle # without it ExitCode stays empty
    if (-not $process.WaitForExit($Seconds * 1000)) {
        try { $process.Kill($true) } catch { Write-Verbose "$_" }
        throw "The sign-in did not finish within $Seconds seconds."
    }
    if ($process.ExitCode -ne 0) { throw 'The Azure CLI sign-in did not finish.' }
}

# Errors a fresh interactive sign-in for that resource can cure: the tenant asks for multi-factor authentication or
# Conditional Access needs a fresh sign-in, typically after switching from another tenant.
$freshSignIn = 'interaction is required|AuthScope|--scope|AADSTS50076|AADSTS50079|AADSTS50078|AADSTS53003|AADSTS50158|multi-factor'
# Graph and Azure Resource Manager are the run itself: their sign-in runs here, while the admin watches. The optional
# services' sign-in (Azure DevOps, Power Platform, Dataverse, Fabric) gets a time limit.
$requiredResources = @('https://graph.microsoft.com', 'https://management.azure.com/')
$signInSeconds = 180
$script:signedInFor = @{}
$script:signInFailed = @{}
$script:signInTimedOut = $false

# One interactive sign-in for $Resource, with the same account, in the target tenant. A stand-in for the sign-in command
# (tests) runs inline: a thread sees only modules.
function Invoke-FreshSignIn([string]$Resource) {
    $limited = $Resource -notin $requiredResources
    if ($useAz) {
        $connect = @{ AuthScope = $Resource; WarningAction = 'SilentlyContinue'; ErrorAction = 'Stop' }
        if ($targetTenant) { $connect.Tenant = $targetTenant }
        if ("$((Get-AzContext).Account.Id)") { $connect.AccountId = "$((Get-AzContext).Account.Id)" }
        if ($limited -and "$((Get-Command Connect-AzAccount).CommandType)" -eq 'Cmdlet' -and (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
            Invoke-TimedSignIn { param($Arguments) Connect-AzAccount @Arguments | Out-Null } $connect $signInSeconds
        }
        else { Connect-AzAccount @connect | Out-Null }
        Assert-SessionTenant "$((Get-AzContext).Tenant.Id)" 'Azure PowerShell (Az)'
        # A new sign-in picks a default subscription: back to the target one.
        Select-TargetSubscription
        return
    }
    $login = @('login', '--allow-no-subscriptions', '-o', 'none', '--scope', "$($Resource.TrimEnd('/'))/.default")
    if ($targetTenant) { $login += '--tenant', $targetTenant }
    if ($limited -and "$((Get-Command az).CommandType)" -eq 'Application') { Invoke-TimedCliSignIn $login $signInSeconds }
    else {
        & az @login
        if ($LASTEXITCODE -ne 0) { throw 'The Azure CLI sign-in did not finish.' }
    }
}

# A token of the target tenant for $Resource. One the existing sign-in cannot get silently gets one interactive sign-in:
# at most once per $Family (default: the resource) and run, and none after one ran out of time, so a refusal stops instead
# of asking in a loop. Every failure is an AuthenticationException (see Get-SignInProblem).
function Get-Token([string]$Resource, [string]$Family) {
    if (-not $Family) { $Family = $Resource }
    if ($script:signInFailed[$Family]) { throw [System.Security.Authentication.AuthenticationException]::new($script:signInFailed[$Family]) }
    try {
        try { $token = Get-TokenOnce $Resource }
        catch {
            if ($script:signedInFor[$Family] -or "$_" -notmatch $freshSignIn) { throw }
            if ($script:signInTimedOut) { throw "$Resource asks for a fresh sign-in, and an earlier sign-in of this run did not finish within $signInSeconds seconds. $_" }
            $script:signedInFor[$Family] = $true
            Write-Host "Tenant $targetTenant asks you to sign in again for $Resource (multi-factor authentication or Conditional Access). A browser window opens once$(if ($Resource -notin $requiredResources) { "; this step waits up to $signInSeconds seconds for it" })." -ForegroundColor Yellow
            try {
                Invoke-FreshSignIn $Resource | Out-Null
                $token = Get-TokenOnce $Resource
            }
            catch {
                if ("$_" -match 'did not finish within') { $script:signInTimedOut = $true }
                $script:signInFailed[$Family] = "$_"
                throw
            }
        }
    }
    catch {
        if ($_.Exception -is [System.Security.Authentication.AuthenticationException]) { throw }
        throw [System.Security.Authentication.AuthenticationException]::new("$_", $_.Exception)
    }
    $issued = Get-TokenTenant $token
    if ($targetTenant -and $issued -and $issued -ne $targetTenant) {
        throw [System.Security.Authentication.AuthenticationException]::new("The sign-in for $Resource is in tenant $issued, but this setup is for tenant $targetTenant. Sign in with an account of tenant $targetTenant, then run the command again.")
    }
    $token
}

# Why an optional step could not sign in, in plain words, or $null when its failure was no sign-in.
$noAccessProblem = 'this account has no access to it, or the sign-in was refused'
$noCacheProblem = 'the Azure sign-in of this session holds no token for it'
function Get-SignInProblem($ErrorRecord) {
    if ($ErrorRecord.Exception -isnot [System.Security.Authentication.AuthenticationException]) { return $null }
    $text = $ErrorRecord.Exception.Message
    if ($text -match 'SharedTokenCacheCredential|supports Azure single sign on') { return $noCacheProblem }
    if ($text -match 'did not finish within') { return 'the sign-in did not finish in time' }
    if ($text -match 'is in tenant') { return $text }
    if ($text -match 'AADSTS50020|AADSTS500011|AADSTS650052|AADSTS50105|AADSTS53003|AADSTS530003|AADSTS50097|access_denied|authentication_canceled|cancell?ed|have access') { return $noAccessProblem }
    if ($text -match $freshSignIn) { return 'it asks for a fresh sign-in, which this run asked for once already' }
    "the sign-in failed: $text"
}

$graphToken = Get-Token 'https://graph.microsoft.com'

function Invoke-Graph([string]$Method, [string]$Path, $Body, [switch]$Advanced) {
    $headers = @{ Authorization = "Bearer $graphToken" }
    if ($Advanced) { $headers.ConsistencyLevel = 'eventual' }
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://graph.microsoft.com/v1.0$Path" }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json -ContentType 'application/json'
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            # New objects take a moment to replicate; throttling and server errors pass.
            if ($attempt -lt 6 -and ($status -in 404, 429 -or $status -ge 500 -or "$_" -match 'does not exist|not found')) { Start-Sleep -Seconds (5 * $attempt); continue }
            throw
        }
    }
}

# Steps reported as failed or missing: with any, the version 1 clean-up at the end is not offered.
$script:stepIssues = 0
$script:optionalIssues = 0
$optionalManual = 0
function Write-Step([string]$Text, [string]$State) {
    if ($State -in 'failed', 'missing') { $script:stepIssues++ }
    $color =switch ($State) { 'ok' { 'Green' } 'added' { 'Cyan' } 'removed' { 'Cyan' } 'missing' { 'Yellow' } 'note' { 'Yellow' } 'skipped' { 'DarkGray' } default { 'Red' } }
    Write-Host ("  [{0,-7}] {1}" -f $State, $Text) -ForegroundColor $color
}

# An older command named no tenant and none was found: the session's tenant, after one question (Y/n). Without a console
# to ask in, the run stops and asks for -TenantId.
function Confirm-SessionTenant($Organization) {
    $domain = @($Organization.verifiedDomains | Where-Object { $_.isDefault }) | Select-Object -First 1
    $name = "$($Organization.displayName)$(if ($domain) { " ($($domain.name))" }), $($Organization.id)"
    if (-not (Test-InteractiveConsole)) {
        throw "This command does not name its tenant, and this session is signed in to tenant $name. Run it again with -TenantId <the instance's tenant id>; the instance shows the complete command."
    }
    $answer = try { Read-Host "This command does not name its tenant. This session is signed in to tenant $name. Is that the tenant of this M365Permissions instance? (Y/n)" } catch { 'n' }
    if ("$answer".Trim() -match '^(n|no)$') { throw "Stopped. Sign in to the instance's tenant, or run the command again with -TenantId <the instance's tenant id>." }
}

# Who runs this: a member of the tenant, or an account of another tenant (a delegated GDAP admin of an MSP, or a guest), who
# gets no role here (docs/msp.md 3.3 step 4). /me may not answer for a delegated admin (UNCONFIRMED): the token names them then.
$me = try { Invoke-RestMethod -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName,userType' -Headers @{ Authorization = "Bearer $graphToken" } } catch { $null }
$callerMember = [bool]$me -and "$($me.userType)" -ne 'Guest'
if (-not $me) {
    $claims = Get-TokenClaim $graphToken
    $me = [pscustomobject]@{ id = "$($claims.oid)"; userPrincipalName = "$(@($claims.upn, $claims.unique_name, $claims.preferred_username, $claims.oid) | Where-Object { $_ } | Select-Object -First 1)" }
}
$organization = @((Invoke-Graph GET '/organization?$select=id,displayName,verifiedDomains').value)[0]
$tenantId = "$($organization.id)".ToLowerInvariant()
if ($targetTenant -and $tenantId -ne $targetTenant) {
    throw "Microsoft Graph answers for tenant $tenantId, but this setup is for tenant $targetTenant. Sign in with an account of tenant $targetTenant, then run the command again."
}
if (-not $targetTenant) {
    Confirm-SessionTenant $organization
    $targetTenant = $tenantId
}

# Azure Resource Manager REST with the same sign-in (no Az module needed).
$script:armToken = $null
function Invoke-Arm([string]$Method, [string]$Path, $Body) {
    if (-not $script:armToken) { $script:armToken = Get-Token 'https://management.azure.com/' }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
    Invoke-RestMethod -Method $Method -Uri "https://management.azure.com$Path" -Headers @{ Authorization = "Bearer $script:armToken" } -Body $json -ContentType 'application/json'
}
# Your User Access Administrator assignment at the root scope "/": what Entra's "Access management for Azure resources" switch sets.
$accessAdministrator = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
function Get-RaisedAccess {
    try {
        @((Invoke-Arm GET "/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$($me.id)'").value |
            Where-Object { $_.properties.scope -eq '/' -and $_.properties.roleDefinitionId -like "*/$accessAdministrator" })
    }
    catch { @() }
}
function Restore-RaisedAccess {
    # The new assignment can take a moment to show up.
    $assignments = @()
    for ($attempt = 1; $attempt -le 6 -and -not $assignments; $attempt++) {
        $assignments = Get-RaisedAccess
        if (-not $assignments) { Start-Sleep -Seconds 10 }
    }
    try {
        if (-not $assignments) { throw 'not found' }
        foreach ($assignment in $assignments) { Invoke-Arm DELETE "$($assignment.id)?api-version=2022-04-01" | Out-Null }
        Write-Step 'Your Azure access set back as it was' 'ok'
    }
    catch {
        Write-Step 'Could not set your Azure access back: Entra admin center > Properties > Access management for Azure resources > No > Save' 'failed'
    }
}

if ($ManagedApplicationId) {
    # The deployment's values (and its setup code) reach only someone who may read the managed application.
    $applicationName = ($ManagedApplicationId -split '/')[-1]
    Write-Host "Reading the managed application $applicationName"
    function Read-ManagedApplication { Invoke-Arm GET "$($ManagedApplicationId)?api-version=2021-07-01" }
    $application = $null
    try { $application = Read-ManagedApplication }
    catch {
        $status = [int]$_.Exception.Response.StatusCode
        $cannot = "Your account cannot read the managed application $applicationName (HTTP $status). Sign in as someone with read access to its resource group"
        if ($status -notin 401, 403) { throw "$cannot, or check the id." }
        if ($NoElevate -or $Audit) { throw "$cannot, or run without -NoElevate and -Audit: a Global Administrator's Azure access is then raised for this read." }
        if (Get-RaisedAccess) { throw "$cannot." }
        # A Global Administrator often has no Azure access: raise it for this read, and set it back right after.
        try { Invoke-Arm POST '/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01' | Out-Null }
        catch { throw "$cannot. Raising your Azure access needs a Global Administrator." }
        Write-Step 'Your Azure access raised to read it (Access management for Azure resources)' 'added'
        try {
            # Azure takes a minute or two to apply raised access.
            for ($attempt = 1; -not $application; $attempt++) {
                try { $application = Read-ManagedApplication }
                catch { if ($attempt -ge 18) { throw "$cannot, even with raised access." }; Start-Sleep -Seconds 10 }
            }
        }
        finally { Restore-RaisedAccess }
    }
    $command = $application.properties.outputs.setupCommand.value
    if (-not $command) { throw "The managed application $applicationName has no setup values yet: its deployment has not finished. Try again in a few minutes." }
    $values = @{}
    foreach ($match in [regex]::Matches($command, "-(\w+) '([^']*)'")) { $values[$match.Groups[1].Value] = $match.Groups[2].Value }
    $WebUrl = $values.WebUrl
    $ScanIdentityPrincipalId = $values.ScanIdentityPrincipalId
    $WebIdentityPrincipalId = $values.WebIdentityPrincipalId
    $SetupCode = $values.SetupCode
    # Assigning re-checks each parameter's pattern.
    if (-not $PeerVirtualNetworkId -and $values.PeerVirtualNetworkId) { $PeerVirtualNetworkId = $values.PeerVirtualNetworkId }
    if (-not $PrivateDnsZoneId -and $values.PrivateDnsZoneId) { $PrivateDnsZoneId = $values.PrivateDnsZoneId }
    if (-not $AlertSenderMailbox -and $values.AlertSenderMailbox) { $AlertSenderMailbox = $values.AlertSenderMailbox }
    if (-not ($WebUrl -and $ScanIdentityPrincipalId -and $WebIdentityPrincipalId -and $SetupCode)) { throw "The managed application $applicationName does not name its instance's identities." }
}
$host_ = ([uri]$WebUrl).Host
Write-Host "M365Permissions setup for $host_ in tenant $tenantId, as $($me.userPrincipalName)$(if ($Audit) { ' (audit only)' })"

# The Entra admin center lists an enterprise app under its default filter (Enterprise Applications) only with this tag;
# admin consent adds it, a plain POST does not.
$listedTag = 'WindowsAzureActiveDirectoryIntegratedApp'

# The enterprise app of an app registration of another tenant (hosted): made by admin consent, or here.
# The sign-in app's (assignment required) gets that switched on when it was made without: only people this tenant assigns sign in.
function Get-EnterpriseApp([string]$AppId, [string]$Label, [bool]$AssignmentRequired) {
    $found = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,appId,displayName,appRoles,appRoleAssignmentRequired,tags").value | Select-Object -First 1
    if ($found -and $AssignmentRequired -and -not $found.appRoleAssignmentRequired) {
        if ($Audit) { Write-Step "$Label $($found.displayName): assignment required" 'missing'; $missing.Add("$Label assignment required") }
        else {
            Invoke-Graph PATCH "/servicePrincipals/$($found.id)" @{ appRoleAssignmentRequired = $true } | Out-Null
            Write-Step "$Label $($found.displayName): assignment required" 'added'
        }
    }
    if ($found -and -not $Audit -and @($found.tags) -notcontains $listedTag) {
        Invoke-Graph PATCH "/servicePrincipals/$($found.id)" @{ tags = @(@($found.tags | Where-Object { $_ }) + $listedTag) } | Out-Null
        Write-Step "$Label $($found.displayName): listed under Enterprise applications" 'added'
    }
    if ($found) { return $found }
    if ($Audit) { Write-Step "$Label ($AppId)" 'missing'; $missing.Add($Label); return $null }
    $created = Invoke-Graph POST '/servicePrincipals' @{ appId = $AppId; appRoleAssignmentRequired = $AssignmentRequired; tags = @($listedTag) }
    Write-Step "$Label $($created.displayName)" 'added'
    $created
}

if (-not $callerMember) {
    Write-Host "You are not a member of tenant $tenantId (a delegated GDAP admin or a guest): the setup gives you no role here; an admin of this tenant assigns their own staff." -ForegroundColor Yellow
}
if ($hosted) {
    Write-Host "`nCustomer tenant of a hosted or MSP instance: enterprise apps"
    $scan = Get-EnterpriseApp $ScanAppId 'Scan app' $false
    if (-not $scan) { Write-Host "`nMissing: $($missing -join ', ')" -ForegroundColor Yellow; return }
}
elseif ($ScanAppId) {
    $scan = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$ScanAppId'&`$select=id,appId,displayName").value | Select-Object -First 1
    if (-not $scan) { throw "No scan identity with application id $ScanAppId in this tenant: run the setup command from the deployment outputs." }
}
else {
    $scan = Invoke-Graph GET "/servicePrincipals/$($ScanIdentityPrincipalId)?`$select=id,appId,displayName"
}

# This setup's command for one step alone, to run that step again later.
function Get-StepCommand([string]$Step) {
    $site = "$WebUrl".TrimEnd('/')
    $which = if ($ManagedApplicationId) { "-ManagedApplicationId '$ManagedApplicationId'" } else { "-WebUrl '$site' -ScanAppId '$($scan.appId)'" }
    # The managed application holds these ids; a deployment of your own names them on the command.
    if (-not $ManagedApplicationId -and $Step -eq 'Network' -and $PeerVirtualNetworkId) { $which += " -PeerVirtualNetworkId '$PeerVirtualNetworkId'" }
    if (-not $ManagedApplicationId -and $Step -eq 'DnsZone' -and $PrivateDnsZoneId) { $which += " -PrivateDnsZoneId '$PrivateDnsZoneId'" }
    "& ([scriptblock]::Create((Invoke-RestMethod '$site/setup/initialize.ps1'))) $which -TenantId '$tenantId' -Only '$Step'"
}
# For an account of another tenant: Microsoft may refuse a step to a delegated (GDAP) or guest admin (UNCONFIRMED for Azure,
# Fabric, Power Platform, Dataverse, Azure DevOps and Exchange); then an account of this tenant runs that step alone.
function Write-DelegatedNote([string]$Step) {
    if ($callerMember) { return }
    Write-Host "  You are not a member of this tenant: Microsoft may not let a delegated or guest admin do this step. If it fails, an account of this tenant runs: $(Get-StepCommand $Step)" -ForegroundColor DarkGray
}

Write-Host "`nScan identity $($scan.displayName): read permissions"
$held = (Invoke-Graph GET "/servicePrincipals/$($scan.id)/appRoleAssignments?`$top=999").value
foreach ($resourceApp in $grants.Keys) {
    # Hosted and MSP customers: the sign-in app lives in the instance's tenant, so the scan app owns nothing here and gets no write right.
    $wanted = @($grants[$resourceApp] | Where-Object { (Test-Step "$($resourceNames[$resourceApp]):$_") -and -not ($hosted -and $_ -eq 'Application.ReadWrite.OwnedBy') })
    if (-not $wanted) { continue }
    $resource = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$resourceApp'&`$select=id,displayName,appRoles").value[0]
    if (-not $resource) { Write-Step "$resourceApp is not in this tenant" 'missing'; $missing.Add($resourceApp); continue }
    foreach ($name in $wanted) {
        $role = $resource.appRoles | Where-Object { $_.value -eq $name -and $_.allowedMemberTypes -contains 'Application' }
        $label = "$($resource.displayName): $name"
        # A permission Microsoft does not offer in this tenant (yet) is skipped, not a failure.
        if (-not $role) { Write-Step "$label (not offered in this tenant)" 'skipped'; continue }
        if ($held | Where-Object { $_.resourceId -eq $resource.id -and $_.appRoleId -eq $role.id }) { Write-Step $label 'ok'; continue }
        if ($Audit) { Write-Step $label 'missing'; $missing.Add($label); continue }
        Invoke-Graph POST "/servicePrincipals/$($scan.id)/appRoleAssignments" @{ principalId = $scan.id; resourceId = $resource.id; appRoleId = $role.id } | Out-Null
        Write-Step $label 'added'
    }
}
if (Test-Step 'GlobalReader') {
    $roles = (Invoke-Graph GET "/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($scan.id)' and roleDefinitionId eq '$globalReader'").value
    if ($roles) { Write-Step 'Directory role Global Reader' 'ok' }
    elseif ($Audit) { Write-Step 'Directory role Global Reader' 'missing'; $missing.Add('Global Reader') }
    else {
        Invoke-Graph POST '/roleManagement/directory/roleAssignments' @{ principalId = $scan.id; roleDefinitionId = $globalReader; directoryScopeId = '/' } | Out-Null
        Write-Step 'Directory role Global Reader' 'added'
    }
}

if (-not $SkipAzureReader -and (Test-Step 'AzureReader')) {
    Write-Host "`nAzure: Reader for the scan identity"
    Write-DelegatedNote 'AzureReader'
    $reader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    # The root scope "/" is the path prefix "".
    function Get-ReaderAt([string]$Scope) {
        $assignments = (Invoke-Arm GET "$($Scope.TrimEnd('/'))/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$($scan.id)'").value
        $assignments | Where-Object { $_.properties.scope -eq $Scope -and $_.properties.roleDefinitionId -like "*/$reader" }
    }
    function Add-ReaderAt([string]$Scope) {
        Invoke-Arm PUT "$($Scope.TrimEnd('/'))/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())?api-version=2022-04-01" @{
            properties = @{ roleDefinitionId = "$(if ($Scope.StartsWith('/subscriptions/')) { $Scope })/providers/Microsoft.Authorization/roleDefinitions/$reader"; principalId = $scan.id; principalType = 'ServicePrincipal' }
        } | Out-Null
    }
    # Reader at the root scope "/" reaches every management group and subscription and the assignments made at the root
    # (the Admins scan reads those); only a User Access Administrator at "/" (raised access) can assign it.
    $rootScope = '/'
    $rootGroup = "/providers/Microsoft.Management/managementGroups/$tenantId"
    # Retries only a refusal: Azure takes a minute or two to apply raised access.
    function Add-ReaderAtRoot([int]$Attempts) {
        for ($attempt = 1; ; $attempt++) {
            try { Add-ReaderAt $rootScope; return $true }
            catch {
                if ($attempt -ge $Attempts -or "$_" -notmatch 'AuthorizationFailed|Forbidden|403') { return $false }
                Start-Sleep -Seconds 10
            }
        }
    }
    $rootLabel = 'Reader at the root scope / (all of Azure)'
    $atRoot = try { Get-ReaderAt $rootScope } catch { $null }
    if ($atRoot) { Write-Step $rootLabel 'ok' }
    elseif ($Audit) { Write-Step $rootLabel 'missing' }
    elseif (Add-ReaderAtRoot 1) { Write-Step $rootLabel 'added' }
    else {
        # A Global Administrator often has no Azure access: raise it for this step only, and set it back below.
        $raised = $false
        try {
            if ($callerMember -and -not $NoElevate -and -not (Get-RaisedAccess)) {
                try {
                    Invoke-Arm POST '/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01' | Out-Null
                    $raised = $true
                    Write-Step 'Your Azure access raised for this step (Access management for Azure resources)' 'added'
                }
                catch { Write-Step 'Raising your Azure access needs a Global Administrator; trying the root management group and subscriptions instead' 'missing' }
            }
            if ($raised -and (Add-ReaderAtRoot 12)) { Write-Step $rootLabel 'added' }
            elseif ($(try { Get-ReaderAt $rootGroup } catch { $null }) -or $(try { Add-ReaderAt $rootGroup; $true } catch { $false })) {
                # One level down: all subscriptions, but not the assignments made at the root scope.
                Write-Step 'Reader on the tenant root management group (assignments at the root scope stay unread: run this as a Global Administrator)' 'missing'
            }
            else {
                # Not allowed at the root: every subscription this account can assign roles in instead.
                $listed = $true
                $subscriptions = @(try { (Invoke-Arm GET '/subscriptions?api-version=2022-12-01').value | Where-Object tenantId -eq $tenantId }
                    catch { $listed = $false; Write-Step "Azure subscriptions could not be listed: $($_.Exception.Message)" 'failed' })
                # A tenant without Azure (or none this account sees): nothing to read there, and nothing failed.
                if ($listed -and $subscriptions.Count -eq 0) { Write-Step 'Reader on Azure: no subscription in this tenant that this account can see, so nothing to read in Azure yet' 'skipped' }
                foreach ($subscription in $subscriptions) {
                    $scope = "/subscriptions/$($subscription.subscriptionId)"
                    try {
                        if (Get-ReaderAt $scope) { Write-Step "Reader on $($subscription.displayName)" 'ok'; continue }
                        Add-ReaderAt $scope
                        Write-Step "Reader on $($subscription.displayName)" 'added'
                    }
                    catch { Write-Step "Reader on $($subscription.displayName): $($_.Exception.Message)" 'failed' }
                }
            }
        }
        finally {
            if ($raised) { Restore-RaisedAccess }
        }
    }
}

if (Test-Step 'PowerBiGroup') {
    Write-Host "`nPower BI: security group with the scan identity"
    $powerBiGroup = (Invoke-Graph GET "/groups?`$filter=mailNickname eq 'm365permissions-scanners'&`$select=id,displayName,createdDateTime").value | Select-Object -First 1
    if (-not $powerBiGroup -and $Audit) { Write-Step 'Group M365Permissions scanners' 'missing' }
    elseif (-not $powerBiGroup) {
        $powerBiGroup = Invoke-Graph POST '/groups' @{
            displayName = 'M365Permissions scanners'; mailNickname = 'm365permissions-scanners'; mailEnabled = $false; securityEnabled = $true
            description = 'The M365Permissions scan identity, for the Fabric setting that lets service principals use read-only admin APIs'
        }
        Write-Step 'Group M365Permissions scanners' 'added'
    }
    else { Write-Step 'Group M365Permissions scanners' 'ok' }
    if ($powerBiGroup) {
        $members = (Invoke-Graph GET "/groups/$($powerBiGroup.id)/members?`$select=id").value
        if ($members | Where-Object id -eq $scan.id) { Write-Step 'Scan identity in the group' 'ok' }
        elseif ($Audit) { Write-Step 'Scan identity in the group' 'missing' }
        else {
            # The member list can lag behind (replicas) or have more pages: an existing membership counts as done.
            try {
                Invoke-Graph POST "/groups/$($powerBiGroup.id)/members/`$ref" @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($scan.id)" } | Out-Null
                Write-Step 'Scan identity in the group' 'added'
            }
            catch {
                if ("$_" -notmatch 'already exist') { throw }
                Write-Step 'Scan identity in the group' 'ok'
            }
        }
    }
}

# Steps this account could not do, for an admin who can (printed at the end).
$manual = [System.Collections.Generic.List[string]]::new()

# An optional step that could not sign in: skipped, with the reason, what an admin does by hand and the command for this
# step alone.
function Write-SignInSkip([string]$Label, [string]$Service, [string]$Problem, [string]$Step, [string]$ByHand) {
    $why = if ($Problem -eq $noAccessProblem) { "this account has no access to $Service, or the sign-in was refused" } else { "sign-in to $Service was not possible from this session ($Problem)" }
    $first = if ($Problem -eq $noCacheProblem -and $useAz) { ", after Connect-AzAccount -Tenant $tenantId" } else { '' }
    Write-Step "$($Label): $why, so this step is skipped. To run only this step again$($first): $(Get-StepCommand $Step)" 'skipped'
    if ($ByHand) { $manual.Add($ByHand) }
}

if (Test-Step 'PowerBiSetting') {
    Write-Host "`nFabric: the group M365Permissions scanners may use the read-only admin APIs"
    Write-DelegatedNote 'PowerBiSetting'
    $byHand = "Fabric admin portal > Tenant settings > 'Service principals can use read-only admin APIs': Enabled, for the group M365Permissions scanners (a Fabric administrator)"
    if (-not $powerBiGroup) { $powerBiGroup = (Invoke-Graph GET "/groups?`$filter=mailNickname eq 'm365permissions-scanners'&`$select=id,displayName,createdDateTime").value | Select-Object -First 1 }
    try {
        # The Power BI audience works for a Cloud Shell sign-in, and the Fabric admin API takes it.
        # The Fabric audience only when the Power BI one failed without a browser sign-in: one at most.
        $fabricToken = try { Get-Token 'https://analysis.windows.net/powerbi/api' 'Fabric' }
        catch { if ($script:signedInFor['Fabric'] -or $script:signInTimedOut) { throw }; Get-Token 'https://api.fabric.microsoft.com' 'Fabric' }
        $fabricHeaders = @{ Authorization = "Bearer $fabricToken" }
        $settings = @((Invoke-RestMethod -Method GET -Uri 'https://api.fabric.microsoft.com/v1/admin/tenantsettings' -Headers $fabricHeaders).tenantSettings)
        # Found by name, else by title: Microsoft renames tenant settings now and then.
        $setting = @($settings | Where-Object settingName -eq 'AllowServicePrincipalsUseReadAdminAPIs') + @($settings | Where-Object { "$($_.title)" -match 'service principals can (use|access) read-only admin' }) |
            Select-Object -First 1
        if (-not $setting) { throw 'Fabric does not list the setting' }
        function ConvertTo-GroupList($Entries) { @(foreach ($entry in @($Entries)) { $id = if ($entry.graphId) { $entry.graphId } else { $entry.id }; if ($id) { @{ graphId = $id; name = $entry.name } } }) }
        # Fabric keeps listing deleted groups, then answers 400 to an update that names them: only live groups stay.
        function Select-LiveGroup($Groups) {
            if (@($Groups).Count -eq 0) { return @() }
            $live = @(for ($i = 0; $i -lt @($Groups).Count; $i += 1000) {
                (Invoke-Graph POST '/directoryObjects/getByIds' @{ ids = @(@($Groups)[$i..([Math]::Min($i + 999, @($Groups).Count - 1))].graphId); types = @('group') }).value.id
            })
            @($Groups | Where-Object { $live -contains $_.graphId })
        }
        $enabledGroups = @(ConvertTo-GroupList $setting.enabledSecurityGroups)
        # On for the whole organization, for the group, or for a group the scan identity is in (Fabric follows nesting).
        $covered = $setting.enabled -and (-not $setting.canSpecifySecurityGroups -or $enabledGroups.Count -eq 0 -or ($powerBiGroup -and $enabledGroups.graphId -contains $powerBiGroup.id))
        if (-not $covered -and $setting.enabled) {
            $covered = @((Invoke-Graph POST "/directoryObjects/$($scan.id)/checkMemberGroups" @{ groupIds = @($enabledGroups.graphId | Select-Object -First 20) }).value).Count -gt 0
        }
        if ($covered) { Write-Step $setting.title 'ok' }
        elseif ($Audit) { Write-Step $setting.title 'missing'; $manual.Add($byHand) }
        elseif (-not $powerBiGroup) { Write-Step "$($setting.title): the group M365Permissions scanners does not exist (-Only PowerBiGroup makes it)" 'missing'; $manual.Add($byHand) }
        else {
            # An update replaces the whole setting: the live groups it lists stay (also while it is off) and this group
            # is added. @() keeps one group a list in the JSON.
            $body = @{ enabled = $true }
            $enabledGroups = @(Select-LiveGroup @($enabledGroups | Where-Object graphId -ne $powerBiGroup.id))
            if ($setting.canSpecifySecurityGroups) {
                $body.enabledSecurityGroups = $enabledGroups + @(@{ graphId = $powerBiGroup.id; name = $powerBiGroup.displayName })
            }
            $excluded = @(Select-LiveGroup @(ConvertTo-GroupList $setting.excludedSecurityGroups))
            if ($excluded.Count -gt 0) { $body.excludedSecurityGroups = $excluded }
            if ($null -ne $setting.delegateToWorkspace) { $body.delegateToWorkspace = $setting.delegateToWorkspace }
            $json = $body | ConvertTo-Json -Depth 5 -Compress
            # Fabric answers 400 to a group it does not know yet: a group made in the last minutes is tried again.
            $newGroup = try { ([datetimeoffset]::UtcNow - [datetimeoffset]$powerBiGroup.createdDateTime).TotalMinutes -lt 30 } catch { $false }
            # The update often answers a passing 429 or 5xx.
            for ($attempt = 1; ; $attempt++) {
                try {
                    Invoke-RestMethod -Method POST -Uri "https://api.fabric.microsoft.com/v1/admin/tenantsettings/$($setting.settingName)/update" -Headers $fabricHeaders `
                        -Body $json -ContentType 'application/json' | Out-Null
                    break
                }
                catch {
                    $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                    $unknownGroup = $status -eq 400 -and $newGroup
                    if ($attempt -ge 5 -or ($status -notin 429, 500, 502, 503, 504 -and -not $unknownGroup)) {
                        if ($unknownGroup) { $script:fabricGroupUnknown = $true }
                        throw
                    }
                    if ($unknownGroup) {
                        if ($attempt -eq 1) { Write-Host '  Fabric does not know the new group yet: trying again for up to two minutes.' -ForegroundColor DarkGray }
                        Start-Sleep -Seconds 30
                    }
                    else { Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(3, $attempt))) }
                }
            }
            $others = @($enabledGroups | Where-Object graphId -ne $powerBiGroup.id).Count
            Write-Step "$($setting.title)$(if ($others) { " (also kept for $others other group$(if ($others -ne 1) { 's' }))" }) (Fabric applies it within 15 minutes)" 'added'
        }
    }
    catch {
        # Fabric names the field it refused in the body, not in the status line.
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $problem = Get-SignInProblem $_
        if ($problem) { Write-SignInSkip 'Fabric setting' 'Fabric' $problem 'PowerBiSetting' $byHand }
        elseif ($script:fabricGroupUnknown) {
            Write-Step "Fabric setting: Fabric does not know the group M365Permissions scanners yet (it was made minutes ago). Run this step again in a few minutes: $(Get-StepCommand 'PowerBiSetting')" 'failed'
            $manual.Add($byHand)
        }
        elseif ($detail -match 'UserNotLicensed') {
            Write-Step "Fabric setting: this account has no Fabric license yet. Sign in once at https://app.fabric.microsoft.com (that gives it the free one), then run this step again: $(Get-StepCommand 'PowerBiSetting')" 'failed'
            $manual.Add($byHand)
        }
        else {
            Write-Step "Fabric setting: $(if ("$_" -match '401|403|Unauthorized|Forbidden') { 'only a Fabric administrator can change it' } else { $detail })" 'failed'
            $manual.Add($byHand)
        }
    }
}

# "name (resource group x, subscription y)" of an Azure resource id.
function Format-AzureResource([string]$Id) {
    $parts = $Id -split '/'
    "$($parts[-1]) (resource group $($parts[4]), subscription $($parts[2]))"
}

# A role for the scan identity on one resource of the customer's (any subscription of the tenant), and nothing wider.
function Grant-ResourceRole([string]$Scope, [string]$RoleId, [string]$Label, [string]$ByHand, [string]$Added, [string]$What, [string]$Step) {
    try {
        $roleHeaders = @{ Authorization = "Bearer $(Get-Token 'https://management.azure.com/')" }
        $assignments = "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments"
        $existing = @((Invoke-RestMethod -Method GET -Uri "$($assignments)?api-version=2022-04-01&`$filter=principalId eq '$($scan.id)'" -Headers $roleHeaders).value |
            Where-Object { $_.properties.scope -eq $Scope -and $_.properties.roleDefinitionId -like "*/$RoleId" })
        if ($existing) { Write-Step $Label 'ok' }
        elseif ($Audit) { Write-Step $Label 'missing'; $manual.Add($ByHand) }
        else {
            # The role definition of the resource's own subscription.
            $subscription = ($Scope -split '/')[0..2] -join '/'
            Invoke-RestMethod -Method PUT -Uri "$assignments/$([guid]::NewGuid())?api-version=2022-04-01" -Headers $roleHeaders -ContentType 'application/json' -Body (@{
                properties = @{ roleDefinitionId = "$subscription/providers/Microsoft.Authorization/roleDefinitions/$RoleId"; principalId = $scan.id; principalType = 'ServicePrincipal' }
            } | ConvertTo-Json -Depth 4 -Compress) | Out-Null
            Write-Step "$Label ($Added)" 'added'
        }
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Step "$($Label): $(if ($detail -match 'AuthorizationFailed|403') { "this account may not assign roles on $What $(Format-AzureResource $Scope). An Owner or User Access Administrator of it runs: $(Get-StepCommand $Step)" } else { $detail })" 'failed'
        $manual.Add($ByHand)
    }
}

# ARM's guid(): UUID version 5 of the arguments joined with '-' (UTF-8), in ARM's own namespace.
function Get-ArmGuid([string[]]$Values) {
    $space = [guid]'11fb06fb-712d-4ddd-98c7-e71bbd588830'
    # Network byte order for the namespace and the result: .NET keeps the first three fields little-endian.
    function Switch-Order([byte[]]$Bytes) { [array]::Reverse($Bytes, 0, 4); [array]::Reverse($Bytes, 4, 2); [array]::Reverse($Bytes, 6, 2); $Bytes }
    $data = [byte[]](@(Switch-Order $space.ToByteArray()) + [Text.Encoding]::UTF8.GetBytes($Values -join '-'))
    $hash = [byte[]][Security.Cryptography.SHA1]::HashData($data)[0..15]
    $hash[6] = ($hash[6] -band 0x0F) -bor 0x50
    $hash[8] = ($hash[8] -band 0x3F) -bor 0x80
    [guid]::new([byte[]](Switch-Order $hash)).ToString()
}

# A deployment of your own: the web identity's Website Contributor on the instance's resource group, which App Service
# managed certificates of a custom domain need where the instance's worker does not secure the domain itself
# (main.bicep certificateGrant, same name so a redeployment matches). Not on Marketplace (the worker secures it there);
# hosted: JSolve's plan. Never throws.
function Grant-CertificateRight {
    if ($ManagedApplicationId -or $hosted -or $fix -or -not $WebIdentityPrincipalId) { return }
    Write-Host "`nCustom domain: the web identity may create App Service managed certificates"
    $role = 'de139f84-1756-47ae-9be6-808fbbe84772'
    $webHost = ([uri]$WebUrl).Host
    $label = $null; $byHand = $null # not the caller's
    try {
        # Any of its host names: the default one, or a custom domain given as -WebUrl.
        $query = "resources | where type =~ 'microsoft.web/sites' | mv-expand hostName = properties.hostNames | where tostring(hostName) =~ '$($webHost -replace "'", '')' | project id, serverFarmId = tostring(properties.serverFarmId), identity | take 1"
        $site = @((Invoke-Arm POST '/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' @{ query = $query }).data) | Select-Object -First 1
        if (-not $site) { Write-Step "Website Contributor for the web identity: the web app $webHost is not in a subscription this account can read" 'skipped'; return }
        $siteGroup = ($site.id -split '/')[0..4] -join '/'
        if (-not $site.serverFarmId -or (($site.serverFarmId -split '/')[0..4] -join '/') -ne $siteGroup) {
            Write-Step 'Website Contributor for the web identity: the App Service plan is in another resource group (a shared plan), so it is not given here' 'skipped'; return
        }
        # The identity's id as the deployment wrote it into the app settings, else as the site lists it.
        $identityId = $null
        try { $identityId = "$((Invoke-Arm POST "$($site.id)/config/appsettings/list?api-version=2023-12-01").properties.M365P__ControlPlane__WebIdentityResourceId)" } catch { Write-Verbose "$_" }
        if (-not $identityId) {
            $identityId = @($site.identity.userAssignedIdentities.PSObject.Properties | Where-Object { "$($_.Value.principalId)" -eq $WebIdentityPrincipalId } | ForEach-Object Name) | Select-Object -First 1
        }
        if (-not $identityId) { Write-Step "Website Contributor for the web identity: the web app $webHost does not carry the web identity $WebIdentityPrincipalId" 'skipped'; return }
        $group = ($identityId -split '/')[0..4] -join '/'
        $label = "Website Contributor on resource group $(($group -split '/')[4]) for the web identity (custom domain certificates)"
        $byHand = "az role assignment create --assignee-object-id $WebIdentityPrincipalId --assignee-principal-type ServicePrincipal --role `"Website Contributor`" --scope $group"
        $existing = @((Invoke-Arm GET "$group/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId eq '$WebIdentityPrincipalId'").value |
            Where-Object { $_.properties.scope -eq $group -and $_.properties.roleDefinitionId -like "*/$role" })
        if ($existing) { Write-Step $label 'ok'; return }
        if ($Audit) { Write-Step $label 'missing'; $manual.Add($byHand); return }
        $name = Get-ArmGuid @($group, $identityId, $role)
        try {
            Invoke-Arm PUT "$group/providers/Microsoft.Authorization/roleAssignments/$($name)?api-version=2022-04-01" @{
                properties = @{ roleDefinitionId = "$(($group -split '/')[0..2] -join '/')/providers/Microsoft.Authorization/roleDefinitions/$role"; principalId = $WebIdentityPrincipalId; principalType = 'ServicePrincipal' }
            } | Out-Null
        }
        catch { if ([int]$_.Exception.Response.StatusCode -ne 409 -and "$($_.ErrorDetails.Message) $_" -notmatch 'RoleAssignmentExists') { throw } }
        Write-Step $label 'added'
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if (-not $label) { $label = 'Website Contributor for the web identity (custom domain certificates)' }
        Write-Step "$($label): $(if ($status -eq 403 -or $detail -match 'AuthorizationFailed') { 'this account may not assign roles there (an Owner or User Access Administrator may)' } else { $detail })" 'failed'
        if ($byHand) { $manual.Add($byHand) }
    }
}

if ($PeerVirtualNetworkId -and (Test-Step 'Network')) {
    Write-Host "`nNetwork: the instance may peer with your virtual network"
    Grant-ResourceRole -Scope $PeerVirtualNetworkId -RoleId '4d97b98b-1d4f-4787-a291-c67834d212e7' -Label 'Network Contributor on your virtual network for the scan identity' `
        -ByHand "Azure portal > virtual network $(Format-AzureResource $PeerVirtualNetworkId) > Access control (IAM): Network Contributor for the M365Permissions scan identity ($($scan.id))" `
        -Added 'the instance peers within a few minutes; without allowed IP ranges it then closes to the internet' -What 'virtual network' -Step 'Network'
}

if ($PrivateDnsZoneId -and (Test-Step 'DnsZone')) {
    Write-Host "`nNetwork: the instance keeps its two records in your private DNS zone"
    Grant-ResourceRole -Scope $PrivateDnsZoneId -RoleId 'b12aa53e-6015-4669-85d0-8515ebb3ae7f' -Label 'Private DNS Zone Contributor on your privatelink.azurewebsites.net zone for the scan identity' `
        -ByHand "Azure portal > private DNS zone $(Format-AzureResource $PrivateDnsZoneId) > Access control (IAM): Private DNS Zone Contributor for the M365Permissions scan identity ($($scan.id))" `
        -Added 'the instance writes the A records of its web app and scm name only, within a few minutes' -What 'private DNS zone' -Step 'DnsZone'
}

if (Test-Step 'PowerPlatformApp') {
    Write-Host "`nPower Platform: the scan identity as a management app (environments, apps and flows)"
    Write-DelegatedNote 'PowerPlatformApp'
    $label = 'Power Platform management app registration'
    $byHand = 'Power Platform: a Power Platform administrator runs this command with -Only PowerPlatformApp'
    try {
        # The admin API behind New-PowerAppManagementApp, without its Windows-only module.
        $bapHeaders = @{ Authorization = "Bearer $(Get-Token 'https://service.powerapps.com/' 'Power Platform')" }
        $bap = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/adminApplications'
        $registered = @((Invoke-RestMethod -Method GET -Uri "$($bap)?api-version=2020-10-01" -Headers $bapHeaders).value |
            Where-Object { $_.applicationId -eq $scan.appId -or $_.name -eq $scan.appId })
        if ($registered) { Write-Step $label 'ok' }
        elseif ($Audit) { Write-Step $label 'missing'; $manual.Add($byHand) }
        else {
            Invoke-RestMethod -Method PUT -Uri "$bap/$($scan.appId)?api-version=2020-10-01" -Headers $bapHeaders | Out-Null
            Write-Step $label 'added'
        }
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $problem = Get-SignInProblem $_
        if ($problem) { Write-SignInSkip $label 'Power Platform' $problem 'PowerPlatformApp' $byHand }
        else {
            Write-Step "$($label): $(if ("$_" -match '401|403|Unauthorized|Forbidden') { 'needs a Power Platform administrator' } else { $detail })" 'failed'
            $manual.Add($byHand)
        }
    }
}

# What each app role of the sign-in app may do, as Entra shows it. Web/Security/Auth.cs (Policies) is the rule.
$roleTexts = @{
    Admin   = 'Everything; the only role that changes settings'
    Auditor = 'Everything except changing settings: reports, risk decisions, remediation scripts, scans, audit log, viewing settings and the API'
    Reader  = 'Reads all reports, searches, graph, score, risk queue and Explore, with exports. No decisions, scans, settings, audit log or API page'
    Self    = 'Only their own access'
    Reviewer = 'Reviews the access of the locations they are asked to review, and nothing else'
    Staff   = 'Signs in only: MSP staff who open the customer tenants an Admin assigns them in M365Permissions'
}
# Every role in the order the app lists them; Self, Reviewer and Staff are for people (and groups) only.
$roleOrder = @('Admin', 'Auditor', 'Reader', 'Self', 'Reviewer', 'Staff')
$peopleOnlyRoles = @('Self', 'Reviewer', 'Staff')

function ConvertTo-AppRole([string]$Value) {
    $types = if ($Value -in $peopleOnlyRoles) { @('User') } else { @('User', 'Application') }
    @{ id = [guid]::NewGuid().ToString(); value = $Value; displayName = $Value; description = $roleTexts[$Value]; allowedMemberTypes = @($types); isEnabled = $true }
}

# Brings the texts of an existing sign-in app up to date. Ids and values stay, so existing assignments keep working.
# An app found by its tag or address is adopted only when it is this script's: anyone who can read the deployment knows
# the tag, and anyone can register an address. A secret or certificate, or an owner who is not a Global Administrator,
# means someone else made it. Returns why, or nothing.
function Get-ForeignReason([string]$AppObjectId) {
    $found = Invoke-Graph GET "/applications/$($AppObjectId)?`$select=appId,passwordCredentials,keyCredentials"
    if (@($found.passwordCredentials).Count -or @($found.keyCredentials).Count) {
        return "App $($found.appId) has a secret or certificate, which this script never adds: delete it, then run this again"
    }
    # The scan identity is an owner by design (Add-ScanOwner).
    $others = @((Invoke-Graph GET "/applications/$AppObjectId/owners?`$select=id").value | ForEach-Object id | Where-Object { $_ -ne $me.id -and $_ -ne $scan.id })
    if (-not $others) { return }
    $admins = @((Invoke-Graph GET "/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '62e90394-69f5-4237-9190-012177145e10'").value |
        Where-Object { $_.directoryScopeId -eq '/' } | ForEach-Object principalId)
    $others = @($others | Where-Object { $_ -notin $admins })
    foreach ($principal in $admins) {
        if (-not $others) { break }
        try { $members = @((Invoke-Graph GET "/groups/$principal/transitiveMembers?`$select=id").value | ForEach-Object id) } catch { continue } # a user, not a group
        $others = @($others | Where-Object { $_ -notin $members })
    }
    if ($others) { "App $($found.appId) has an owner who is not a Global Administrator ($($others -join ', ')), so this script did not make it: delete it, then run this again" }
}

# Adds the roles an existing sign-in app lacks (a role of a newer version, with a new id) and brings the descriptions up
# to date. The ids and values of the roles it has stay, so existing assignments keep working. Returns whether it changed.
function Sync-RoleText($App) {
    $stale = @($App.appRoles | Where-Object { $roleTexts[$_.value] -and $_.description -cne $roleTexts[$_.value] })
    $present = @($App.appRoles | ForEach-Object value)
    $added = @($roleOrder | Where-Object { $_ -cnotin $present } | ForEach-Object { ConvertTo-AppRole $_ })
    if (-not $stale -and -not $added) { return $false }
    foreach ($role in $stale) { $role.description = $roleTexts[$role.value] }
    Invoke-Graph PATCH "/applications/$($App.id)" @{ appRoles = @(@($App.appRoles) + $added) } | Out-Null
    $true
}

# Tokens carry the groups assigned to the sign-in app (MSP staff assigned to customer tenants as a group, docs/msp.md 4.2);
# only those, so the token never overflows. An app that has a groups setting of its own keeps it. Returns whether it changed.
function Sync-GroupClaim($App) {
    if ($App.groupMembershipClaims -and $App.groupMembershipClaims -ne 'None') { return $false }
    Invoke-Graph PATCH "/applications/$($App.id)" @{ groupMembershipClaims = 'ApplicationGroup' } | Out-Null
    $true
}

# Makes the scan identity an owner of one of the instance's app registrations: with Application.ReadWrite.OwnedBy the
# instance then keeps its addresses up to date itself (a custom domain). Never throws: a failure is left for an admin.
function Add-ScanOwner([string]$AppObjectId, [string]$Label, [string]$AppName) {
    try {
        $owners = @((Invoke-Graph GET "/applications/$AppObjectId/owners?`$select=id").value | ForEach-Object id)
        if ($owners -contains $scan.id) { Write-Step $Label 'ok'; return }
        if ($Audit) { Write-Step $Label 'missing'; $missing.Add($Label); return }
        try { Invoke-Graph POST "/applications/$AppObjectId/owners/`$ref" @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($scan.id)" } | Out-Null }
        catch { if ("$($_.ErrorDetails.Message) $_" -notmatch 'already exist') { throw } }
        Write-Step $Label 'added'
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Step "$($Label): $detail" 'failed'
        $manual.Add("Entra admin center > App registrations > $AppName > Owners > Add owners: the M365Permissions scan identity (object id $($scan.id))")
    }
}

if (-not $fix) {
    Write-Host "`nSign-in app"
    $app = $null
    $sp = $null
    if ($SetupCode) {
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SetupCode))).ToLowerInvariant()
        $tag = "m365p-setup-$hash"
        $app = (Invoke-Graph GET "/applications?`$filter=tags/any(t:t eq '$tag')&`$count=true&`$select=id,appId,displayName,appRoles,groupMembershipClaims" -Advanced).value | Select-Object -First 1
    }
    elseif (-not $hosted) {
        $app = (Invoke-Graph GET "/applications?`$filter=web/redirectUris/any(u:u eq 'https://$host_/signin-oidc')&`$count=true&`$select=id,appId,displayName,appRoles,groupMembershipClaims" -Advanced).value |
            Select-Object -First 1
    }
    $graph = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$graphApp'&`$select=id,oauth2PermissionScopes").value[0]
    $foreign = if ($app) { Get-ForeignReason $app.id }
    if ($foreign) {
        Write-Step $foreign 'missing'; $missing.Add('sign-in app'); $app = $null
    }
    elseif ($hosted) {
        # The instance's sign-in app (JSolve's, or the MSP's) trusts only its web identity: here its enterprise app, consent and your role.
        $sp = Get-EnterpriseApp $SignInAppId 'Sign-in app' $true
    }
    elseif (-not $app -and -not $SetupCode) { Write-Step 'No sign-in app found; run the setup command with -SetupCode from the deployment outputs' 'missing'; $missing.Add('sign-in app') }
    elseif (-not $app -and $Audit) { Write-Step 'Sign-in app' 'missing'; $missing.Add('sign-in app') }
    elseif (-not $app) {
        $access = $signInScopes.Split(' ') | ForEach-Object { $scope = $_; @{ id = ($graph.oauth2PermissionScopes | Where-Object value -eq $scope).id; type = 'Scope' } }
        $app = Invoke-Graph POST '/applications' @{
            displayName            = "M365Permissions sign-in ($host_)"
            signInAudience         = 'AzureADMyOrg'
            tags                   = @($tag)
            web                    = @{ redirectUris = @("https://$host_/signin-oidc"); logoutUrl = "https://$host_/signout-callback-oidc"
                implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false } }
            api                    = @{ requestedAccessTokenVersion = 2 }
            appRoles               = @($roleOrder | ForEach-Object { ConvertTo-AppRole $_ })
            groupMembershipClaims  = 'ApplicationGroup'
            requiredResourceAccess = @(@{ resourceAppId = $graphApp; resourceAccess = @($access) })
        }
        Invoke-Graph PATCH "/applications/$($app.id)" @{ identifierUris = @("api://$($app.appId)") } | Out-Null
        Write-Step "Created $($app.displayName) ($($app.appId))" 'added'
    }
    if ($app) {
        if (-not $Audit -and (Sync-RoleText $app)) { Write-Step 'Roles and their descriptions' 'added' }
        if (-not $Audit -and (Sync-GroupClaim $app)) { Write-Step 'Groups assigned to the app in its tokens (in-app assignments to groups)' 'added' }
        $issuer = "https://login.microsoftonline.com/$tenantId/v2.0"
        $credentials = (Invoke-Graph GET "/applications/$($app.id)/federatedIdentityCredentials").value
        if ($credentials | Where-Object { $_.issuer -eq $issuer -and $_.subject -eq $WebIdentityPrincipalId }) { Write-Step 'Federated credential for the web identity' 'ok' }
        elseif ($Audit) { Write-Step 'Federated credential for the web identity' 'missing'; $missing.Add('federated credential') }
        else {
            Invoke-Graph POST "/applications/$($app.id)/federatedIdentityCredentials" @{
                name = 'm365permissions-web'; issuer = $issuer; subject = $WebIdentityPrincipalId; audiences = @('api://AzureADTokenExchange')
                description = 'Sign-in with the web app''s managed identity, no secret'
            } | Out-Null
            Write-Step 'Federated credential for the web identity' 'added'
        }
        $sp = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$($app.appId)'&`$select=id,appRoles").value | Select-Object -First 1
        if (-not $sp -and -not $Audit) {
            $sp = Invoke-Graph POST '/servicePrincipals' @{ appId = $app.appId; appRoleAssignmentRequired = $true; tags = @($listedTag) }
            Write-Step 'Enterprise app, assignment required' 'added'
        }
        Add-ScanOwner $app.id 'Scan identity as owner of the sign-in app (it keeps the custom domain addresses up to date)' $app.displayName
        # The AI clients app, when it exists; the AI assistant step below does this itself.
        if (-not $mcpStep) {
            $ownedClient = (Invoke-Graph GET "/applications?`$filter=tags/any(t:t eq 'm365p-mcp-clients-$host_')&`$count=true&`$select=id,appId,displayName" -Advanced).value | Select-Object -First 1
            if ($ownedClient -and -not (Get-ForeignReason $ownedClient.id)) { Add-ScanOwner $ownedClient.id "Scan identity as owner of $($ownedClient.displayName)" $ownedClient.displayName }
        }
    }
    if ($sp) {
        $consent = (Invoke-Graph GET "/oauth2PermissionGrants?`$filter=clientId eq '$($sp.id)' and consentType eq 'AllPrincipals'").value
        if ($consent) { Write-Step 'Consent for sign-in' 'ok' }
        elseif (-not $Audit) {
            Invoke-Graph POST '/oauth2PermissionGrants' @{ clientId = $sp.id; consentType = 'AllPrincipals'; resourceId = $graph.id; scope = $signInScopes } | Out-Null
            Write-Step 'Consent for sign-in' 'added'
        }
        $admin = ($app.appRoles + $sp.appRoles | Where-Object value -eq 'Admin' | Select-Object -First 1).id
        $assigned = if ($callerMember) { (Invoke-Graph GET "/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$top=999").value | Where-Object { $_.principalId -eq $me.id -and $_.appRoleId -eq $admin } }
        # An account of another tenant (an MSP's delegated admin) gets no role: the customer assigns their own staff.
        if (-not $callerMember) { Write-Step "No role for $($me.userPrincipalName) (not a member of this tenant): an admin of this tenant assigns roles in the enterprise app of the sign-in app ($(if ($sp.displayName) { $sp.displayName } else { $sp.appId }))" 'note' }
        elseif ($assigned) { Write-Step "Admin for $($me.userPrincipalName)" 'ok' }
        elseif (-not $Audit) {
            Invoke-Graph POST "/servicePrincipals/$($sp.id)/appRoleAssignedTo" @{ principalId = $me.id; resourceId = $sp.id; appRoleId = $admin } | Out-Null
            Write-Step "Admin for $($me.userPrincipalName)" 'added'
        }
    }
}

# AI assistant access (-EnableMcp, or -Only Mcp; docs/api/mcp.md). On the sign-in app: the delegated scope MCP.Read, the
# identifier URI of the instance's /mcp address (clients ask Entra for that resource) and Visual Studio Code pre-authorised.
# The public client app "M365Permissions AI clients" for Claude Code and Claude, with admin consent. Nothing else changes.
if ($mcpStep) {
    Write-Host "`nAI assistants (MCP)"
    $mcpUri = "https://$host_/mcp"
    $mcpScope = 'MCP.Read'
    $vsCodeApp = 'aebc6443-996d-45c2-90f0-388ff96faa56'
    $mcpRedirects = @('http://localhost:41730/callback', 'http://127.0.0.1:41730/callback', 'https://claude.ai/api/mcp/auth_callback',
        'https://claude.com/api/mcp/auth_callback', "https://$host_/settings/ai-assistants")
    $oidcScopes = 'openid profile offline_access'
    # A change to an app Entra has just changed can be refused for a short while: tried again.
    function Invoke-McpChange([string]$Method, [string]$Path, $Body) {
        for ($attempt = 1; ; $attempt++) {
            try { return Invoke-Graph $Method $Path $Body }
            catch {
                if ($attempt -lt 6 -and "$($_.ErrorDetails.Message) $_" -match 'concurrently|cannot be found|valid application object') { Start-Sleep -Seconds (5 * $attempt); continue }
                throw
            }
        }
    }
    $registration = $null
    $select = '$select=id,appId,displayName,identifierUris,api,signInAudience'
    if ($app) { $registration = Invoke-Graph GET "/applications/$($app.id)?$select" }
    elseif ($SignInAppId) { $registration = (Invoke-Graph GET "/applications?`$filter=appId eq '$SignInAppId'&$select").value | Select-Object -First 1 }
    elseif ($SetupCode) {
        $mcpTag = "m365p-setup-$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SetupCode))).ToLowerInvariant())"
        $registration = (Invoke-Graph GET "/applications?`$filter=tags/any(t:t eq '$mcpTag')&`$count=true&$select" -Advanced).value | Select-Object -First 1
    }
    else {
        $registration = (Invoke-Graph GET "/applications?`$filter=web/redirectUris/any(u:u eq 'https://$host_/signin-oidc')&`$count=true&$select" -Advanced).value | Select-Object -First 1
    }
    if ($registration -and -not $app -and ($foreign = Get-ForeignReason $registration.id)) { Write-Step $foreign 'missing'; $missing.Add('sign-in app'); $registration = $null; $SignInAppId = $null }
    $signInId = if ($registration) { $registration.appId } else { $SignInAppId }
    $signInSp = if ($signInId) { (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$signInId'&`$select=id,appId,oauth2PermissionScopes,servicePrincipalNames").value | Select-Object -First 1 }
    $scopeId = $null
    if (-not $signInSp) { Write-Step 'No sign-in app found: run the setup command of the deployment first' 'missing'; $missing.Add('sign-in app') }
    elseif ($registration) {
        $api = $registration.api
        $scope = @($api.oauth2PermissionScopes) | Where-Object { $_.value -eq $mcpScope } | Select-Object -First 1
        if ($scope) { Write-Step "Scope $mcpScope" 'ok' }
        elseif ($Audit) { Write-Step "Scope $mcpScope" 'missing'; $missing.Add("scope $mcpScope") }
        else {
            $scope = [pscustomobject]@{
                id = [guid]::NewGuid().ToString(); value = $mcpScope; type = 'Admin'; isEnabled = $true
                adminConsentDisplayName = 'Read M365Permissions data for an AI assistant'
                adminConsentDescription = 'Lets an AI assistant read M365Permissions data as the signed-in user. It cannot change anything.'
            }
            Invoke-McpChange PATCH "/applications/$($registration.id)" @{ api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = @(@($api.oauth2PermissionScopes) + $scope | Where-Object { $_ })
                    preAuthorizedApplications = @($api.preAuthorizedApplications | Where-Object { $_ }); knownClientApplications = @($api.knownClientApplications | Where-Object { $_ }) } } | Out-Null
            Write-Step "Scope $mcpScope" 'added'
        }
        $scopeId = $scope.id
        # Entra accepts an https address of a host it has not verified only on a single-tenant app with v2 tokens (checked live).
        if (@($registration.identifierUris) -contains $mcpUri) { Write-Step "Identifier URI $mcpUri" 'ok' }
        elseif ($registration.signInAudience -and $registration.signInAudience -ne 'AzureADMyOrg' -and $host_ -like '*.azurewebsites.net') {
            # An MSP instance: the instance puts the address on its custom domain (Settings, AI assistants).
            Write-Step "Identifier URI $($mcpUri): the sign-in app is multi-tenant, where Entra takes it only on a custom domain; M365Permissions adds https://<custom domain>/mcp itself" 'skipped'
        }
        elseif ($Audit) { Write-Step "Identifier URI $mcpUri" 'missing'; $missing.Add("identifier URI $mcpUri") }
        else {
            Invoke-McpChange PATCH "/applications/$($registration.id)" @{ identifierUris = @(@($registration.identifierUris) + $mcpUri | Where-Object { $_ }) } | Out-Null
            Write-Step "Identifier URI $mcpUri" 'added'
        }
        $pre = @($api.preAuthorizedApplications | Where-Object { $_ })
        if ($pre | Where-Object { $_.appId -eq $vsCodeApp -and @($_.delegatedPermissionIds) -contains $scopeId }) { Write-Step 'Visual Studio Code pre-authorised' 'ok' }
        elseif ($Audit) { Write-Step 'Visual Studio Code pre-authorised' 'missing'; $missing.Add('Visual Studio Code pre-authorised') }
        else {
            $scopes = @(@($api.oauth2PermissionScopes) + $scope | Where-Object { $_ } | Sort-Object id -Unique)
            $entry = [pscustomobject]@{ appId = $vsCodeApp; delegatedPermissionIds = @(@($pre | Where-Object appId -eq $vsCodeApp | ForEach-Object { $_.delegatedPermissionIds }) + $scopeId | Select-Object -Unique) }
            Invoke-McpChange PATCH "/applications/$($registration.id)" @{ api = @{ requestedAccessTokenVersion = 2; oauth2PermissionScopes = $scopes
                    preAuthorizedApplications = @(@($pre | Where-Object appId -ne $vsCodeApp) + $entry); knownClientApplications = @($api.knownClientApplications | Where-Object { $_ }) } } | Out-Null
            Write-Step 'Visual Studio Code pre-authorised' 'added'
        }
    }
    else {
        # Hosted: the sign-in app is JSolve's; its scope and the address are JSolve's part.
        $scopeId = (@($signInSp.oauth2PermissionScopes) | Where-Object { $_.value -eq $mcpScope } | Select-Object -First 1).id
        foreach ($check in @(@("Scope $mcpScope", [bool]$scopeId), @("Identifier URI $mcpUri", (@($signInSp.servicePrincipalNames) -contains $mcpUri)))) {
            if ($check[1]) { Write-Step $check[0] 'ok' } else { Write-Step "$($check[0]) (JSolve adds it to its sign-in app)" 'missing'; $missing.Add($check[0]) }
        }
    }

    # -Audit also reports the client app while the scope is still missing.
    if ($signInSp -and ($scopeId -or $Audit)) {
        $graphSp = (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$graphApp'&`$select=id,oauth2PermissionScopes").value[0]
        $access = @(
            @{ resourceAppId = $signInSp.appId; resourceAccess = @(@{ id = $scopeId; type = 'Scope' }) },
            @{ resourceAppId = $graphApp; resourceAccess = @($oidcScopes.Split(' ') | ForEach-Object { $name = $_; @{ id = ($graphSp.oauth2PermissionScopes | Where-Object value -eq $name).id; type = 'Scope' } }) })
        $clientTag = "m365p-mcp-clients-$host_"
        $client = (Invoke-Graph GET "/applications?`$filter=tags/any(t:t eq '$clientTag')&`$count=true&`$select=id,appId,displayName,publicClient,requiredResourceAccess,isFallbackPublicClient" -Advanced).value | Select-Object -First 1
        $clientName = "M365Permissions AI clients ($host_)"
        if ($client -and ($foreign = Get-ForeignReason $client.id)) { Write-Step $foreign 'missing'; $missing.Add('client app for AI assistants'); $client = $null }
        elseif (-not $client -and $Audit) { Write-Step "Client app $clientName" 'missing'; $missing.Add('client app for AI assistants') }
        elseif (-not $client) {
            $client = Invoke-Graph POST '/applications' @{
                displayName = $clientName; signInAudience = 'AzureADMyOrg'; tags = @($clientTag); isFallbackPublicClient = $true
                publicClient = @{ redirectUris = $mcpRedirects }; requiredResourceAccess = $access
                notes = 'AI assistants (Claude Code, Claude) sign in with this app to read M365Permissions. Public client: no secret. Made by the M365Permissions setup command.'
            }
            Write-Step "Created $clientName ($($client.appId))" 'added'
        }
        else {
            $redirects = @($client.publicClient.redirectUris)
            $wanted = @($mcpRedirects | Where-Object { $_ -notin $redirects })
            $resource = @($client.requiredResourceAccess) | Where-Object { $_.resourceAppId -eq $signInSp.appId }
            $hasScope = @($resource.resourceAccess) | Where-Object { $_.id -eq $scopeId }
            if (-not $wanted -and $hasScope -and $client.isFallbackPublicClient) { Write-Step "$clientName ($($client.appId))" 'ok' }
            elseif ($Audit) { Write-Step "$($clientName): redirect addresses or the scope" 'missing'; $missing.Add('client app settings') }
            else {
                $others = @(@($client.requiredResourceAccess) | Where-Object { $_ -and $_.resourceAppId -notin $signInSp.appId, $graphApp })
                Invoke-McpChange PATCH "/applications/$($client.id)" @{ isFallbackPublicClient = $true; publicClient = @{ redirectUris = @($redirects + $wanted | Where-Object { $_ }) }
                    requiredResourceAccess = @($others + $access) } | Out-Null
                Write-Step "$($clientName): redirect addresses and scope" 'added'
            }
        }
        if ($client) {
            if (-not $hosted) { Add-ScanOwner $client.id "Scan identity as owner of $clientName" $clientName }
            $clientSp =(Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$($client.appId)'&`$select=id").value | Select-Object -First 1
            if (-not $clientSp -and -not $Audit) { $clientSp = Invoke-McpChange POST '/servicePrincipals' @{ appId = $client.appId; appRoleAssignmentRequired = $false } }
            $held = if ($clientSp) { @((Invoke-Graph GET "/oauth2PermissionGrants?`$filter=clientId eq '$($clientSp.id)' and consentType eq 'AllPrincipals'").value) } else { @() }
            foreach ($grant in @(@($signInSp.id, $mcpScope, "Admin consent for $mcpScope"), @($graphSp.id, $oidcScopes, 'Admin consent for sign-in'))) {
                $existing = $held | Where-Object { $_.resourceId -eq $grant[0] } | Select-Object -First 1
                $lacking = @($grant[1].Split(' ') | Where-Object { $_ -notin "$($existing.scope)".Split(' ') })
                if (-not $lacking) { Write-Step $grant[2] 'ok' }
                elseif ($Audit) { Write-Step $grant[2] 'missing'; $missing.Add($grant[2]) }
                elseif ($existing) {
                    Invoke-Graph PATCH "/oauth2PermissionGrants/$($existing.id)" @{ scope = (@("$($existing.scope)".Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) + $lacking) -join ' ' } | Out-Null
                    Write-Step $grant[2] 'added'
                }
                else {
                    # A grant made moments ago may not show in the read yet: Entra then says it exists.
                    try {
                        Invoke-Graph POST '/oauth2PermissionGrants' @{ clientId = $clientSp.id; consentType = 'AllPrincipals'; resourceId = $grant[0]; scope = $grant[1] } | Out-Null
                        Write-Step $grant[2] 'added'
                    }
                    catch { if ("$($_.ErrorDetails.Message) $_" -match 'already exists') { Write-Step $grant[2] 'ok' } else { throw } }
                }
            }
            Write-Host "  Client app id for AI assistants: $($client.appId) (Settings, AI assistants in M365Permissions shows how to connect)"
        }
    }
}

# Custom domain (-Only CustomDomain or CustomDomainMcp, with -CustomDomain; docs/api/access.md section 6). CustomDomain: the
# sign-in app's redirect URIs on that host (sign-in and sign-out). CustomDomainMcp: the identifier URI of its /mcp address
# and the AI client app's consent landing there. -RemoveCustomDomain takes them off again. Nothing else changes.
if ($domainStep) {
    Write-Host "`nCustom domain $CustomDomain$(if ($RemoveCustomDomain) { ' (removing)' })"
    if (-not $CustomDomain) { throw '-Only CustomDomain needs -CustomDomain with the host name.' }
    $domainHost = $CustomDomain.ToLowerInvariant()
    $domainRedirects = @("https://$domainHost/signin-oidc", "https://$domainHost/signout-callback-oidc")
    # A change to an app Entra has just changed can be refused for a short while: tried again.
    function Invoke-DomainChange([string]$Method, [string]$Path, $Body) {
        for ($attempt = 1; ; $attempt++) {
            try { return Invoke-Graph $Method $Path $Body }
            catch {
                if ($attempt -lt 6 -and "$($_.ErrorDetails.Message) $_" -match 'concurrently|cannot be found|valid application object') { Start-Sleep -Seconds (5 * $attempt); continue }
                throw
            }
        }
    }
    # Sets a list to $Wanted with $Write, or with -Audit only reports that it differs.
    function Sync-DomainList([string]$Label, [object[]]$Current, [object[]]$Wanted, [scriptblock]$Write) {
        $Current = @($Current | Where-Object { $_ })
        $Wanted = @($Wanted | Where-Object { $_ })
        if (($Current -join "`n") -ceq ($Wanted -join "`n")) { Write-Step $Label 'ok'; return }
        if ($Audit) { Write-Step $Label 'missing'; $missing.Add($Label); return }
        & $Write $Wanted
        Write-Step $Label $(if ($RemoveCustomDomain) { 'removed' } else { 'added' })
    }
    $domainSelect = '$select=id,appId,displayName,identifierUris,web'
    $domainApp = $null
    if ($SignInAppId) { $domainApp = (Invoke-Graph GET "/applications?`$filter=appId eq '$SignInAppId'&$domainSelect").value | Select-Object -First 1 }
    elseif ($SetupCode) {
        $domainTag = "m365p-setup-$([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SetupCode))).ToLowerInvariant())"
        $domainApp = (Invoke-Graph GET "/applications?`$filter=tags/any(t:t eq '$domainTag')&`$count=true&$domainSelect" -Advanced).value | Select-Object -First 1
    }
    else { $domainApp = (Invoke-Graph GET "/applications?`$filter=web/redirectUris/any(u:u eq 'https://$host_/signin-oidc')&`$count=true&$domainSelect" -Advanced).value | Select-Object -First 1 }
    if ($domainApp -and ($foreign = Get-ForeignReason $domainApp.id)) { Write-Step $foreign 'missing'; $missing.Add('sign-in app'); $domainApp = $null }
    elseif (-not $domainApp -and $SignInAppId) { Write-Step "Redirect URIs on $domainHost (the sign-in app is JSolve's: JSolve adds them on request)" 'missing'; $missing.Add("redirect URIs on $domainHost") }
    elseif (-not $domainApp) { Write-Step 'No sign-in app found: run the setup command of the deployment first' 'missing'; $missing.Add('sign-in app') }
    if ($domainApp -and $Only -contains 'CustomDomain') {
        $current = @($domainApp.web.redirectUris)
        $wanted = if ($RemoveCustomDomain) { @($current | Where-Object { $_ -notin $domainRedirects }) } else { @($current) + @($domainRedirects | Where-Object { $_ -notin $current }) }
        Sync-DomainList "Redirect URIs on $domainHost" $current $wanted {
            param($List)
            # The web object goes back whole, so its sign-out address and settings stay as they were.
            $web = @{ redirectUris = @($List) }
            foreach ($name in 'logoutUrl', 'homePageUrl', 'implicitGrantSettings') { if ($null -ne $domainApp.web.$name) { $web[$name] = $domainApp.web.$name } }
            Invoke-DomainChange PATCH "/applications/$($domainApp.id)" @{ web = $web } | Out-Null
        }
    }
    if ($domainApp -and $Only -contains 'CustomDomainMcp') {
        $domainMcp = "https://$domainHost/mcp"
        $current = @($domainApp.identifierUris)
        $wanted = if ($RemoveCustomDomain) { @($current | Where-Object { $_ -ne $domainMcp }) } else { @($current) + @(@($domainMcp) | Where-Object { $_ -notin $current }) }
        Sync-DomainList "Identifier URI $domainMcp" $current $wanted { param($List) Invoke-DomainChange PATCH "/applications/$($domainApp.id)" @{ identifierUris = @($List) } | Out-Null }
        $landing = "https://$domainHost/settings/ai-assistants"
        $domainClient = (Invoke-Graph GET "/applications?`$filter=tags/any(t:t eq 'm365p-mcp-clients-$host_')&`$count=true&`$select=id,appId,publicClient" -Advanced).value | Select-Object -First 1
        if ($domainClient -and ($foreign = Get-ForeignReason $domainClient.id)) { Write-Step $foreign 'missing'; $missing.Add('client app for AI assistants') }
        elseif ($domainClient) {
            $current = @($domainClient.publicClient.redirectUris)
            $wanted = if ($RemoveCustomDomain) { @($current | Where-Object { $_ -ne $landing }) } else { @($current) + @(@($landing) | Where-Object { $_ -notin $current }) }
            Sync-DomainList "AI clients app: redirect URI $landing" $current $wanted { param($List) Invoke-DomainChange PATCH "/applications/$($domainClient.id)" @{ publicClient = @{ redirectUris = @($List) } } | Out-Null }
        }
        elseif (-not $RemoveCustomDomain) { Write-Step 'No client app for AI assistants yet: run -Only Mcp first' 'missing'; $missing.Add('client app for AI assistants') }
    }
}

# Exchange takes no Azure token (Microsoft blocks Azure PowerShell's and the CLI's: scp "blocked exoauthsec"), and
# Graph cannot make shared mailboxes or Exchange service principals, so this uses Exchange Online PowerShell itself:
# one sign-in per run, kept open to the end of the mail step, in this tenant (its own sign-in address, then checked). An
# existing connection to this tenant is used as it is. A failed sign-in is not asked for again in this run.
$exchangeConnected = $false
$script:exchangeFailure = $null
function Connect-Exchange {
    if ($script:exchangeFailure) { throw $script:exchangeFailure }
    if (-not (Get-Command Connect-ExchangeOnline -ErrorAction SilentlyContinue)) {
        Write-Host '  Installing ExchangeOnlineManagement for the current user.'
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
    }
    $open = Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' -and "$($_.TenantID)" -eq $tenantId } | Select-Object -First 1
    if ($open) { return }
    try {
        # A delegated (GDAP) admin connects to the customer's organisation from their own tenant.
        $connect = @{ UserPrincipalName = $me.userPrincipalName; ShowBanner = $false; ErrorAction = 'Stop' }
        if ($callerMember) { $connect.AzureADAuthorizationEndpointUri = "https://login.microsoftonline.com/$tenantId" } else { $connect.DelegatedOrganization = $tenantId }
        Connect-ExchangeOnline @connect
        $script:exchangeConnected = $true
        $connections = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' })
        if ($connections.Count -gt 0 -and -not ($connections | Where-Object { "$($_.TenantID)" -eq $tenantId })) {
            throw "Exchange Online signed in to tenant $(@($connections)[-1].TenantID), but this setup is for tenant $($tenantId): sign in with an account of tenant $tenantId"
        }
    }
    catch {
        $script:exchangeFailure = $_
        throw
    }
}

# One Exchange cmdlet with these parameters, through the connection above.
function Invoke-Exchange([string]$Cmdlet, [hashtable]$Parameters) {
    @(& $Cmdlet @Parameters -ErrorAction Stop)
}

# The objects a Get- cmdlet finds; none when Exchange does not know it.
function Find-Exchange([string]$Cmdlet, [hashtable]$Parameters) {
    try { @(Invoke-Exchange $Cmdlet $Parameters) }
    catch {
        if ("$_" -match "couldn't be found|could not be found|ManagementObjectNotFound|wasn't found") { return @() }
        throw
    }
}

# A tenant that never customised Exchange refuses a scope or role assignment until Enable-OrganizationCustomization ran
# once (Exchange's own text says so). It is run here, and the change tried again while Exchange applies it. Right after
# it, Exchange also refuses an application role assignment ("delegating role assignment", seen in p6zm 2026-11-16)
# until administrators' delegating assignments exist; without a recent switch that refusal means the account lacks them.
$script:customizationOn = $false
function Invoke-ExchangeChange([string]$Cmdlet, [hashtable]$Parameters) {
    for ($attempt = 1; ; $attempt++) {
        try { return Invoke-Exchange $Cmdlet $Parameters }
        catch {
            $text = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
            $again = "Run this step again later: $(Get-StepCommand 'MailSender')"
            if ($text -match 'delegating role assignment') {
                if (-not $script:customizationOn) {
                    throw "Exchange did not let this account assign $($Parameters.Role): that needs Organization Management in Exchange (Global Administrator or Exchange Administrator). Right after Enable-OrganizationCustomization Exchange refuses it for a while, even then. $again"
                }
                if ($attempt -ge 19) { throw "Exchange is still applying Enable-OrganizationCustomization and does not yet let administrators assign $($Parameters.Role). $again" }
                if ($attempt -eq 1) { Write-Host '  Exchange is applying the customisation; waiting up to 3 minutes for it.' }
            }
            elseif ($text -notmatch 'Enable-OrganizationCustomization') { throw }
            elseif (-not $script:customizationOn) {
                Invoke-Exchange 'Enable-OrganizationCustomization' @{} | Out-Null
                $script:customizationOn = $true
                Write-Step 'Exchange customisation switched on (Enable-OrganizationCustomization): Exchange asks for it once before it takes a scope' 'added'
            }
            elseif ($attempt -ge 7) { throw "Exchange is still applying Enable-OrganizationCustomization. $again" }
            Start-Sleep -Seconds 10
        }
    }
}

# One scope per scan identity: another instance or product in the tenant keeps its own (an older version shared
# 'M365Permissions-Sender', which the old product uses too; it is left alone).
$senderScope = "M365Permissions-Sender-$($scan.appId)"
$senderRole = 'Application Mail.Send'
function Get-SenderByHand {
    $address = if ($AlertSenderMailbox) { $AlertSenderMailbox } else { '<mailbox>' }
    @(
        "Mail alerts, in Exchange Online PowerShell (Connect-ExchangeOnline), with the primary address of the mailbox that sends them"
        "(when Exchange asks for it, first: Enable-OrganizationCustomization):"
        "    New-ServicePrincipal -AppId $($scan.appId) -ObjectId $($scan.id) -DisplayName 'M365Permissions scan identity'"
        "    New-ManagementScope -Name '$senderScope' -RecipientRestrictionFilter `"PrimarySmtpAddress -eq '$address'`""
        "    New-ManagementRoleAssignment -App $($scan.appId) -Role '$senderRole' -CustomResourceScope '$senderScope'"
        "    Test-ServicePrincipalAuthorization -Identity $($scan.appId) -Resource $address   (InScope True for $senderRole)"
    ) -join "`n  "
}
# Why an Exchange call failed, in words: a network that does not reach Exchange Online, a refused sign-in, or Exchange's own text.
function Get-ExchangeFailure($ErrorRecord) {
    $text = "$($ErrorRecord.ErrorDetails.Message) $($ErrorRecord.Exception.Message)"
    if ($text -match 'did not properly respond|failed to respond|timed out|actively refused|No such host|SocketException|NameResolution|network is unreachable') {
        return 'Exchange Online (outlook.office365.com) did not answer from this computer, while Microsoft Graph did: a network, VPN or firewall blocks it. Run this command again later or from another network, with -Only MailSender to do just this step'
    }
    if ($text -match '401|403|Unauthorized|Forbidden|not authorized') { return 'Exchange refused this sign-in (an Exchange administrator may run it, or do it by hand)' }
    if ($ErrorRecord.ErrorDetails.Message) { $ErrorRecord.ErrorDetails.Message } else { $ErrorRecord.Exception.Message }
}
# Something changed in Exchange: it applies that within 2 hours (Microsoft: 30 minutes to 2 hours).
$senderChanged = $false
# No mailbox given, or the given one does not exist: with a console, the end of the run offers a shared mailbox
# (Complete-MailSender). Created: made in this run. Settings: an address the deployment does not name, to set in
# Settings, E-mail alerts.
$canAskSender = -not $Audit -and (Test-InteractiveConsole)
$senderPlan = @{ Ask = $false; Created = $false; Settings = $null }

# Lets the scan identity send as $AlertSenderMailbox. Dot-sourced, so what it sets stays in the script's scope.
function Invoke-MailSenderStep {
    Write-Host "`nMail alerts: the scan identity may send as $AlertSenderMailbox, and as no other mailbox"
    Write-DelegatedNote 'MailSender'
    try {
        Connect-Exchange
        # A mailbox made just now can take a moment to show.
        $tries = if ($senderPlan.Created) { 6 } else { 1 }
        for ($attempt = 1; ; $attempt++) {
            $mailbox = @(Find-Exchange 'Get-Mailbox' @{ Identity = $AlertSenderMailbox }) | Select-Object -First 1
            if ($mailbox -or $attempt -ge $tries) { break }
            Start-Sleep -Seconds 5
        }
        if (-not $mailbox -and $canAskSender -and -not $senderPlan.Created) {
            Write-Step "There is no mailbox $AlertSenderMailbox yet: the end of this run offers to create it" 'note'
            $senderPlan.Ask = $true
            return
        }
        if (-not $mailbox) { throw "there is no mailbox $AlertSenderMailbox yet: create it (a shared mailbox is enough), then run this again" }
        # A scope filters on the primary address: one on a further address (alias) matches no mailbox at all.
        $primary = "$($mailbox.PrimarySmtpAddress)"
        if (-not $primary) { $primary = $AlertSenderMailbox }
        if ($primary -ne $AlertSenderMailbox) {
            Write-Step "$AlertSenderMailbox is a further address of mailbox $primary ($($mailbox.RecipientTypeDetails)): the scope names $primary, so the scan identity may send as that mailbox. A shared mailbox with $AlertSenderMailbox as its primary address keeps it apart" 'note'
        }

        # The service principal must point at the scan identity's enterprise app: application id and object id.
        $label = 'The scan identity in Exchange'
        $pointer = @(Find-Exchange 'Get-ServicePrincipal' @{ Identity = $scan.appId }) | Select-Object -First 1
        if (-not $pointer) { $pointer = @(Find-Exchange 'Get-ServicePrincipal' @{ Identity = $scan.id }) | Select-Object -First 1 }
        if ($pointer -and "$($pointer.AppId)" -eq $scan.appId -and "$($pointer.ObjectId)" -eq $scan.id) { Write-Step $label 'ok' }
        elseif ($pointer -and "$($pointer.AppId)" -ne $scan.appId) {
            # Another application's pointer at this object id: not ours to replace.
            throw "Exchange has a service principal for object id $($scan.id) with application id $($pointer.AppId), not $($scan.appId): remove it (Remove-ServicePrincipal) if it is wrong, then run this again"
        }
        elseif ($Audit) { Write-Step "$label$(if ($pointer) { " (points at object id $($pointer.ObjectId), not $($scan.id))" })" 'missing'; $missing.Add($label) }
        else {
            if ($pointer) {
                # Ours (this application id) but pointing at another object, so Exchange applies none of its assignments; they are made again below.
                foreach ($old in @(Find-Exchange 'Get-ManagementRoleAssignment' @{ RoleAssignee = $scan.appId })) {
                    Invoke-Exchange 'Remove-ManagementRoleAssignment' @{ Identity = "$($old.Name)"; Confirm = $false } | Out-Null
                }
                Invoke-Exchange 'Remove-ServicePrincipal' @{ Identity = $scan.appId; Confirm = $false } | Out-Null
            }
            Invoke-Exchange 'New-ServicePrincipal' @{ AppId = $scan.appId; ObjectId = $scan.id; DisplayName = 'M365Permissions scan identity' } | Out-Null
            Write-Step "$label$(if ($pointer) { " (replaced: it pointed at object id $($pointer.ObjectId))" })" 'added'
            $senderChanged = $true
        }

        $filter = "PrimarySmtpAddress -eq '$primary'"
        # Exchange refuses a second scope with the same filter, so one another product made for this mailbox is used as it is.
        function Test-SenderFilter($Scope) { ("$($Scope.RecipientFilter)" -replace '[\s()]', '').ToLowerInvariant() -eq ($filter -replace '[\s()]', '').ToLowerInvariant() }
        $existing = @(Find-Exchange 'Get-ManagementScope' @{ Identity = $senderScope }) | Select-Object -First 1
        $shared = if (-not ($existing -and (Test-SenderFilter $existing))) {
            @(Find-Exchange 'Get-ManagementScope' @{}) | Where-Object { "$($_.Name)" -ne $senderScope -and "$($_.Exclusive)" -ne 'True' -and (Test-SenderFilter $_) } | Select-Object -First 1
        }
        if ($shared) { $senderScope = "$($shared.Name)" }
        $label = "Management scope $senderScope ($primary only)"
        if ($shared) { Write-Step "$label, which exists already: the scan identity uses it as it is" 'ok' }
        elseif ($existing -and (Test-SenderFilter $existing)) { Write-Step $label 'ok' }
        elseif ($Audit) { Write-Step "$label$(if ($existing) { " (now: $($existing.RecipientFilter))" })" 'missing'; $missing.Add($label) }
        elseif ($existing) {
            Invoke-ExchangeChange 'Set-ManagementScope' @{ Identity = $senderScope; RecipientRestrictionFilter = $filter } | Out-Null
            Write-Step "$label (was: $($existing.RecipientFilter))" 'added'
            $senderChanged = $true
        }
        else {
            Invoke-ExchangeChange 'New-ManagementScope' @{ Name = $senderScope; RecipientRestrictionFilter = $filter } | Out-Null
            Write-Step $label 'added'
            $senderChanged = $true
        }

        # Exactly one Mail.Send assignment for the scan identity, in that scope: any other lets it send as more mailboxes.
        $label = "$senderRole in scope $senderScope"
        $assigned = @(Find-Exchange 'Get-ManagementRoleAssignment' @{ RoleAssignee = $scan.appId; Role = $senderRole })
        $right = $assigned | Where-Object { "$($_.CustomResourceScope)" -eq $senderScope } | Select-Object -First 1
        $others = @($assigned | Where-Object { "$($_.CustomResourceScope)" -ne $senderScope })
        function Get-ScopeName($Assignment) { if ("$($Assignment.CustomResourceScope)") { "scope $($Assignment.CustomResourceScope)" } else { 'the whole organisation' } }
        if ($right) { Write-Step $label 'ok' }
        elseif ($Audit) {
            # The first one would be moved, the rest removed.
            Write-Step "$label$(if ($others) { " (now: $(Get-ScopeName $others[0]))" })" 'missing'; $missing.Add($label)
            $others = @($others | Select-Object -Skip 1)
        }
        elseif ($others) {
            $moved = $others[0]
            $others = @($others | Select-Object -Skip 1)
            Invoke-ExchangeChange 'Set-ManagementRoleAssignment' @{ Identity = "$($moved.Name)"; CustomResourceScope = $senderScope } | Out-Null
            Write-Step "$label (was: $(Get-ScopeName $moved))" 'added'
            $senderChanged = $true
        }
        else {
            Invoke-ExchangeChange 'New-ManagementRoleAssignment' @{ App = $scan.appId; Role = $senderRole; CustomResourceScope = $senderScope } | Out-Null
            Write-Step $label 'added'
            $senderChanged = $true
        }
        foreach ($other in $others) {
            $text = "$senderRole in $(Get-ScopeName $other) (more mailboxes than $primary)"
            if ($Audit) { Write-Step "$text, to be removed" 'missing'; $missing.Add($text) }
            else {
                Invoke-Exchange 'Remove-ManagementRoleAssignment' @{ Identity = "$($other.Name)"; Confirm = $false } | Out-Null
                Write-Step "$text removed" 'added'
                $senderChanged = $true
            }
        }

        # Exchange's own check, which bypasses its cache: does the assignment cover the mailbox?
        $label = "Exchange lets the scan identity send as $AlertSenderMailbox"
        $covered = $null
        try {
            $tests = @(Invoke-Exchange 'Test-ServicePrincipalAuthorization' @{ Identity = $scan.appId; Resource = $primary }) | Where-Object { "$($_.RoleName)" -eq $senderRole }
            $covered = [bool]($tests | Where-Object { "$($_.InScope)" -eq 'True' })
        }
        catch { Write-Verbose "$_" }
        # A mailbox made in this run may not match its new scope yet: that counts as not yet applied.
        if ($covered -eq $false -and $senderPlan.Created) { $covered = $null }
        if ($covered -eq $false -and -not $Audit) { throw "Exchange's own check (Test-ServicePrincipalAuthorization) says $senderRole does not cover $AlertSenderMailbox" }
        elseif ($covered -eq $false) { Write-Step $label 'missing'; $missing.Add($label) }
        elseif ($senderChanged) { Write-Step "$label once it applies the change: within 2 hours (Microsoft: 30 minutes to 2 hours). Until then alert mails fail and are sent again later; no change is left out" 'added' }
        elseif ($null -eq $covered) { Write-Step "$label (set up; Exchange's own check could not run)" 'ok' }
        else { Write-Step $label 'ok' }
    }
    catch {
        Write-Step "Mail alerts: $(Get-ExchangeFailure $_)" 'failed'
        $manual.Add((Get-SenderByHand))
    }
}

if ($AlertSenderMailbox -and (Test-Step 'MailSender')) { . Invoke-MailSenderStep }
elseif ((Test-Step 'MailSender') -and $canAskSender) { $senderPlan.Ask = $true }
elseif ($askedMail) {
    Write-Step 'Mail alerts: add -AlertSenderMailbox <the mailbox the alerts come from>' 'missing'
    $missing.Add('-AlertSenderMailbox')
}

# At the end of the run, before the version 1 clean-up: a shared mailbox for alert mails when none was given or the given
# one does not exist, after a question (default Yes) and its name (default M365Permissions). A given address stays; with
# none, a name makes <name>@<default domain>, or a full address is used as it is. Then sending as it is set up.
function Complete-MailSender {
    if (-not $senderPlan.Ask) { return }
    $wanted = $AlertSenderMailbox
    Write-Host "`nMail alerts: a mailbox to send them from"
    $question = if ($wanted) { "There is no mailbox $wanted yet. Create it as a shared mailbox now? (Y/n)" } else { 'No mailbox for alert mails was given. Create a shared mailbox for them now? (Y/n)' }
    $answer = try { Read-Host $question } catch { 'n' }
    if ("$answer".Trim() -match '^(n|no)$') {
        if ($wanted) {
            Write-Step "Mail alerts: there is no mailbox $wanted yet: create it (a shared mailbox is enough), then run this again" 'failed'
            $manual.Add((Get-SenderByHand))
        }
        elseif ($askedMail) { Write-Step 'Mail alerts: add -AlertSenderMailbox <the mailbox the alerts come from>' 'missing'; $missing.Add('-AlertSenderMailbox') }
        return
    }
    $name = try { "$(Read-Host 'Name of the shared mailbox [M365Permissions]')".Trim() } catch { '' }
    if (-not $name) { $name = 'M365Permissions' }
    if (-not $wanted -and $name -match '@') { $wanted = $name; $name = $name.Split('@')[0] }
    try {
        Connect-Exchange
        $alias = (($(if ($wanted) { $wanted.Split('@')[0] } else { $name })) -replace '[^A-Za-z0-9._-]', '').Trim('.')
        if (-not $alias) { throw "$name has no letters or digits to make an address of: run this again and choose another name" }
        if (-not $wanted) {
            $domain = @(Find-Exchange 'Get-AcceptedDomain' @{}) | Where-Object { "$($_.Default)" -eq 'True' } | Select-Object -First 1
            if (-not $domain) { throw 'Exchange names no default domain: run this again with -AlertSenderMailbox <address>' }
            $wanted = "$alias@$($domain.DomainName)"
        }
        if ($wanted -notmatch '^[^\s@'']+@[^\s@'']+\.[^\s@'']+$') { throw "$wanted is not an e-mail address" }
        if (@(Find-Exchange 'Get-Mailbox' @{ Identity = $wanted }).Count) { Write-Step "Mailbox $wanted exists already: alert mails come from it" 'ok' }
        else {
            Invoke-Exchange 'New-Mailbox' @{ Shared = $true; Name = $name; DisplayName = $name; Alias = $alias; PrimarySmtpAddress = $wanted } | Out-Null
            Write-Step "Shared mailbox $name ($wanted)" 'added'
            $senderPlan.Created = $true
        }
    }
    catch {
        Write-Step "Mail alerts: the shared mailbox was not created: $(Get-ExchangeFailure $_)" 'failed'
        $manual.Add((Get-SenderByHand))
        return
    }
    if ($wanted -ne $AlertSenderMailbox) { $senderPlan.Settings = $wanted }
    $AlertSenderMailbox = $wanted
    . Invoke-MailSenderStep
}

# Only a connection this script opened is closed again.
function Close-Exchange {
    if ($exchangeConnected) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; $exchangeConnected = $false }
}

# Optional steps, last: everything above is done before Dataverse may ask for input. A problem in them is listed for
# an admin, stops nothing, and does not hold back the version 1 clean-up.
$optionalFrom = $script:stepIssues, $manual.Count
Grant-CertificateRight
if (Test-Step 'AzureDevOps') {
    try {
        Write-Host "`nAzure DevOps: the scan identity as a Stakeholder with read access to every project"
        Write-DelegatedNote 'AzureDevOps'
        $devOpsApp = '499b84ac-1321-427f-aa17-267ca6975798'
        $noDevOps = 'Azure DevOps: this account has no Azure DevOps organisation (or no access to it); nothing to do'
        $devOpsByHand = "Azure DevOps: in each organization, Organization settings > Users > Add users > the scan identity (object id $($scan.id)), access level Stakeholder"
        $devOpsHeaders = $null
        $organizations = @()
        # The owner of each organization, as the catalog names it.
        $devOpsOwners = @{}
        # Without Azure DevOps' enterprise app no organisation is connected to this tenant: nothing to sign in for.
        $devOpsApps = @(try { (Invoke-Graph GET "/servicePrincipals?`$filter=appId eq '$devOpsApp'&`$select=id").value } catch { 'unknown' })
        if ($devOpsApps.Count -eq 0 -and -not $DevOpsOrganization) { Write-Step $noDevOps 'skipped' }
        else {
            try {
                $devOpsHeaders = @{ Authorization = "Bearer $(Get-Token $devOpsApp)" }
                # The catalog answers CSV (with a byte order mark): one row per organization of this tenant.
                $csv = Invoke-RestMethod -Method GET -Headers $devOpsHeaders -Uri "https://vsaex.dev.azure.com/_apis/EnterpriseCatalog/Organizations?tenantId=$tenantId&api-version=7.1-preview.1" -TimeoutSec 60
                $rows = @("$csv".TrimStart([char]0xFEFF) | ConvertFrom-Csv)
                foreach ($row in $rows) { $devOpsOwners["$($row.'Organization Name')".Trim()] = "$($row.Owner)".Trim() }
                $organizations = @($rows | ForEach-Object { "$($_.'Organization Name')".Trim() } |
                    Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$' } | Select-Object -Unique)
                if ($DevOpsOrganization) { $organizations = @($DevOpsOrganization | Select-Object -Unique) }
                if ($organizations.Count -eq 0) { Write-Step $noDevOps 'skipped' }
            }
            catch {
                $problem = Get-SignInProblem $_
                $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                # Azure DevOps refuses an account that is in no organisation of this tenant.
                # An organization's owner may not list the tenant's organizations: the ones the command names are enough.
                if ($DevOpsOrganization -and -not $problem) { $organizations = @($DevOpsOrganization | Select-Object -Unique) }
                elseif ($problem -eq $noAccessProblem -or (-not $problem -and ($status -in 401, 403 -or "$_" -match '\b401\b|Unauthorized'))) { Write-Step $noDevOps 'skipped' }
                elseif ($problem) { Write-SignInSkip 'Azure DevOps' 'Azure DevOps' $problem 'AzureDevOps' $devOpsByHand }
                else {
                    Write-Step "Azure DevOps organizations could not be listed: $($_.Exception.Message)" 'failed'
                    $manual.Add($devOpsByHand)
                }
            }
        }
        function Invoke-DevOpsApi([string]$Method, [string]$Uri, $Body) {
            $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $devOpsHeaders -Body $json -ContentType 'application/json'
        }
        # The scan identity's descriptor in an organization (memberships are keyed on it), or null when it is not a user there.
        function Get-ScanDescriptor([string]$Organization) {
            $continuation = $null
            do {
                $page = Invoke-RestMethod -Method GET -Headers $devOpsHeaders -ResponseHeadersVariable pageHeaders `
                    -Uri "https://vssps.dev.azure.com/$Organization/_apis/graph/serviceprincipals?api-version=7.1-preview.1$(if ($continuation) { "&continuationToken=$continuation" })"
                $hit = @($page.value) | Where-Object originId -eq $scan.id | Select-Object -First 1
                if ($hit) { return $hit.descriptor }
                $continuation = if ($pageHeaders) { @($pageHeaders['X-MS-ContinuationToken'])[0] }
            } while ($continuation)
            $null
        }
        # Whether the owner the catalog names is an enabled account of this tenant: $true, $false (disabled or gone), or $null (not known).
        function Get-OwnerState([string]$Owner) {
            if ("$Owner" -notmatch '^[^\s@'']+@[^\s@'']+$') { return $null }
            try {
                $found = @((Invoke-Graph GET "/users?`$filter=userPrincipalName eq '$Owner' or mail eq '$Owner'&`$select=accountEnabled").value)
                if ($found.Count -eq 0) { return $false }
                return [bool](@($found | Where-Object { $_.accountEnabled }).Count)
            }
            catch { return $null }
        }
        # This step for one organization, for its owner to run: the instance's address and scan app, never the managed
        # application (its owner may not read it).
        function Get-DevOpsCommand([string]$Organization) {
            $site = "$WebUrl".TrimEnd('/')
            "& ([scriptblock]::Create((Invoke-RestMethod '$site/setup/initialize.ps1'))) -WebUrl '$site' -ScanAppId '$($scan.appId)' -TenantId '$tenantId' -Only 'AzureDevOps' -DevOpsOrganization '$Organization'"
        }
        foreach ($organization in $organizations) {
            try {
                $descriptor = Get-ScanDescriptor $organization
                if ($descriptor) { Write-Step "$($organization): Stakeholder" 'ok' }
                elseif ($Audit) { Write-Step "$($organization): Stakeholder" 'missing'; continue }
                else {
                    $added = Invoke-DevOpsApi POST "https://vsaex.dev.azure.com/$organization/_apis/serviceprincipalentitlements?api-version=7.1-preview.1" @{
                        accessLevel = @{ accountLicenseType = 'stakeholder' }; projectEntitlements = @()
                        servicePrincipal = @{ origin = 'aad'; originId = $scan.id; subjectKind = 'servicePrincipal' }
                    }
                    # Azure DevOps answers 200 also when it refused: the verdict is operationResult.isSuccess.
                    if ($added.operationResult -and $added.operationResult.isSuccess -eq $false) {
                        throw "Azure DevOps refused: $((@($added.operationResult.errors) | ForEach-Object { if ($_.value) { $_.value } else { $_.message } }) -join '; ')"
                    }
                    Write-Step "$($organization): Stakeholder" 'added'
                    for ($attempt = 1; $attempt -le 6 -and -not $descriptor; $attempt++) {
                        $descriptor = Get-ScanDescriptor $organization
                        if (-not $descriptor) { Start-Sleep -Seconds 5 }
                    }
                    if (-not $descriptor) { throw 'the new user does not show up yet; run this again in a few minutes for project access' }
                }
                # Project access is separate from the organization: without it the scan sees no projects. Readers only reads.
                $groupsOfScan = @((Invoke-DevOpsApi GET "https://vssps.dev.azure.com/$organization/_apis/graph/Memberships/$($descriptor)?direction=up&api-version=7.1-preview.1").value.containerDescriptor)
                foreach ($project in @((Invoke-DevOpsApi GET "https://dev.azure.com/$organization/_apis/projects?api-version=7.1&`$top=1000").value)) {
                    $label = "$organization/$($project.name): Readers"
                    $scope = (Invoke-DevOpsApi GET "https://vssps.dev.azure.com/$organization/_apis/graph/descriptors/$($project.id)?api-version=7.1-preview.1").value
                    $readers = (@((Invoke-DevOpsApi GET "https://vssps.dev.azure.com/$organization/_apis/graph/groups?scopeDescriptor=$scope&api-version=7.1-preview.1").value) |
                        Where-Object displayName -eq 'Readers' | Select-Object -First 1).descriptor
                    if (-not $readers) { Write-Step "$($label): the project has no Readers group" 'failed' }
                    elseif ($groupsOfScan -contains $readers) { Write-Step $label 'ok' }
                    elseif ($Audit) { Write-Step $label 'missing' }
                    else {
                        Invoke-DevOpsApi PUT "https://vssps.dev.azure.com/$organization/_apis/graph/memberships/$descriptor/$($readers)?api-version=7.1-preview.1" | Out-Null
                        Write-Step $label 'added'
                    }
                }
            }
            catch {
                if ("$_" -notmatch '401|403|Unauthorized|Forbidden|permission') {
                    Write-Step "$($organization): $($_.Exception.Message)" 'failed'
                    $manual.Add("Azure DevOps: https://dev.azure.com/$organization/_settings/users > Add users > the scan identity (object id $($scan.id)), access level Stakeholder, Readers in each project")
                    continue
                }
                # Not an administrator there: often an organization a user made for themselves. Nobody but its owner and its
                # Project Collection Administrators can add a user; an Entra role reaches in only when they are all inactive.
                $owner = $devOpsOwners[$organization]
                $active = Get-OwnerState $owner
                if ($owner -and $active -eq $false) {
                    Write-Step "$($organization): its owner $owner is no longer active in this tenant. An Azure DevOps Administrator (Entra role) can claim it: https://dev.azure.com/$organization > Claim Ownership, then run this step again" 'missing'
                    $manual.Add("Azure DevOps: claim $organization (its owner $owner is no longer active) as an Azure DevOps Administrator at https://dev.azure.com/$organization, then run: $(Get-DevOpsCommand $organization)")
                }
                else {
                    $who = if ($owner) { "its owner $owner" } else { 'its owner' }
                    Write-Step "$($organization): only $who or a Project Collection Administrator of it can add the scan identity, as themselves (no Entra role needed)" 'missing'
                    $manual.Add("Azure DevOps: ask $who to run, signed in as themselves: $(Get-DevOpsCommand $organization)")
                }
            }
        }
    }
    catch { Write-Step "Azure DevOps: $($_.Exception.Message)" 'failed' }
}

# Dataverse's self-elevation (applyAdminRole of the Power Platform API) only answers Microsoft's own sign-in clients: the
# permission it asks for is not published, so no other app can hold it (seen live 2026-11-17: 403 for Azure PowerShell's
# token, 200 for this client's). So one browser sign-in through the Power Platform CLI's public client, authorization code
# with PKCE on a loopback address, in this run's tenant and only as the account this run uses. Returns the token.
$powerPlatformCliClient = '9cee029c-6210-4654-90bb-17e6e9d36617'
function Get-ElevationToken {
    if (-not (Test-InteractiveConsole) -or $env:ACC_CLOUD) { throw 'this session cannot open a browser sign-in' }
    $free = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $free.Start(); $port = $free.LocalEndpoint.Port; $free.Stop()
    $redirect = "http://localhost:$port/"
    function ConvertTo-Base64Url([byte[]]$Value) { [Convert]::ToBase64String($Value).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $random = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
    $verifier = ConvertTo-Base64Url $random
    $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    $state = [guid]::NewGuid().ToString('N')
    $scope = 'https://api.powerplatform.com/.default'
    $authority = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0"
    $query = "client_id=$powerPlatformCliClient&response_type=code&redirect_uri=$([uri]::EscapeDataString($redirect))&response_mode=query&scope=$([uri]::EscapeDataString($scope))&state=$state&code_challenge=$challenge&code_challenge_method=S256"
    if ("$($me.userPrincipalName)" -match '@') { $query += "&login_hint=$([uri]::EscapeDataString($me.userPrincipalName))" }
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($redirect)
    $listener.Start()
    try {
        Start-Process "$authority/authorize?$query"
        $pending = $listener.GetContextAsync()
        if (-not $pending.Wait([TimeSpan]::FromSeconds($signInSeconds))) { throw "the sign-in did not finish within $signInSeconds seconds" }
        $context = $pending.Result
        $answer = @{}
        foreach ($pair in $context.Request.Url.Query.TrimStart('?').Split('&')) {
            $name, $value = $pair.Split('=', 2)
            $answer[$name] = [uri]::UnescapeDataString("$value".Replace('+', ' '))
        }
        $page = [Text.Encoding]::UTF8.GetBytes('<html><body style="font-family:sans-serif">Signed in. You can close this tab and go back to the setup.</body></html>')
        $context.Response.ContentType = 'text/html'
        $context.Response.OutputStream.Write($page, 0, $page.Length)
        $context.Response.Close()
        if ($answer.error) { throw "$($answer.error): $("$($answer.error_description)".Split("`n")[0].Trim())" }
        if ($answer.state -ne $state -or -not $answer.code) { throw 'the sign-in answered something that was not asked for' }
        $token = (Invoke-RestMethod -Method POST -Uri "$authority/token" -Body @{
                client_id = $powerPlatformCliClient; grant_type = 'authorization_code'; code = $answer.code; redirect_uri = $redirect; code_verifier = $verifier; scope = $scope
            }).access_token
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
    # The role goes to whoever signed in: only the account this run works as.
    $claims = Get-TokenClaim $token
    if (-not $claims -or "$($claims.tid)" -ne $tenantId -or ($me.id -and "$($claims.oid)" -ne "$($me.id)")) { throw 'the sign-in was not with the account this setup runs as' }
    $token
}

if (Test-Step 'DataverseUser') {
    try {
        # Optional: without it the scan cannot see whether an environment blocks guests from Dataverse, and shows their access,
        # nor who holds which security role there.
        Write-Host "`nDataverse (optional): the scan identity as an application user of each environment, reading only the organization settings, security roles, users, teams, business units and Copilot Studio agents"
        Write-DelegatedNote 'DataverseUser'
        $byHand = 'Dataverse: run this command with -Only DataverseUser as a Global or Power Platform Administrator, or as a System Administrator of the environment (admin center: Environments, the environment, Membership, Add me)'
        $roleName = 'M365Permissions reader'
        # Read only, at organization depth: the guest access setting (organization), security roles with their privileges and
        # holders (role), users and application users (systemuser), teams and their members (team), business units.
        $readPrivileges = @('prvReadOrganization', 'prvReadRole', 'prvReadUser', 'prvReadTeam', 'prvReadBusinessUnit')
        # Copilot Studio agents (bot), their knowledge and actions (botcomponent) and connections (connectionreference): only
        # where the environment has these tables.
        $agentPrivileges = @('prvReadbot', 'prvReadbotcomponent', 'prvReadconnectionreference')
        $instances = @()
        try {
            $bapHeaders = @{ Authorization = "Bearer $(Get-Token 'https://service.powerapps.com/' 'Power Platform')" }
            $next = 'https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01&$expand=properties'
            while ($next) {
                $page = Invoke-RestMethod -Method GET -Uri $next -Headers $bapHeaders
                $instances += @($page.value | ForEach-Object {
                    $url = "$($_.properties.linkedEnvironmentMetadata.instanceUrl)".TrimEnd('/')
                    if ($url -match '^https://[a-z0-9-]+(\.[a-z0-9-]+)*\.(dynamics\.com|dynamics\.cn|microsoftdynamics\.us|appsplatform\.us)$') {
                        [pscustomobject]@{ Id = "$($_.name)"; Name = "$($_.properties.displayName)"; Url = $url; Teams = "$($_.properties.environmentSku)" -eq 'Teams' }
                    }
                })
                $next = $page.nextLink
            }
            if ($instances.Count -eq 0) { Write-Step 'No environments with Dataverse' 'ok' }
        }
        catch {
            $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            $problem = Get-SignInProblem $_
            if ($problem) { Write-SignInSkip 'Dataverse environments' 'Power Platform' $problem 'DataverseUser' $byHand }
            else {
                Write-Step "Dataverse environments could not be listed: $(if ("$_" -match '401|403|Unauthorized|Forbidden') { 'needs a Power Platform administrator' } else { $detail })" 'failed'
                $manual.Add($byHand)
            }
        }
        # What Dataverse said when it refused: {error:{message}}, or something else from a gateway on the way.
        function Get-RefusalText($Failure) {
            $text = if ($Failure.ErrorDetails.Message) { $Failure.ErrorDetails.Message } else { $Failure.Exception.Message }
            try { $answer = $text | ConvertFrom-Json } catch { return $text }
            foreach ($candidate in @($answer.error.message, $answer.message, $answer.error)) {
                if ($candidate -is [string] -and $candidate) { return $candidate }
            }
            $text
        }
        # Reads $api and $dvHeaders of the environment at hand.
        function Invoke-Dataverse([string]$Method, [string]$Path, $Body) {
            $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 6 -Compress } else { $null }
            $response = Invoke-WebRequest -Method $Method -Uri "$api/$Path" -Headers $dvHeaders -Body $json -ContentType 'application/json'
            # A create answers 204 with the new record's address in OData-EntityId.
            if ($response.Headers['OData-EntityId']) { return "$($response.Headers['OData-EntityId'])" -replace '^.*\(([0-9a-fA-F-]{36})\)$', '$1' }
            if ($response.Content) { return $response.Content | ConvertFrom-Json }
        }
        function Get-DataverseRootUnit { (Invoke-Dataverse GET 'businessunits?$select=businessunitid&$filter=_parentbusinessunitid_value eq null').value[0].businessunitid }
        $systemAdministratorTemplate = '627090ff-40a3-4053-8790-584edc5be201'
        # One environment; safe to run again, also after a refusal part way.
        function Add-DataverseUser {
            $unit = Get-DataverseRootUnit
            $agentFilter = ($agentPrivileges | ForEach-Object { "name eq '$_'" }) -join ' or '
            $wanted = @($readPrivileges) + @(@((Invoke-Dataverse GET "privileges?`$select=name&`$filter=$agentFilter").value) | ForEach-Object { "$($_.name)" } | Where-Object { $_ -in $agentPrivileges })
            $role = (Invoke-Dataverse GET "roles?`$select=roleid&`$filter=name eq '$roleName' and _businessunitid_value eq $unit").value | Select-Object -First 1
            $user = (Invoke-Dataverse GET "systemusers?`$select=systemuserid&`$filter=applicationid eq $($scan.appId)").value | Select-Object -First 1
            # Complete: the role holds the read privileges and nothing else, and the scan identity holds the role.
            function Get-RolePrivilegeList([string]$Id) { @((Invoke-Dataverse GET "roles($Id)/roleprivileges_association?`$select=name,privilegeid").value) }
            $rolePrivileges = if ($role) { Get-RolePrivilegeList $role.roleid } else { @() }
            $lacking = @($wanted | Where-Object { $_ -notin @($rolePrivileges.name) })
            $extra = @($rolePrivileges | Where-Object { $_.name -notin $wanted })
            $holds = $user -and $role -and (Invoke-Dataverse GET "systemusers($($user.systemuserid))/systemuserroles_association?`$select=roleid&`$filter=roleid eq $($role.roleid)").value
            if ($lacking.Count -eq 0 -and $extra.Count -eq 0 -and $holds) { Write-Step $label 'ok'; return }
            $adds = if ($role) { "$(if ($lacking.Count -gt 0) { ": role $roleName misses $($lacking -join ', ')" })$(if ($extra.Count -gt 0) { "$(if ($lacking.Count -gt 0) { ';' } else { ": role $roleName" }) also holds $($extra.name -join ', ')" })" } else { '' }
            if ($Audit) { Write-Step "$label$adds" 'missing'; $manual.Add($byHand); return }
            # Read privileges only, nothing that changes the environment. A role from an earlier run gets what it misses and loses the rest.
            $roleId = if ($role) { $role.roleid } else {
                Invoke-Dataverse POST 'roles' @{ name = $roleName; 'businessunitid@odata.bind' = "/businessunits($unit)"; description = 'M365Permissions scan: reads the organization settings, security roles, users, teams, business units and Copilot Studio agents' }
            }
            if ($lacking.Count -gt 0) {
                $filter = ($lacking | ForEach-Object { "name eq '$_'" }) -join ' or '
                $found = @((Invoke-Dataverse GET "privileges?`$select=privilegeid,name&`$filter=$filter").value)
                $absent = @($lacking | Where-Object { $_ -notin @($found.name) })
                if ($absent.Count -gt 0) { throw "This environment has no privilege $($absent -join ', ')." }
                $grant = @($found | ForEach-Object { @{ Depth = 'Global'; PrivilegeId = $_.privilegeid; BusinessUnitId = $unit } })
                Invoke-Dataverse POST "roles($roleId)/Microsoft.Dynamics.CRM.AddPrivilegesRole" @{ Privileges = $grant } | Out-Null
            }
            # Dataverse gives a new role default privileges, and every AddPrivilegesRole adds creating and changing SharePoint
            # data again: what is not one of the reads goes, last.
            $surplus = if ($role -and $lacking.Count -eq 0) { $extra } else { @(Get-RolePrivilegeList $roleId | Where-Object { $_.name -notin $wanted }) }
            foreach ($privilege in $surplus) {
                Invoke-Dataverse POST "roles($roleId)/Microsoft.Dynamics.CRM.RemovePrivilegeRole" @{ Privilege = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.privilege'; privilegeid = $privilege.privilegeid } } | Out-Null
            }
            $userId = if ($user) { $user.systemuserid } else { Invoke-Dataverse POST 'systemusers' @{ applicationid = $scan.appId; 'businessunitid@odata.bind' = "/businessunits($unit)" } }
            if (-not $holds) { Invoke-Dataverse POST "systemusers($userId)/systemuserroles_association/`$ref" @{ '@odata.id' = "$api/roles($roleId)" } | Out-Null }
            Write-Step "$label (role $roleName$(if ($role -and $lacking.Count -gt 0) { ", now also $($lacking -join ', ')" })$(if ($role -and $extra.Count -gt 0) { ", no longer $($extra.name -join ', ')" }))" 'added'
        }
        # Self-elevation, as Membership > Add me does: System Administrator of the environment for the admin who runs this. One
        # sign-in serves every environment; when it fails it is not tried again and the admin is asked instead.
        $elevation = @{ Token = $null; Failed = $null; Said = $false }
        function Add-SelfAsAdmin([string]$EnvironmentId) {
            if ($elevation.Failed) { throw $elevation.Failed }
            if (-not $elevation.Token) {
                Write-Host '  One more browser sign-in (it shows as Power Platform CLI) lets this step make you System Administrator where an environment needs it, and remove you again afterwards.'
                try { $elevation.Token = Get-ElevationToken }
                catch { $elevation.Failed = "$($_.Exception.Message)"; throw }
            }
            for ($try = 1; ; $try++) {
                try {
                    Invoke-RestMethod -Method POST -Uri "https://api.powerplatform.com/usermanagement/environments/$([uri]::EscapeDataString($EnvironmentId))/user/applyAdminRole?api-version=2024-10-01" -Headers @{ Authorization = "Bearer $($elevation.Token)" } -ContentType 'application/json' | Out-Null
                    return
                }
                catch {
                    # 429: Microsoft's own directory reads behind this call were throttled (seen live).
                    if ([int]$_.Exception.Response.StatusCode -ne 429 -or $try -ge 5) { throw }
                    Start-Sleep -Seconds 20
                }
            }
        }
        # Takes away the System Administrator role this step gave the admin. Reads $api and $dvHeaders of the environment.
        function Revoke-SelfAsAdmin([string]$Name, [bool]$Asked) {
            try {
                $self = (Invoke-Dataverse GET 'WhoAmI').UserId
                $admin = (Invoke-Dataverse GET "systemusers($self)/systemuserroles_association?`$select=roleid&`$filter=_roletemplateid_value eq $systemAdministratorTemplate").value | Select-Object -First 1
                if ($admin) {
                    Invoke-Dataverse DELETE "systemusers($self)/systemuserroles_association($($admin.roleid))/`$ref" | Out-Null
                    Write-Step "You are no longer System Administrator of $Name" 'ok'
                }
                else {
                    Write-Step "Dataverse lists no System Administrator role for you in $Name, so none was removed" 'missing'
                    $manual.Add("Dataverse: if $(if ($Asked) { 'Add me finished' } else { 'the role arrived' }) after this step, remove your own System Administrator role in $Name (admin center: Environments, the environment, Membership)")
                }
            }
            catch {
                Write-Step "Your System Administrator role in $Name could not be removed: $($_.Exception.Message)" 'failed'
                $manual.Add("Dataverse: remove your own System Administrator role in $Name (admin center: Environments, the environment, Membership)")
            }
        }
        # Dataverse for Teams takes no custom security role (AddPrivilegesRole is refused there), so no reader role can be made.
        $teamsNote = "Dataverse for Teams, which takes no reader role: access there follows the team's owners, members and guests"
        # The role a run made there before Dataverse refused its privileges is of no use: it goes, when this account may.
        function Clear-UnusedReaderRole {
            if ($Audit) { return '' }
            try {
                $left = @((Invoke-Dataverse GET "roles?`$select=roleid&`$filter=name eq '$roleName'").value)
                foreach ($role in $left) { Invoke-Dataverse DELETE "roles($($role.roleid))" | Out-Null }
                if ($left.Count -gt 0) { return "; the unused role $roleName is removed" }
            }
            catch { Write-Verbose "$_" }
            ''
        }
        # Each environment in turn. One that waits for the admin's new role to reach Dataverse goes to the back of the line,
        # so the waits of many environments overlap.
        $line = [System.Collections.Generic.Queue[object]]::new()
        foreach ($instance in $instances) { $line.Enqueue([pscustomobject]@{ Instance = $instance; Elevated = $false }) }
        try {
            while ($line.Count -gt 0) {
                $turn = $line.Dequeue()
                $instance = $turn.Instance
                $label = "Application user in $($instance.Name)"
                $elevated = $turn.Elevated
                $asked = $false
                $skipped = $false
                if ($instance.Teams) {
                    $gone = ''
                    try {
                        $dvHeaders = @{ Authorization = "Bearer $(Get-Token $instance.Url 'Dataverse')"; 'OData-Version' = '4.0'; Accept = 'application/json' }
                        $api = "$($instance.Url)/api/data/v9.2"
                        $gone = Clear-UnusedReaderRole
                    }
                    catch { Write-Verbose "$_" }
                    Write-Step "$($label): $teamsNote$gone" 'skipped'
                    continue
                }
                try {
                    # One browser sign-in at most for all environments together.
                    $dvHeaders = @{ Authorization = "Bearer $(Get-Token $instance.Url 'Dataverse')"; 'OData-Version' = '4.0'; Accept = 'application/json' }
                    $api = "$($instance.Url)/api/data/v9.2"
                    for ($attempt = 1; ; $attempt++) {
                        try {
                            Add-DataverseUser
                            break
                        }
                        catch {
                            if ([int]$_.Exception.Response.StatusCode -notin 401, 403) { throw }
                            if ($elevated) {
                                # The role takes a while to reach Dataverse: the step itself is the test.
                                if ($attempt -ge 20) { throw }
                                Start-Sleep -Seconds 15
                                continue
                            }
                            if ($Audit -or $NoElevate -or -not $callerMember) { throw } # no role for an account of another tenant
                            # Global and Power Platform Administrators are no System Administrators of an environment until they add
                            # themselves; everyone in a default environment can read it, so the refusal may come only at the first change.
                            try {
                                Add-SelfAsAdmin $instance.Id
                                Write-Host "  You are System Administrator of $($instance.Name) for this step; it goes on there once Dataverse sees the role"
                                $line.Enqueue([pscustomobject]@{ Instance = $instance; Elevated = $true })
                                break
                            }
                            catch {
                                if (-not $elevation.Said) { Write-Host "  Making you System Administrator of $($instance.Name) did not work ($(Get-RefusalText $_))." }
                                $elevation.Said = [bool]$elevation.Failed
                            }
                            Write-Host "  This step needs you as System Administrator of $($instance.Name), which only you can arrange:"
                            Write-Host "  https://admin.powerplatform.microsoft.com/manage/environments > $($instance.Name) > Membership > Add me" -ForegroundColor Cyan
                            $answer = try { Read-Host '  Press Enter when done (the role is removed again after this step), or S to skip this environment' } catch { 's' }
                            if ("$answer".Trim() -match '^(s|skip)$') { $skipped = $true; throw }
                            $asked = $true
                            $elevated = $true
                            $attempt = 0
                            Write-Host '  Waiting for Dataverse to see the role, up to 5 minutes'
                        }
                    }
                }
                catch {
                    $detail = Get-RefusalText $_
                    $status = [int]$_.Exception.Response.StatusCode
                    $why = if ($skipped) { 'skipped: it needs you as System Administrator of this environment' }
                    elseif ($elevated -and $status -in 401, 403) {
                        $held = try { @((Invoke-Dataverse GET "systemusers($((Invoke-Dataverse GET 'WhoAmI').UserId))/systemuserroles_association?`$select=name").value.name) -join ', ' } catch { 'unknown' }
                        "Dataverse still refuses after 5 minutes, so the role has not reached it. Check that Membership lists you as System Administrator. Your roles there: $held ($detail)"
                    }
                    elseif ($status -in 401, 403) { "needs a System Administrator of this environment, which Microsoft no longer makes a Global Administrator automatically ($detail)" } else { $detail }
                    $problem = Get-SignInProblem $_
                    if ("$detail" -match 'Dataverse for Teams') { Write-Step "$($label): $teamsNote$(Clear-UnusedReaderRole)" 'skipped' }
                    elseif ($problem) { Write-SignInSkip $label 'Dataverse' $problem 'DataverseUser' $byHand }
                    else {
                        Write-Step "$($label): $why" 'failed'
                        $manual.Add($byHand)
                    }
                }
                finally {
                    if ($elevated) { Revoke-SelfAsAdmin $instance.Name $asked }
                }
            }
        }
        finally {
            # A run stopped part way: the roles of the environments still waiting in line go too.
            foreach ($turn in @($line | Where-Object { $_.Elevated })) {
                try {
                    $dvHeaders = @{ Authorization = "Bearer $(Get-Token $turn.Instance.Url 'Dataverse')"; 'OData-Version' = '4.0'; Accept = 'application/json' }
                    $api = "$($turn.Instance.Url)/api/data/v9.2"
                }
                catch { continue }
                Revoke-SelfAsAdmin $turn.Instance.Name $false
            }
        }
    }
    catch { Write-Step "Dataverse: $($_.Exception.Message)" 'failed' }
}

# DevOps and Dataverse problems are left out of the version 1 check.
$script:optionalIssues = $script:stepIssues - $optionalFrom[0]
$optionalManual = $manual.Count - $optionalFrom[1]

# The mail alert step's question last, so the rest of the run never waits for it. Its problems count as the step's.
. Complete-MailSender
. Close-Exchange

if ($manual.Count -gt 0) {
    Write-Host "`nStill to do by an admin who may (each switches on one more category):" -ForegroundColor Yellow
    $manual | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

if (-not $fix -and -not $AlertSenderMailbox) {
    Write-Host "`nOptional: mail alerts. Run this command again with -AlertSenderMailbox <mailbox> (it sets up Exchange), or by hand:"
    Write-Host "  $(Get-SenderByHand)"
}
if ($senderPlan.Settings) { Write-Host "`nMail alerts: in M365Permissions, Settings, E-mail alerts, enter $($senderPlan.Settings) under Use another mailbox of this tenant and choose Test and use, once Exchange applies the change (within 2 hours)." -ForegroundColor Yellow }

if ($missing.Count -gt 0) {
    # No exit: the script runs as a script block in your session, which exit would close.
    Write-Host "`nMissing: $($missing -join ', ')" -ForegroundColor Yellow
    return
}
if ($senderChanged) { Write-Host "`nMail alerts: Exchange applies the change within 2 hours. Then choose Send a test mail in M365Permissions (Settings, E-mail alerts). Alerts that failed meanwhile go out with every change since their last mail." -ForegroundColor Green }
$domainOnly = $domainStep -and -not @($Only | Where-Object { $_ -notin $domainSteps })
if ($domainOnly) { Write-Host "`nDone. Entra applies this within a minute: choose Check again under Settings, Access, Custom domain in M365Permissions." -ForegroundColor Green }
elseif ($fix -and -not (($askedMail -or $mcpStep) -and $Only.Count -eq 1)) { Write-Host "`nDone. Azure and Power BI apply this within minutes, Microsoft 365 when the scan identity's token renews (within 24 hours). Then choose Check again in M365Permissions." -ForegroundColor Green }
elseif ($fix) { Write-Host "`nDone." -ForegroundColor Green }
else {
    # A Marketplace instance's short link (m365permissions.com/name): JSolve gives it once the instance read the tenant's
    # domains, which the grants above allow, usually within two minutes. Its install status (progressUrl) carries it.
    $link = $null
    $progress = if ($application -and -not $Audit) { "$($application.properties.outputs.progressUrl.value)" } else { '' }
    if ($progress -match '^(https://[^/?#]+(?:/[^?#]*)?)/install\?app=') {
        $status = "$($Matches[1])/api/marketplace/install?app=$([uri]::EscapeDataString($ManagedApplicationId))"
        Write-Host "`nWaiting for your M365Permissions address (up to 3 minutes)."
        for ($attempt = 1; $attempt -le 18 -and -not $link; $attempt++) {
            try {
                $answer = Invoke-RestMethod -Uri $status -TimeoutSec 20
                if ("$($answer.link)" -match '^https://m365permissions\.com/[a-z0-9-]+$') { $link = "$($answer.link)" }
            }
            catch { Write-Verbose "$_" }
            if (-not $link) { Start-Sleep -Seconds 10 }
        }
    }
    if ($link) { Write-Host "`nDone. Open $link and sign in as $($me.userPrincipalName). Bookmark it: it always leads to your M365Permissions." -ForegroundColor Green }
    elseif (-not $callerMember) { Write-Host "`nDone. M365Permissions checks this tenant again within minutes. Staff of this tenant sign in once an admin here assigns them a role in the enterprise app of the sign-in app." -ForegroundColor Green }
    else { Write-Host "`nDone. Open $WebUrl in a few minutes and sign in as $($me.userPrincipalName)." -ForegroundColor Green }
    # The sign-in opens after the peering; once connected, without allowed IP ranges, only from the customer's own network.
    if ($PeerVirtualNetworkId) { Write-Host "M365Permissions now connects to your virtual network and, without allowed IP ranges, stays closed until it has: nobody can sign in and nothing is scanned. It then opens only from your network. The start page shows what it waits for." -ForegroundColor Yellow }
}

# Version 1 of M365Permissions: a Marketplace managed application (VM, SQL, web app; its VM identity scans), a sign-in app
# "M365PermissionsPortal-<web app> (Single Sign-On)" and three groups. Offered for deletion only after a full run without
# problems. The application and sign-in app only when tied to a version 1 managed application this account can read and
# delete; the groups by exact name once one of those was found. No raised access:
# it would not allow the deletion.
if (-not $fix -and -not $KeepVersion1) {
    # Problems of this run: a step reported failed or missing, something left by hand ($manual) or missing ($missing).
    $v1Issues = ($script:stepIssues - $script:optionalIssues) + ($manual.Count - $optionalManual) + $missing.Count
    if (-not $Audit -and $v1Issues -gt 0) { Write-Host "`nVersion 1 of M365Permissions: not looked for, because this run left something to do. Run this command again once that is done." -ForegroundColor DarkGray }
    elseif (-not $Audit -and -not (Test-InteractiveConsole)) { Write-Host "`nVersion 1 of M365Permissions: not looked for, because there is no console to ask in. Run this command in PowerShell 7 yourself to remove it." -ForegroundColor DarkGray }
    else {
        # Version 2's own objects, whatever they look like: its managed application, sign-in app, scan identity and group.
        $v2Applications = @($ManagedApplicationId, $(if ($application) { $application.id })) | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() }
        $v2AppIds = @($(if ($app) { $app.appId }), $(if ($sp) { $sp.appId }), $SignInAppId, $scan.appId) | Where-Object { $_ }
        $v2Groups = @($(if ($powerBiGroup) { $powerBiGroup.id })) | Where-Object { $_ }
        $v1Found = [System.Collections.Generic.List[object]]::new()
        # $Why empty: offered for deletion; otherwise listed with what to check.
        function Add-V1Item([string]$Kind, [string]$Name, [string]$Id, [string]$Path, [string]$Why) {
            $v1Found.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Id = $Id; Path = $Path; Why = $Why })
        }
        # Whether this account may delete a managed application in the scope; null when Azure does not say.
        function Test-ArmDelete([string]$Scope) {
            $action = 'Microsoft.Solutions/applications/delete'
            try { $granted = @((Invoke-Arm GET "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01").value) }
            catch { return $null }
            [bool]($granted | Where-Object { @($_.actions | Where-Object { $action -like $_ }) -and -not @($_.notActions | Where-Object { $action -like $_ }) })
        }
        $v1Sites = @{}
        # A version 1 instance that is not removed now may still use the shared groups.
        $v1Blocked = $false

        $v1Subscriptions = try { @((Invoke-Arm GET '/subscriptions?api-version=2022-12-01').value | Where-Object tenantId -eq $tenantId) } catch { @() }
        foreach ($v1Subscription in $v1Subscriptions) {
            $v1Next = "/subscriptions/$($v1Subscription.subscriptionId)/providers/Microsoft.Solutions/applications?api-version=2021-07-01"
            $v1Apps = @()
            try {
                while ($v1Next) {
                    $v1Page = Invoke-Arm GET $v1Next
                    $v1Apps += @($v1Page.value)
                    $v1Next = if ($v1Page.nextLink) { "$($v1Page.nextLink)" -replace '^https://management\.azure\.com', '' } else { $null }
                }
            }
            catch {
                Write-Step "Managed applications in subscription $($v1Subscription.displayName) could not be listed: $($_.Exception.Message)" 'note'
                $v1Blocked = $true
            }
            foreach ($v1App in $v1Apps) {
                $v1Plan = $v1App.plan
                if ("$($v1Plan.publisher)" -ne 'liebenconsultancy') { continue }
                # Version 2 is the same offer with plans *v2 and a setup command among its outputs.
                if ("$($v1App.id)".ToLowerInvariant() -in $v2Applications -or "$($v1Plan.name)" -like '*v2' -or $v1App.properties.outputs.setupCommand) { continue }
                $v1ResourceGroup = ($v1App.id -split '/')[0..4] -join '/'
                $v1Why = if ("$($v1Plan.product)" -notin 'm365permissions', 'm365permissions-preview' -or "$($v1Plan.name)" -notin 'standard', 'enterprise') {
                    "plan $($v1Plan.product)/$($v1Plan.name) is not one of version 1: check in the Azure portal (Managed applications) which version it is"
                }
                elseif ((Test-ArmDelete $v1ResourceGroup) -eq $false) { "your account may not delete it: that needs Owner or Contributor on resource group $(($v1ResourceGroup -split '/')[-1])" }
                Add-V1Item 'Managed application' $v1App.name $v1App.id $v1App.id $v1Why
                if ($v1Why) { $v1Blocked = $true; continue }
                # Its web app ties the sign-in app to it.
                $v1Resources = try { @((Invoke-Arm GET "$($v1App.properties.managedResourceGroupId)/resources?api-version=2021-04-01").value) } catch { @() }
                foreach ($v1Web in @($v1Resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $_.name -like 'm365pf*' })) {
                    $v1Hosts = @("$($v1Web.name).azurewebsites.net")
                    try {
                        $v1Site = (Invoke-Arm GET "$($v1Web.id)?api-version=2023-12-01").properties
                        $v1Hosts += @($v1Site.hostNames) + @($v1Site.defaultHostName)
                    }
                    catch { Write-Verbose "$_" }
                    $v1Sites[$v1Web.name] = @($v1Hosts | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
                }
            }
        }

        # The sign-in app: the exact name of version 1, a redirect URI on that instance's web app.
        $v1Portals = try { @((Invoke-Graph GET "/applications?`$filter=startswith(displayName,'M365PermissionsPortal-')&`$select=id,appId,displayName,publicClient,web,tags&`$top=999").value) } catch { @() }
        foreach ($v1Portal in $v1Portals) {
            $v1Name = [regex]::Match("$($v1Portal.displayName)", '^M365PermissionsPortal-(.+) \(Single Sign-On\)$')
            if (-not $v1Name.Success) { continue }
            if ($v1Portal.appId -in $v2AppIds -or @($v1Portal.tags | Where-Object { "$_" -like 'm365p-setup-*' }) -or @($v1Portal.web.redirectUris) -contains "https://$host_/signin-oidc") { continue }
            $v1WebName = $v1Name.Groups[1].Value
            $v1Replies = @(foreach ($v1Reply in @($v1Portal.publicClient.redirectUris)) { if ("$v1Reply" -match '^https://([^/]+)/api/entra/response$') { $Matches[1].ToLowerInvariant() } })
            $v1Why = if (-not $v1Sites.ContainsKey($v1WebName)) {
                "no version 1 managed application with web app $v1WebName was found in the subscriptions you can read: check that this instance is gone, then delete the app in the Entra admin center (App registrations)"
            }
            elseif (-not @($v1Replies | Where-Object { $_ -in $v1Sites[$v1WebName] })) { "its redirect URI does not point at web app $($v1WebName): check it in the Entra admin center (App registrations)" }
            Add-V1Item 'Sign-in app' $v1Portal.displayName $v1Portal.appId "/applications/$($v1Portal.id)" $v1Why
            if ($v1Why) { $v1Blocked = $true }
        }

        # The groups: the exact names of version 1, by name alone (owners and members do not matter, they are deleted anyway),
        # once a version 1 managed application or sign-in app was found with confidence. Never version 2's group.
        $v1Confident = [bool]@($v1Found | Where-Object { -not $_.Why })
        foreach ($v1GroupName in 'SEC-APP-M365Permissions-Users', 'SEC-APP-M365Permissions-Admins', 'SEC-SVC-M365Permissions') {
            $v1Groups = try { @((Invoke-Graph GET "/groups?`$filter=displayName eq '$v1GroupName'&`$select=id,displayName,mailNickname").value) } catch { @() }
            foreach ($v1Group in $v1Groups) {
                if ($v1Group.id -in $v2Groups -or "$($v1Group.mailNickname)" -eq 'm365permissions-scanners') { continue }
                $v1Why = if (-not $v1Confident) {
                    'no version 1 managed application or sign-in app was found here: check in the Entra admin center (Groups) whether it is version 1 before you delete it'
                }
                elseif ($v1Blocked) { 'a version 1 instance or sign-in app that is not deleted now (see above) may still use it' }
                Add-V1Item 'Group' $v1Group.displayName $v1Group.id "/groups/$($v1Group.id)" $v1Why
            }
        }

        $v1Offered = @($v1Found | Where-Object { -not $_.Why })
        if ($v1Found.Count -gt 0) { Write-Host "`nVersion 1 of M365Permissions in this tenant" }
        foreach ($v1Item in @($v1Found | Where-Object { $_.Why })) { Write-Step "$($v1Item.Kind) $($v1Item.Name) ($($v1Item.Id)), not offered for deletion: $($v1Item.Why)" 'note' }
        if ($Audit) {
            foreach ($v1Item in $v1Offered) { Write-Step "$($v1Item.Kind) $($v1Item.Name) ($($v1Item.Id)): a run without -Audit and without problems offers to delete it" 'note' }
        }
        elseif ($v1Offered.Count -gt 0) {
            Write-Host 'Version 2 is set up. This command can now delete version 1:'
            foreach ($v1Item in $v1Offered) { Write-Host "  $($v1Item.Kind) $($v1Item.Name) ($($v1Item.Id))" }
            Write-Host 'Deleting the managed application also deletes its resource group and scan identity, and everything version 1 stored,'
            Write-Host 'including its scan history. Export what you need from version 1 (CSV or Excel) first. Entra keeps deleted apps and'
            Write-Host 'groups for 30 days (Deleted items).'
            $v1Answer = try { Read-Host 'Delete version 1 now? (y/N)' } catch { '' }
            if ("$v1Answer".Trim() -notmatch '^(y|yes)$') { Write-Step 'Version 1 kept. Run this command again to delete it later' 'skipped' }
            else {
                $v1Pending = [System.Collections.Generic.List[object]]::new()
                foreach ($v1Item in $v1Offered) {
                    try {
                        if ($v1Item.Kind -eq 'Managed application') {
                            # Azure deletes the managed resource group with it, in the background.
                            Invoke-Arm DELETE "$($v1Item.Path)?api-version=2021-07-01" | Out-Null
                            $v1Pending.Add($v1Item)
                        }
                        else {
                            # Deleting an app registration deletes its enterprise app.
                            Invoke-Graph DELETE $v1Item.Path | Out-Null
                            Write-Step "$($v1Item.Kind) $($v1Item.Name) deleted" 'ok'
                        }
                    }
                    catch {
                        $v1Detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
                        Write-Step "$($v1Item.Kind) $($v1Item.Name) could not be deleted: $v1Detail" 'failed'
                    }
                }
                if ($v1Pending.Count -gt 0) { Write-Host '  Waiting for Azure to delete the managed application (up to 10 minutes).' }
                for ($v1Attempt = 1; $v1Pending.Count -gt 0 -and $v1Attempt -le 40; $v1Attempt++) {
                    Start-Sleep -Seconds 15
                    foreach ($v1Item in @($v1Pending)) {
                        try { Invoke-Arm GET "$($v1Item.Path)?api-version=2021-07-01" | Out-Null }
                        catch {
                            if ([int]$_.Exception.Response.StatusCode -eq 404) {
                                Write-Step "Managed application $($v1Item.Name) deleted, with its resource group" 'ok'
                                [void]$v1Pending.Remove($v1Item)
                            }
                        }
                    }
                }
                foreach ($v1Item in $v1Pending) { Write-Step "Managed application $($v1Item.Name) is still being deleted: Azure finishes it in the background (Azure portal, Managed applications)" 'note' }
            }
        }
    }
}
