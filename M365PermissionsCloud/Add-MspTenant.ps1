<#
.SYNOPSIS
    Creates an app registration with required API permissions and a 10-year certificate
    for M365Permissions MSP / cross-tenant scanning.

.DESCRIPTION
    Fully provisions the target tenant for M365Permissions cross-tenant scanning:
    1. Creates an app registration named "M365Permissions-CrossTenant"
    2. Generates a 10-year self-signed certificate (CN={ClientId})
    3. Uploads the certificate credential to the app registration
    4. Assigns all required API permissions (SharePoint, Exchange, Graph)
    5. Assigns the Exchange Administrator directory role
    6. Exports the PFX (for deployment) and CER (for reference)

    You must be logged in as a Global Administrator via Connect-AzAccount before running.
    For full setup instructions, visit: https://m365permissions.com/#/docs/msp-cross-tenant

.NOTES
    After running this function:
    1. Note the ClientId from the output
    2. Upload the .pfx file during M365Permissions deployment (MSP / Cross-Tenant tab)
    3. The PFX password you specified is the same password you provide during deployment
#>

[scriptblock]$authorizeM365Permissions = {
    $AppDisplayName = "M365Permissions-CrossTenant"
    # Verify Azure context
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw "No Azure context found. Please run Connect-AzAccount first."
        }
    } catch {
        Write-Error "Please run Connect-AzAccount -TenantId 'customer-tenant-id' before running this function."
        return
    }

    $tenantId = $context.Tenant.Id
    Write-Host "Using tenant: $tenantId" -ForegroundColor Cyan

    # Get Graph token
    try {
        $graphToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -ErrorAction Stop).Token | ConvertFrom-SecureString -AsPlainText
        $graphHeaders = @{ "Authorization" = "Bearer $graphToken" }
    } catch {
        Write-Error "Failed to get Graph API token: $_"
        return
    }

    $tenantName = ((Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/domains?$top=999").value | Where-Object -Property isInitial -EQ $true | Select-Object -First 1).id

    Write-Host "Detected tenant name: $tenantName"  -ForegroundColor Green

    $Null = Read-Host "Press Enter to continue with app registration creation or Ctrl+C to cancel..."

    # Step 1: Create the app registration
    Write-Host ""
    Write-Host "[1/7] Creating app registration '$AppDisplayName'..." -ForegroundColor Yellow

    $existingApp = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppDisplayName'").value | Select-Object -First 1

    $isNewApp = $false
    if ($existingApp) {
        Write-Host "  App registration '$AppDisplayName' already exists (AppId: $($existingApp.appId)). Reusing."
        $app = $existingApp
    } else {
        $isNewApp = $true
        $appBody = @{
            displayName = $AppDisplayName
            signInAudience = "AzureADMyOrg"
        } | ConvertTo-Json
        try {
            $app = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications" -Body $appBody
            Write-Host "  Created app registration. AppId: $($app.appId)"
            Start-Sleep -Seconds 3
        } catch {
            Write-Error "Failed to create app registration: $_"
            return
        }
    }

    $clientId = $app.appId

    # Step 2: Ensure service principal exists
    Write-Host "[2/7] Ensuring service principal exists..." -ForegroundColor Yellow

    $spn = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$clientId'").value | Select-Object -First 1

    if (-not $spn) {
        try {
            $spn = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body (@{ appId = $clientId } | ConvertTo-Json)
            Write-Host "  Service principal created. ObjectId: $($spn.id)"
            Start-Sleep -Seconds 3
        } catch {
            Write-Error "Failed to create service principal: $_"
            return
        }
    } else {
        Write-Host "  Service principal already exists. ObjectId: $($spn.id)"
    }

    if ($isNewApp) {
        # Step 3: Generate certificate (only for new app registrations)
        Write-Host "[3/7] Generating self-signed certificate..." -ForegroundColor Yellow

        $pfxFilePath = Join-Path -Path (Get-Location).Path -ChildPath "$clientId.pfx"
        $cerFilePath = Join-Path -Path (Get-Location).Path -ChildPath "$clientId.cer"

        $cert = New-SelfSignedCertificate `
            -Subject "CN=$clientId" `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -KeyExportPolicy Exportable `
            -KeySpec Signature `
            -KeyLength 2048 `
            -KeyAlgorithm RSA `
            -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(10)

        Write-Host "  Thumbprint: $($cert.Thumbprint)"

        if (-not $PfxPassword) {
            $PfxPassword = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString())) -replace '[/+=]', '' | Select-Object -First 32
        }
        $securePwd = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $pfxFilePath -Password $securePwd | Out-Null
        Export-Certificate -Cert $cert -FilePath $cerFilePath -Type CERT | Out-Null

        # Step 4: Upload certificate to app registration
        Write-Host "[4/7] Uploading certificate to app registration..." -ForegroundColor Yellow

        $certBytes = [System.IO.File]::ReadAllBytes($cerFilePath)
        $certBase64 = [System.Convert]::ToBase64String($certBytes)

        $keyCredential = @{
            type = "AsymmetricX509Cert"
            usage = "Verify"
            key = $certBase64
            displayName = "M365Permissions Cross-Tenant Certificate"
        }

        try {
            Invoke-RestMethod -ContentType "application/json" -Method PATCH -Headers $graphHeaders `
                -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
                -Body (@{ keyCredentials = @($keyCredential) } | ConvertTo-Json -Depth 5)
            Write-Host "  Certificate uploaded to app registration"
        } catch {
            Write-Error "Failed to upload certificate to app registration: $_" -ErrorAction Continue
        }

        # Remove cert from local store - customer only needs the files
        Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
    } else {
        Write-Host "[3/7] Skipping certificate generation (app already exists)" -ForegroundColor Yellow
        Write-Host "[4/7] Skipping certificate upload (app already exists)" -ForegroundColor Yellow
    }

    # Step 5: Assign required API permissions
    Write-Host "[5/7] Assigning API permissions..." -ForegroundColor Yellow

    $requiredRoles = @(
        @{ resource = "00000003-0000-0ff1-ce00-000000000000"; id = "Sites.FullControl.All" }          # SharePoint
        @{ resource = "00000002-0000-0ff1-ce00-000000000000"; id = "Exchange.ManageAsApp" }            # Exchange
        @{ resource = "00000002-0000-0ff1-ce00-000000000000"; id = "full_access_as_app" }              # Exchange
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "Directory.Read.All" }              # Graph
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "EntitlementManagement.Read.All" }  # Graph
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "RoleEligibilitySchedule.Read.Directory" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "RoleManagement.Read.All" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "Sites.FullControl.All" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "Application.ReadWrite.OwnedBy" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "Mail.Send" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "CloudPC.Read.All" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "PrivilegedAccess.Read.AzureAD" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "PrivilegedEligibilitySchedule.Read.AzureADGroup" }
        @{ resource = "00000003-0000-0000-c000-000000000000"; id = "DeviceManagementRBAC.Read.All" }
    )

    # Ensure resource SPNs exist in the tenant
    $resourceSpns = @()
    foreach ($uniqueResource in ($requiredRoles.resource | Select-Object -Unique)) {
        try {
            $targetSpn = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$uniqueResource'").value
        } catch {
            $targetSpn = $null
        }
        if (-not $targetSpn) {
            Write-Host "  Registering resource SPN $uniqueResource..."
            try {
                $targetSpn = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body (@{ appId = $uniqueResource } | ConvertTo-Json)
                Start-Sleep -Seconds 5
            } catch {
                Write-Error "  Failed to register SPN $($uniqueResource): $_" -ErrorAction Continue
                continue
            }
        }
        if ($targetSpn) {
            $resourceSpns += $targetSpn
        }
    }

    # Get existing role assignments
    $existingRoles = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments").value

    # Assign each required role
    foreach ($role in $requiredRoles) {
        $targetSpn = $resourceSpns | Where-Object { $_.appId -eq $role.resource }
        $fullRole = $targetSpn.appRoles | Where-Object { $_.value -eq $role.id }
        if (-not $fullRole -or -not $targetSpn) {
            Write-Host "  WARNING: Could not find role $($role.id) on resource $($role.resource)" -ForegroundColor DarkYellow
            continue
        }
        $alreadyAssigned = $existingRoles | Where-Object { $_.appRoleId -eq $fullRole.id -and $_.resourceId -eq $targetSpn.id }
        if ($alreadyAssigned) {
            Write-Host "  $($role.id) - already assigned"
            continue
        }
        $body = @{
            principalId = $spn.id
            resourceId  = $targetSpn.id
            appRoleId   = $fullRole.id
        }
        try {
            Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments" -Body ($body | ConvertTo-Json -Depth 5)
            Write-Host "  $($role.id) - assigned"
        } catch {
            Write-Error "  Failed to assign $($role.id): $_" -ErrorAction Continue
        }
    }

    # Step 6: Assign Exchange Administrator directory role
    Write-Host "[6/7] Assigning Exchange Administrator directory role..." -ForegroundColor Yellow

    $dirRoleId = "29232cdf-9323-42fd-ade2-1d097af3e4de" # Exchange Administrator

    $memberOf = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/transitiveMemberOf").value | Where-Object { $_.'@odata.type' -eq "#microsoft.graph.directoryRole" }

    if ($memberOf -and $memberOf.roleTemplateId -contains $dirRoleId) {
        Write-Host "  Exchange Administrator role already assigned"
    } else {
        $roleBody = @{
            '@odata.type'    = "#microsoft.graph.unifiedRoleAssignment"
            roleDefinitionId = $dirRoleId
            principalId      = $spn.id
            directoryScopeId = "/"
        } | ConvertTo-Json

        try {
            Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments" -Body $roleBody
            Write-Host "  Exchange Administrator role assigned"
        } catch {
            Write-Error "  Failed to assign Exchange Administrator role: $_" -ErrorAction Continue
        }
    }

    # Step 7: Summary
    Write-Host "[7/7] Complete!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Cross-tenant setup complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "App Registration:" -ForegroundColor Cyan
    Write-Host "  Display Name : $AppDisplayName"
    Write-Host "  Client ID    : $clientId"
    Write-Host "  Tenant ID    : $tenantId"
    Write-Host "  Object ID    : $($app.id)"
    Write-Host ""
    if ($isNewApp) {
        Write-Host "Certificate:" -ForegroundColor Cyan
        Write-Host "  Thumbprint   : $($cert.Thumbprint)"
        Write-Host "  Password     : $PfxPassword"
        Write-Host "  Expires      : $($cert.NotAfter)"
        Write-Host "  PFX file     : $pfxFilePath"
        Write-Host "  CER file     : $cerFilePath"
        Write-Host ""
        Write-Host "Deployment steps:" -ForegroundColor Yellow
        Write-Host "  1. In the M365Permissions deployment wizard, go to the 'MSP / Cross-Tenant' tab"
        Write-Host "  2. Enable 'Cross-Tenant Scanning'"
        Write-Host "  3. Enter Client ID: $clientId"
        Write-Host "  4. Upload the PFX file: $pfxFilePath"
        Write-Host "  5. Enter the PFX password: $PfxPassword"
    } else {
        Write-Host "Permissions and roles have been validated/updated." -ForegroundColor Cyan
        Write-Host "Certificate was not regenerated (app already existed)." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Documentation: https://m365permissions.com/#/docs/msp-cross-tenant" -ForegroundColor Cyan
}

invoke-command -scriptblock $authorizeM365Permissions