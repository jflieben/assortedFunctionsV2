<#
.SYNOPSIS
    Waarmerk - Azure installatie (een script, alleen Azure CLI nodig)

.DESCRIPTION
    Zet Waarmerk volledig neer in de Azure-omgeving van een klant. Bedoeld om
    publiek gehost en vanuit de Azure Cloud Shell in een keer uitgevoerd te worden:

        iex "& { $(irm https://<host>/install.ps1) }"

    Het script heeft ALLEEN de Azure CLI (az) nodig. Alle installatie-artefacten
    (ARM-templates + de code van het toestemmingsportaal) worden via een SAS-URL
    van een storage account gedownload; er is geen lokale build, geen npm en geen
    configuratiebestand nodig.

    Idempotent: op basis van het bestaan van de resource group wordt automatisch
    Install (nieuw) of Update (bestaand) gekozen. Opnieuw uitvoeren is veilig; ARM
    werkt bestaande resources incrementeel bij.

.PARAMETER ImageTag
    Optioneel. Specifieke container image tag om te deployen (bijv. voor een
    rollback op advies van support). Leeg = nieuwste tag uit de registry.

.PARAMETER SubscriptionId
    Optioneel. Sla de interactieve subscription-keuze over.

.EXAMPLE
    # Cloud Shell (interactief)
    iex "& { $(irm https://<host>/install.ps1) }"

.EXAMPLE
    # Rollback naar een specifieke versie
    & ([scriptblock]::Create((irm https://<host>/install.ps1))) -ImageTag v1.2.3
#>

[CmdletBinding()]
param(
    [string]$ImageTag,
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"
$AppName = "waarmerk"
$AcrLoginServer = "waarmerk.azurecr.io"

function Show-Banner {
    Write-Output ""
    Write-Output "  ==========================================="
    Write-Output "        Waarmerk - Azure installatie"
    Write-Output "  ==========================================="
    Write-Output ""
}

function New-RandomPassword {
    # 24 tekens, mix van klassen (voldoet aan PostgreSQL-eisen)
    $bytes = [byte[]]::new(18)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'A') + "aA1!"
}

function New-Base64Secret {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes)
}

function ConvertTo-Pem {
    param([byte[]]$Der, [string]$Label)
    $b64 = [Convert]::ToBase64String($Der)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("-----BEGIN $Label-----")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        [void]$sb.AppendLine($b64.Substring($i, [Math]::Min(64, $b64.Length - $i)))
    }
    [void]$sb.Append("-----END $Label-----")
    return $sb.ToString()
}

function New-Es256KeyPair {
    $ec = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve]::CreateFromFriendlyName("nistP256"))
    try {
        return @{
            Private = ConvertTo-Pem $ec.ExportPkcs8PrivateKey() "PRIVATE KEY"
            Public  = ConvertTo-Pem $ec.ExportSubjectPublicKeyInfo() "PUBLIC KEY"
        }
    } finally { $ec.Dispose() }
}

function Get-PublicKeyFromPrivate {
    param([string]$PrivatePem)
    $pem = $PrivatePem -replace '\\n', "`n"
    $ec = [System.Security.Cryptography.ECDsa]::Create()
    try {
        $ec.ImportFromPem($pem)
        return ConvertTo-Pem $ec.ExportSubjectPublicKeyInfo() "PUBLIC KEY"
    } finally { $ec.Dispose() }
}

function Write-ParamFile {
    param([hashtable]$Parameters)
    $params = @{}
    foreach ($k in $Parameters.Keys) { $params[$k] = @{ value = $Parameters[$k] } }
    $obj = @{
        '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
        contentVersion = "1.0.0.0"
        parameters     = $params
    }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("waarmerk-p-" + [Guid]::NewGuid().ToString("N") + ".json")
    $obj | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding utf8
    return $path
}

