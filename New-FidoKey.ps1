#Requires -Version 7.0
<#
.SYNOPSIS
    Generates a software-based passkey (FIDO2) and provisions it in Entra ID via Microsoft Graph API.
    Requires attestation and key restrictions to be disabled in your Fido (passkey) authentication method settings in Entra ID.

.NOTES
    Author:       Jos Lieben (Lieben Consultancy)
    Created:      2026-02-06
    GitHub:       https://github.com/jflieben
    Web/Blog:     www.lieben.nu
    License:      Free to use! Please keep headers intact to give credit to the author.

.DESCRIPTION
    This script:
    1. Authenticates to Microsoft Graph (beta) using client credentials (client_id + client_secret) or an existing access token
    2. Retrieves WebAuthn creation options (challenge) from the creationOptions endpoint
    3. Generates an EC P-256 key pair locally (software virtual authenticator)
    4. Constructs the attestation object and client data JSON per the WebAuthn spec
    5. POSTs the credential to Entra ID to register it as a FIDO2 authentication method

    NOTE: This creates a "none" attestation software passkey. It is NOT backed by a hardware
    security key. The private key is exported and saved locally so it can be used for authentication.
    This is primarily useful for testing, automation, or pre-provisioning scenarios.

.PARAMETER UserUpn
    The user's UPN in Entra ID.

.PARAMETER DisplayName
    The display name for the passkey in Entra ID.

.PARAMETER ClientId
    The application (client) ID of the app registration with 
    UserAuthenticationMethod.ReadWrite.All application permission

.PARAMETER ClientSecret
    The client secret for the app registration.

.PARAMETER outputFilePath
    Path to save the private key and credential info. Defaults to current directory.

.EXAMPLE
    .\New-FidoKey.ps1 -UserId "user@contoso.com" -DisplayName "Provisioned Passkey" -ClientId "your-app-id" -ClientSecret "your-secret"
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory=$true)]
    [string]$UserUpn="jos@lieben.nu",
    [Parameter(Mandatory=$false)]
    [string]$DisplayName = "Provisioned Passkey",
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret,
    [Parameter(Mandatory=$false)]
    [String]$outputFilePath
)

$ErrorActionPreference = "Stop"

#region Helper Functions

function ConvertTo-Base64Url {
    <#
    .SYNOPSIS
        Converts a byte array to a Base64URL-encoded string (no padding).
    #>
    param([byte[]]$Bytes)
    $base64 = [Convert]::ToBase64String($Bytes)
    return $base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    <#
    .SYNOPSIS
        Converts a Base64URL-encoded string back to a byte array.
    #>
    param([string]$Base64Url)
    $base64 = $Base64Url.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        2 { $base64 += "==" }
        3 { $base64 += "=" }
    }
    return [Convert]::FromBase64String($base64)
}