function Invoke-RgDeployment {
    param(
        [Parameter(Mandatory = $true)][string] $ResourceGroup,
        [Parameter(Mandatory = $true)][string] $DeploymentName,
        [Parameter(Mandatory = $true)][string] $TemplateFile,
        [Parameter(Mandatory = $true)][string] $ParametersFile,
        [Parameter(Mandatory = $true)][string] $FailureMessage
    )

    az deployment group create -g $ResourceGroup --name $DeploymentName `
        --template-file $TemplateFile --parameters "@$ParametersFile" --output none
    if ($LASTEXITCODE -ne 0) { Write-Error $FailureMessage; exit 1 }

    $outJson = az deployment group show -g $ResourceGroup --name $DeploymentName --query "properties.outputs" -o json
    if ($LASTEXITCODE -ne 0) { Write-Error $FailureMessage; exit 1 }

    return ($outJson | ConvertFrom-Json)
}

function Read-NonEmpty {
    param([string]$Prompt)
    while ($true) {
        $v = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Write-Output "  Dit veld is verplicht."
    }
}

function Test-AcrPullCredential {
    # Valideert ACR-inloggegevens puur op de data-plane
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password')]
    param([string]$LoginServer, [string]$Username, [string]$Password, [string]$Repository)
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $uri = "https://$LoginServer/oauth2/token?service=$LoginServer&scope=repository:${Repository}:pull"
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 30 -ErrorAction Stop
        return [bool]$resp.access_token
    } catch {
        return $false
    }
}

# =========================================
#  Start
# =========================================

Show-Banner

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) is niet beschikbaar. Gebruik de Azure Cloud Shell of installeer az."
    exit 1
}

# --- Login ---
try {
    $null = az account show 2>&1
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Output "Niet ingelogd. Login starten..."
    az login | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Azure login mislukt."; exit 1 }
}

# --- Subscription ---
if (-not $SubscriptionId) {
    Write-Output ""
    Write-Output "Beschikbare subscriptions:"
    $subs = (az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o json) | ConvertFrom-Json
    for ($i = 0; $i -lt $subs.Count; $i++) {
        $mark = if ($subs[$i].isDefault) { " (huidig)" } else { "" }
        Write-Output "  [$($i + 1)] $($subs[$i].name)$mark"
    }
    while ($true) {
        $c = Read-Host "Kies een subscription [1-$($subs.Count)] of Enter voor de huidige"
        if ([string]::IsNullOrWhiteSpace($c)) { $SubscriptionId = ($subs | Where-Object { $_.isDefault }).id; break }
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $subs.Count) { $SubscriptionId = $subs[[int]$c - 1].id; break }
        Write-Output "  Ongeldige keuze."
    }
}
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { Write-Error "Kan subscription niet selecteren."; exit 1 }
$subName = az account show --query name -o tsv
Write-Output "Actieve subscription: $subName"

# --- Resource providers vooraf registreren ---
$requiredProviders = @('Microsoft.Network', 'Microsoft.DBforPostgreSQL', 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.ServiceBus')
Write-Output "Resource providers controleren en registreren..."
foreach ($ns in $requiredProviders) {
    $state = az provider show --namespace $ns --query registrationState -o tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Output "  $ns registreren (status: $state)..."
        az provider register --namespace $ns --only-show-errors | Out-Null
    }
}
foreach ($ns in $requiredProviders) {
    $deadline = (Get-Date).AddMinutes(10)
    while ((az provider show --namespace $ns --query registrationState -o tsv 2>$null) -ne 'Registered') {
        if ((Get-Date) -gt $deadline) {
            Write-Warning "Provider $ns is nog niet 'Registered'. De deployment kan alsnog vertragen of falen; probeer het daarna opnieuw."
            break
        }
        Start-Sleep -Seconds 10
    }
}

# --- Resource group -> bepaalt modus ---
$ResourceGroup = Read-NonEmpty "Naam van de resource group (bestaand = bijwerken, nieuw = installeren)"
$rgExists = (az group exists -n $ResourceGroup) -eq "true"
$Mode = if ($rgExists) { "Update" } else { "Install" }
Write-Output "Modus: $Mode (resource group $($(if ($rgExists) { 'bestaat' } else { 'wordt aangemaakt' })))"

# --- Locatie (naamgeving van resources wordt afgeleid van de resource group) ---
if ($Mode -eq "Install") {
    $validLocs = (az account list-locations --query "[].name" -o tsv) -split "\r?\n"
    while ($true) {
        $Location = Read-Host "Azure regio [swedencentral]"
        if ([string]::IsNullOrWhiteSpace($Location)) { $Location = "swedencentral" }
        $Location = $Location.Trim().ToLower()
        if ($validLocs -contains $Location) { break }
        Write-Output "  Onbekende regio. Voorbeelden: westeurope, northeurope, swedencentral."
    }
} else {
    $Location = az group show -n $ResourceGroup --query location -o tsv
    Write-Output "Regio (uit bestaande resource group): $Location"
}

# Resourcenamen dragen een van de resource group afgeleide suffix; de backend-web-app
# hoeft dus niet vooraf berekend te worden maar wordt bij een update opgezocht.
$backendAppPrefix = "$AppName-backend-"

# --- ACR credentials + SAS-URL van het installatiepakket (door leverancier geleverd) ---
$DeployAssetsUrl = Read-NonEmpty "SAS-URL naar het installatiepakket (waarmerk-deploy.zip, van de leverancier)"
while ($true) {
    $AcrUsername = Read-NonEmpty "ACR gebruikersnaam"
    $AcrPasswordSecure = Read-Host "ACR wachtwoord" -AsSecureString
    $AcrPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AcrPasswordSecure))
    if (Test-AcrPullCredential -LoginServer $AcrLoginServer -Username $AcrUsername -Password $AcrPassword -Repository "$AppName-backend") { break }
    Write-Output "  ACR-inloggegevens werken niet (kan geen pull-token krijgen). Probeer opnieuw."
}

# --- Extra tags (optioneel) ---
$extraTags = @()
Write-Output ""
Write-Output "Extra tags voor de resource group (optioneel). Formaat sleutel=waarde, Enter om te stoppen."
while ($true) {
    $t = Read-Host "  tag"
    if ([string]::IsNullOrWhiteSpace($t)) { break }
    if ($t -match '^[^=]+=[^=]*$') { $extraTags += $t.Trim() } else { Write-Output "    Gebruik sleutel=waarde." }
}

# --- Image tag (standaard 'latest'; preview-builds dragen die tag niet) ---
if (-not $ImageTag) { $ImageTag = "latest" }
Write-Output "Image tag: $ImageTag"

# --- Bevestiging ---
Write-Output ""
Write-Output "========================================="
Write-Output " Samenvatting"
Write-Output "========================================="
Write-Output " Modus:          $Mode"
Write-Output " Subscription:   $subName"
Write-Output " Resource Group: $ResourceGroup"
Write-Output " Locatie:        $Location"
Write-Output " Image tag:      $ImageTag"
Write-Output "========================================="
$confirm = Read-Host "Doorgaan? (j/N)"
if ($confirm -notin @("j", "J", "ja", "Ja", "y", "Y", "yes")) { Write-Output "Geannuleerd."; exit 0 }

# --- Installatiepakket downloaden en controleren ---
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("waarmerk-deploy-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$zipPath = Join-Path $workDir "assets.zip"
Write-Output ""
Write-Output "Installatiepakket downloaden..."
try {
    Invoke-WebRequest -Uri $DeployAssetsUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
    Expand-Archive -Path $zipPath -DestinationPath $workDir -Force
} catch {
    Write-Error "Kan het installatiepakket niet downloaden/uitpakken. Controleer of de leverancier een geldige SAS-URL heeft geconfigureerd. ($($_.Exception.Message))"
    exit 1
}
$mainTemplate    = Join-Path $workDir "main.json"
$consentTemplate = Join-Path $workDir "consent.json"
$appsTemplate    = Join-Path $workDir "apps.json"
$portalZip       = Join-Path $workDir "consent-portal.zip"
foreach ($f in @($mainTemplate, $consentTemplate, $appsTemplate, $portalZip)) {
    if (-not (Test-Path $f)) { Write-Error "Installatiepakket is onvolledig: $($f | Split-Path -Leaf) ontbreekt."; exit 1 }
}
Write-Output "Installatiepakket in orde."

# --- Geheimen: hergebruiken indien er al een backend draait, anders nieuw genereren.
# De backend-web-app wordt opgezocht (naam draagt een van de resource group afgeleide
# suffix); zo werkt een update ook zonder de oude naam te kennen. De geheimen staan
# als app settings (env vars) op de backend.
$existingBackendApp = $null
if ($Mode -eq "Update") {
    $existingBackendApp = az webapp list -g $ResourceGroup `
        --query "[?starts_with(name, '$backendAppPrefix')].name | [0]" -o tsv 2>$null
}

if ([string]::IsNullOrWhiteSpace($existingBackendApp)) {
    # Nieuwe installatie (of bestaande resource group zonder backend): verse geheimen.
    $DbAdminPassword  = New-RandomPassword
    $JwtSecret        = New-Base64Secret
    $kp               = New-Es256KeyPair
    $ConsentPrivate   = $kp.Private
    $ConsentPublic    = $kp.Public
} else {
    $DbAdminPassword = az webapp config appsettings list -g $ResourceGroup -n $existingBackendApp --query "[?name=='DB_PASSWORD'].value | [0]" -o tsv 2>$null
    $JwtSecret       = az webapp config appsettings list -g $ResourceGroup -n $existingBackendApp --query "[?name=='JWT_SECRET'].value | [0]" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($DbAdminPassword) -or [string]::IsNullOrWhiteSpace($JwtSecret)) {
        Write-Error "Kan bestaande geheimen (DB_PASSWORD/JWT_SECRET) niet lezen van $existingBackendApp."
        exit 1
    }
    $ConsentPrivate = az webapp config appsettings list -g $ResourceGroup -n $existingBackendApp --query "[?name=='CONSENT_SIGNING_PRIVATE_KEY'].value | [0]" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($ConsentPrivate)) {
        # Portaal was er nog niet: genereer alsnog een paar
        $kp = New-Es256KeyPair; $ConsentPrivate = $kp.Private; $ConsentPublic = $kp.Public
    } else {
        $ConsentPublic = Get-PublicKeyFromPrivate $ConsentPrivate
    }
}