function New-CBOREncoded {
    <#
    .SYNOPSIS
        Minimal CBOR encoder for the attestation object structure.
        Supports maps, byte strings, text strings, integers, and arrays.
    #>
    param($Value)

    $byteListType = 'System.Collections.Generic.List[byte]'

    # CBOR Map (hashtable or ordered dictionary)
    if ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        $entries = New-Object $byteListType
        foreach ($entry in $Value.GetEnumerator()) {
            $keyEncoded = New-CBOREncoded $entry.Key
            $valEncoded = New-CBOREncoded $entry.Value
            $entries.AddRange([byte[]]$keyEncoded)
            $entries.AddRange([byte[]]$valEncoded)
        }
        $result = New-Object $byteListType
        $mapCount = $Value.Count
        if ($mapCount -lt 24) {
            $result.Add([byte](0xA0 + $mapCount))
        }
        else {
            $result.Add([byte]0xB8)
            $result.Add([byte]$mapCount)
        }
        $result.AddRange($entries)
        return , $result.ToArray()
    }

    # CBOR Byte String
    if ($Value -is [byte[]]) {
        $len = $Value.Length
        $result = New-Object $byteListType
        if ($len -lt 24) {
            $result.Add([byte](0x40 + $len))
        }
        elseif ($len -lt 256) {
            $result.Add([byte]0x58)
            $result.Add([byte]$len)
        }
        elseif ($len -lt 65536) {
            $result.Add([byte]0x59)
            $u16 = [uint16]$len
            $lenBytes = [System.BitConverter]::GetBytes($u16)
            if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBytes) }
            $result.AddRange([byte[]]$lenBytes)
        }
        $result.AddRange([byte[]]$Value)
        return , $result.ToArray()
    }

    # CBOR Text String
    if ($Value -is [string]) {
        $strBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $len = $strBytes.Length
        $result = New-Object $byteListType
        if ($len -lt 24) {
            $result.Add([byte](0x60 + $len))
        }
        elseif ($len -lt 256) {
            $result.Add([byte]0x78)
            $result.Add([byte]$len)
        }
        elseif ($len -lt 65536) {
            $result.Add([byte]0x79)
            $u16 = [uint16]$len
            $lenBytes = [System.BitConverter]::GetBytes($u16)
            if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBytes) }
            $result.AddRange([byte[]]$lenBytes)
        }
        $result.AddRange([byte[]]$strBytes)
        return , $result.ToArray()
    }

    # CBOR Unsigned/Negative Integer
    if ($Value -is [int] -or $Value -is [long]) {
        if ($Value -ge 0) {
            if ($Value -lt 24) {
                return , [byte[]]@([byte]$Value)
            }
            elseif ($Value -lt 256) {
                return , [byte[]]@(0x18, [byte]$Value)
            }
            elseif ($Value -lt 65536) {
                $u16 = [uint16]$Value
                $numBytes = [System.BitConverter]::GetBytes($u16)
                if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($numBytes) }
                $out = [byte[]]::new(3)
                $out[0] = 0x19
                $out[1] = $numBytes[0]
                $out[2] = $numBytes[1]
                return , $out
            }
        }
        else {
            $posVal = -1 - $Value
            if ($posVal -lt 24) {
                return , [byte[]]@([byte](0x20 + $posVal))
            }
            elseif ($posVal -lt 256) {
                return , [byte[]]@(0x38, [byte]$posVal)
            }
            elseif ($posVal -lt 65536) {
                $u16 = [uint16]$posVal
                $numBytes = [System.BitConverter]::GetBytes($u16)
                if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($numBytes) }
                $out = [byte[]]::new(3)
                $out[0] = 0x39
                $out[1] = $numBytes[0]
                $out[2] = $numBytes[1]
                return , $out
            }
        }
    }

    # CBOR Array
    if ($Value -is [array]) {
        $arrCount = $Value.Count
        $result = New-Object $byteListType
        if ($arrCount -lt 24) {
            $result.Add([byte](0x80 + $arrCount))
        }
        else {
            $result.Add([byte]0x98)
            $result.Add([byte]$arrCount)
        }
        foreach ($item in $Value) {
            $encoded = New-CBOREncoded $item
            $result.AddRange([byte[]]$encoded)
        }
        return , $result.ToArray()
    }

    throw "Unsupported CBOR type: $($Value.GetType().Name)"
}

function New-AttestationObject {
    <#
    .SYNOPSIS
        Creates a WebAuthn attestation object with "none" attestation format.
    .PARAMETER AuthData
        The authenticator data bytes.
    #>
    param([byte[]]$AuthData)

    # attestation object is a CBOR map: { "fmt": "none", "attStmt": {}, "authData": <bytes> }
    $attObj = [ordered]@{
        "fmt"      = "none"
        "attStmt"  = [ordered]@{}
        "authData" = $AuthData
    }

    return New-CBOREncoded $attObj
}

function New-AuthenticatorData {
    <#
    .SYNOPSIS
        Constructs the authenticator data for credential creation.
    .PARAMETER RpIdHash
        SHA-256 hash of the relying party ID.
    .PARAMETER CredentialId
        The credential ID bytes.
    .PARAMETER PublicKeyX
        The X coordinate of the EC public key.
    .PARAMETER PublicKeyY
        The Y coordinate of the EC public key.
    #>
    param(
        [byte[]]$RpIdHash,
        [byte[]]$CredentialId,
        [byte[]]$PublicKeyX,
        [byte[]]$PublicKeyY
    )

    $result = New-Object 'System.Collections.Generic.List[byte]'

    # rpIdHash (32 bytes)
    $result.AddRange($RpIdHash)

    # flags: UP (0x01) | UV (0x04) | AT (0x40) | BE (0x08) | BS (0x10) = 0x5D
    $result.Add([byte]0x5D)

    # signCount (4 bytes, big-endian, starting at 0)
    $result.AddRange([byte[]]@(0, 0, 0, 0))

    # attestedCredentialData
    # AAGUID (16 bytes) - all zeros for software authenticator
    $result.AddRange([byte[]]::new(16))

    # credentialIdLength (2 bytes, big-endian)
    $credIdLen = $CredentialId.Length
    $result.Add([byte](($credIdLen -shr 8) -band 0xFF))
    $result.Add([byte]($credIdLen -band 0xFF))

    # credentialId
    $result.AddRange($CredentialId)

    # credentialPublicKey (COSE_Key format, CBOR-encoded EC2 key)
    # {1: 2, 3: -7, -1: 1, -2: x, -3: y}
    $coseKey = [ordered]@{
        [int]1    = [int]2          # kty: EC2
        [int]3    = [int]-7         # alg: ES256
        [int]-1   = [int]1          # crv: P-256
        [int]-2   = [byte[]]$PublicKeyX  # x coordinate
        [int]-3   = [byte[]]$PublicKeyY  # y coordinate
    }
    $coseKeyBytes = New-CBOREncoded $coseKey
    $result.AddRange($coseKeyBytes)

    return $result.ToArray()
}

#endregion

#region Authentication

$TenantId = (Invoke-RestMethod "https://login.microsoftonline.com/$($UserUpn.Split("@")[1])/.well-known/openid-configuration" -Method GET).userinfo_endpoint.Split("/")[3]

Write-Host "`n=== Authenticating via Client Credentials ==="  -ForegroundColor Cyan
$tokenBody = @{
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = "https://graph.microsoft.com/.default"
    grant_type    = "client_credentials"
}

try {
    $tokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $tokenBody
} catch {
    Write-Error "Failed to acquire token: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) {
        Write-Error $_.ErrorDetails.Message
    }
    throw
}

$AccessToken = $tokenResponse.access_token
Write-Host "Authentication successful!" -ForegroundColor Green

$headers = @{
    "Authorization" = "Bearer $AccessToken"
}

#endregion

#region Step 1: Get Creation Options (Challenge)

Write-Host "`n=== Step 1: Retrieving creation options from Entra ID ===" -ForegroundColor Cyan

$creationOptionsUri = "https://graph.microsoft.com/beta/users/$UserUpn/authentication/fido2Methods/creationOptions(challengeTimeoutInMinutes=10)"

try {
    $creationOptionsResponse = Invoke-RestMethod -Method GET -Uri $creationOptionsUri -Headers $headers
} catch {
    Write-Error "Failed to retrieve creation options: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) {
        Write-Error $_.ErrorDetails.Message
    }
    throw
}

$creationOptions = $creationOptionsResponse.value
if (-not $creationOptions) {
    $creationOptions = $creationOptionsResponse
}

$publicKeyOptions = $creationOptions.publicKey
$challenge = $publicKeyOptions.challenge
$rpId = $publicKeyOptions.rp.id
$rpName = $publicKeyOptions.rp.name
$userId = $publicKeyOptions.user.id
$userDisplayName = $publicKeyOptions.user.displayName
$userName = $publicKeyOptions.user.name

Write-Host "  RP ID:           $rpId" -ForegroundColor Gray
Write-Host "  RP Name:         $rpName" -ForegroundColor Gray
Write-Host "  User:            $userName ($userDisplayName)" -ForegroundColor Gray
Write-Host "  Challenge:       $($challenge.Substring(0, [Math]::Min(40, $challenge.Length)))..." -ForegroundColor Gray
Write-Host "  Challenge Timeout: $($creationOptions.challengeTimeoutDateTime)" -ForegroundColor Gray

#endregion

#region Step 2: Generate Key Pair & Credential

Write-Host "`n=== Step 2: Generating EC P-256 key pair (software passkey) ===" -ForegroundColor Cyan

# Generate an EC P-256 key pair using .NET
# Note: ECDsa.Create() defaults to nistP256 (256-bit key)
$ecDsa = [System.Security.Cryptography.ECDsa]::Create()
$ecDsa.KeySize = 256
$ecParams = $ecDsa.ExportParameters($true)

$publicKeyX = $ecParams.Q.X   # 32 bytes
$publicKeyY = $ecParams.Q.Y   # 32 bytes
$privateKeyD = $ecParams.D    # 32 bytes

Write-Host "  Key pair generated successfully" -ForegroundColor Green
Write-Host "  Public Key X: $(ConvertTo-Base64Url $publicKeyX)" -ForegroundColor Gray
Write-Host "  Public Key Y: $(ConvertTo-Base64Url $publicKeyY)" -ForegroundColor Gray

# Generate a random credential ID (32 bytes)
$credentialIdBytes = [byte[]]::new(32)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($credentialIdBytes)
$credentialIdB64Url = ConvertTo-Base64Url $credentialIdBytes

Write-Host "  Credential ID:  $credentialIdB64Url" -ForegroundColor Gray

#endregion

#region Step 3: Build clientDataJSON

Write-Host "`n=== Step 3: Building WebAuthn response data ===" -ForegroundColor Cyan

# clientDataJSON per WebAuthn spec
$clientData = @{
    type      = "webauthn.create"
    challenge = $challenge
    origin    = "https://login.microsoft.com"
} | ConvertTo-Json -Compress