$tempFiles = @()
try {
    # --- Resource group ---
    $tagArgs = @("project=waarmerk") + $extraTags
    az group create --name $ResourceGroup --location $Location --tags @tagArgs --output none
    if ($LASTEXITCODE -ne 0) { Write-Error "Resource group aanmaken/bijwerken mislukt."; exit 1 }

    # --- Infrastructuur (ARM, incrementeel = idempotent) ---
    Write-Output "[1/4] Infrastructuur (PostgreSQL, Storage, VNet, App Service Plan)..."
    $mainParams = Write-ParamFile @{ appName = $AppName; location = $Location; dbAdminPassword = $DbAdminPassword }
    $tempFiles += $mainParams
    $mainOut = Invoke-RgDeployment -ResourceGroup $ResourceGroup -DeploymentName 'waarmerk-main' `
        -TemplateFile $mainTemplate -ParametersFile $mainParams -FailureMessage "Infrastructuur-deployment mislukt."
    $StorageAccountName = $mainOut.storageAccountName.value

    # --- Toestemmingsintake (Service Bus + Function App) ---
    Write-Output "[2/4] Toestemmingsintake frontend (Service Bus + Function App)..."
    $consentParams = Write-ParamFile @{ appName = $AppName; location = $Location; consentSigningPublicKey = $ConsentPublic }
    $tempFiles += $consentParams
    $consent = Invoke-RgDeployment -ResourceGroup $ResourceGroup -DeploymentName 'waarmerk-consent' `
        -TemplateFile $consentTemplate -ParametersFile $consentParams -FailureMessage "Toestemmingsintake-deployment mislukt."
    $funcAppName = $consent.functionAppName.value
    $PortalUrl   = $consent.functionAppUrl.value

    # --- Web Apps (App Service) ---
    Write-Output "[3/4] Web Apps (App Service, image tag: $ImageTag)..."
    $appsParams = Write-ParamFile @{
        appName = $AppName; location = $Location;
        dbAdminPassword = $DbAdminPassword; jwtSecret = $JwtSecret; imageTag = $ImageTag;
        acrLoginServer = $AcrLoginServer; acrUsername = $AcrUsername; acrPassword = $AcrPassword;
        consentSigningPrivateKey = $ConsentPrivate; storageAccountName = $StorageAccountName
    }
    $tempFiles += $appsParams
    $apps = Invoke-RgDeployment -ResourceGroup $ResourceGroup -DeploymentName 'waarmerk-apps' `
        -TemplateFile $appsTemplate -ParametersFile $appsParams -FailureMessage "Web Apps-deployment mislukt."
    $FrontendUrl = $apps.frontendUrl.value

    # --- Portaalcode deployen (prebuilt zip, geen npm nodig) ---
    Write-Output "[4/4] Toestemmingsportaal deployen naar $funcAppName..."
    az functionapp deployment source config-zip -g $ResourceGroup -n $funcAppName --src $portalZip | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Portaal-deploy gaf een fout; controleer de Function App." }

    # =========================================
    #  Klaar + instructies
    # =========================================
    Write-Output ""
    Write-Output "========================================="
    Write-Output " Installatie voltooid"
    Write-Output "========================================="
    Write-Output " Frontend URL:   $FrontendUrl"
    Write-Output " Image tag:      $ImageTag"
    Write-Output ""
    Write-Output " LET OP: de webapp is volledig PRIVÉ (geen publiek internet)."
    Write-Output ""
    Write-Output " EERSTE GEBRUIKER = BEHEERDER"
    Write-Output "========================================="
} finally {
    foreach ($f in $tempFiles) { if ($f -and (Test-Path $f)) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    if ($workDir -and (Test-Path $workDir)) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}