$clientDataBytes = [System.Text.Encoding]::UTF8.GetBytes($clientData)
$clientDataB64Url = ConvertTo-Base64Url $clientDataBytes

Write-Host "  clientDataJSON built" -ForegroundColor Gray

#endregion

#region Step 4: Build authenticator data & attestation object

# Hash the RP ID for authenticator data
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$rpIdHash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($rpId))

# Build authenticator data
$authData = New-AuthenticatorData `
    -RpIdHash $rpIdHash `
    -CredentialId $credentialIdBytes `
    -PublicKeyX $publicKeyX `
    -PublicKeyY $publicKeyY

Write-Host "  Authenticator data built ($($authData.Length) bytes)" -ForegroundColor Gray

# Build attestation object (none format - no attestation statement)
$attestationObjectBytes = New-AttestationObject -AuthData $authData
$attestationObjectB64Url = ConvertTo-Base64Url $attestationObjectBytes

Write-Host "  Attestation object built ($($attestationObjectBytes.Length) bytes)" -ForegroundColor Gray

#endregion

#region Step 5: Register the passkey in Entra ID

Write-Host "`n=== Step 4: Registering passkey in Entra ID ===" -ForegroundColor Cyan

$registrationBody = @{
    displayName         = $DisplayName
    publicKeyCredential = @{
        id       = $credentialIdB64Url
        response = @{
            clientDataJSON    = $clientDataB64Url
            attestationObject = $attestationObjectB64Url
        }
    }
} | ConvertTo-Json -Depth 10

$registerUri = "https://graph.microsoft.com/beta/users/$UserUpn/authentication/fido2Methods"

Write-Host "  Sending registration request..." -ForegroundColor Gray

try {
    $registerResponse = Invoke-RestMethod -Method POST -Uri $registerUri -Headers $headers -Body $registrationBody -ContentType "application/json; charset=utf-8"
    Write-Host "`n  Passkey registered successfully!" -ForegroundColor Green
    Write-Host "  Method ID:      $($registerResponse.id)" -ForegroundColor Gray
    Write-Host "  Display Name:   $($registerResponse.displayName)" -ForegroundColor Gray
    Write-Host "  AAGUID:         $($registerResponse.aaGuid)" -ForegroundColor Gray
    Write-Host "  Model:          $($registerResponse.model)" -ForegroundColor Gray
    Write-Host "  Attestation:    $($registerResponse.attestationLevel)" -ForegroundColor Gray
    Write-Host "  Created:        $($registerResponse.createdDateTime)" -ForegroundColor Gray
} catch {
    Write-Error "Failed to register passkey: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) {
        $errDetail = $_.ErrorDetails.Message
        Write-Error $errDetail
        try {
            $parsed = $errDetail | ConvertFrom-Json
            if ($parsed.error.message) {
                Write-Host "`n  Error detail: $($parsed.error.message)" -ForegroundColor Red
            }
        } catch {}
    }
    throw
}

#endregion

#region Step 6: Save private key for future authentication

Write-Host "`n=== Step 5: Saving credential data ===" -ForegroundColor Cyan

$credentialInfo = @{
    credentialId       = $credentialIdB64Url
    relyingParty       = $rpId
    url                = "https://$rpId"
    userHandle         = $userId
    userName           = $userName
    displayName        = $DisplayName
    methodId           = $registerResponse.id
    createdDateTime    = $registerResponse.createdDateTime
}

# Export private key in PEM format (PKCS#8)
$pkcs8Bytes = $ecDsa.ExportPkcs8PrivateKey()
$pemBase64 = [Convert]::ToBase64String($pkcs8Bytes, [Base64FormattingOptions]::InsertLineBreaks)
$pem = "-----BEGIN PRIVATE KEY-----$($pemBase64)-----END PRIVATE KEY-----"
$credentialInfo.privateKey = $pem

if(!$outputFilePath){
    $outputFilePath = Join-Path -Path (Get-Location) -ChildPath "$($UserUpn.Split("@")[0])_$($DisplayName.Replace(" ", "_"))_credential.json"
}

$credentialInfo | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputFilePath -Encoding UTF8

Write-Host "  Credential saved to: $outputFilePath" -ForegroundColor Green
Write-Host ""
Write-Host "  !! IMPORTANT: The file contains the private key. Keep it secure! !!" -ForegroundColor Red
Write-Host ""

# Cleanup
$ecDsa.Dispose()
$sha256.Dispose()

#endregion

Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Passkey '$DisplayName' has been provisioned for user $userName" -ForegroundColor Green
Write-Host ""
