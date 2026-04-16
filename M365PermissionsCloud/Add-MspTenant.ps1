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
    $AppDisplayNameBackend = "M365Permissions-CrossTenant-Backend"
    $AppDisplayNameFrontend = "M365Permissions-CrossTenant-Frontend"

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
    Write-Host "[1/11] Creating app registration '$AppDisplayNameBackend'..." -ForegroundColor Yellow

    $existingApp = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppDisplayNameBackend'").value | Select-Object -First 1

    $isNewApp = $false
    if ($existingApp) {
        Write-Host "  App registration '$AppDisplayNameBackend' already exists (AppId: $($existingApp.appId)). Reusing."
        $app = $existingApp
    } else {
        $isNewApp = $true
        $appBody = @{
            displayName = $AppDisplayNameBackend
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
    Write-Host "[2/11] Ensuring service principal exists..." -ForegroundColor Yellow

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
        Write-Host "[3/11] Generating self-signed certificate..." -ForegroundColor Yellow

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
        Write-Host "[4/11] Uploading certificate to app registration..." -ForegroundColor Yellow

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
        Write-Host "[3/11] Skipping certificate generation (app already exists)" -ForegroundColor Yellow
        Write-Host "[4/11] Skipping certificate upload (app already exists)" -ForegroundColor Yellow
    }

    # Step 5: Assign required API permissions
    Write-Host "[5/11] Assigning API permissions..." -ForegroundColor Yellow

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
            $Null = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/appRoleAssignments" -Body ($body | ConvertTo-Json -Depth 5)
            Write-Host "  $($role.id) - assigned"
        } catch {
            Write-Error "  Failed to assign $($role.id): $_" -ErrorAction Continue
        }
    }

    # Step 6: Assign Exchange Administrator directory role
    Write-Host "[6/11] Assigning Exchange Administrator directory role..." -ForegroundColor Yellow

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
            $Null = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments" -Body $roleBody
            Write-Host "  Exchange Administrator role assigned"
        } catch {
            Write-Error "  Failed to assign Exchange Administrator role: $_" -ErrorAction Continue
        }
    }

    # Step 7: Create Frontend App Registration for SSO
    Write-Host "[7/11] Creating frontend app registration '$AppDisplayNameFrontend'..." -ForegroundColor Yellow

    $existingFrontendApp = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppDisplayNameFrontend'").value | Select-Object -First 1

    if ($existingFrontendApp) {
        Write-Host "  Frontend app '$AppDisplayNameFrontend' already exists (AppId: $($existingFrontendApp.appId)). Reusing."
        $frontendApp = $existingFrontendApp
    } else {
        $frontendAppBody = @{
            displayName = $AppDisplayNameFrontend
            signInAudience = "AzureADMyOrg"
        } | ConvertTo-Json
        try {
            $frontendApp = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications" -Body $frontendAppBody
            Write-Host "  Created frontend app. AppId: $($frontendApp.appId)"
            Start-Sleep -Seconds 3
        } catch {
            Write-Error "Failed to create frontend app registration: $_"
            return
        }
    }

    $frontendClientId = $frontendApp.appId

    # Step 8: Configure Frontend SPN and SSO permissions
    Write-Host "[8/11] Configuring frontend SPN and SSO permissions..." -ForegroundColor Yellow

    $frontendSpn = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$frontendClientId'").value | Select-Object -First 1

    if (-not $frontendSpn) {
        try {
            $frontendSpn = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body (@{ appId = $frontendClientId } | ConvertTo-Json)
            Write-Host "  Frontend SPN created. ObjectId: $($frontendSpn.id)"
            Start-Sleep -Seconds 3
        } catch {
            Write-Error "Failed to create frontend service principal: $_"
            return
        }
    } else {
        Write-Host "  Frontend SPN already exists. ObjectId: $($frontendSpn.id)"
    }

    # Restrict access to assigned users/groups only
    try {
        Invoke-RestMethod -ContentType "application/json" -Method PATCH -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($frontendSpn.id)" -Body '{"appRoleAssignmentRequired": true}'
        Write-Host "  App role assignment requirement set on frontend SPN"
    } catch {
        Write-Error "  Failed to set appRoleAssignmentRequired: $_" -ErrorAction Continue
    }

    # Add backend SPN as owner of the frontend SPN so it can manage role assignments
    $spnRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($spn.id)" }
    try {
        Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($frontendSpn.id)/owners/`$ref" -Body ($spnRef | ConvertTo-Json)
        Write-Host "  Backend SPN added as owner of frontend SPN"
    } catch {
        Write-Host "  Backend SPN already owner of frontend SPN (or failed: $($_.Exception.Message))"
    }
    
    # Add backend SPN as owner of the frontend app so it can manage sso config
    try {
        Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications/$($frontendApp.id)/owners/`$ref" -Body ($spnRef | ConvertTo-Json)
        Write-Host "  Backend SPN added as owner of frontend APP"
    } catch {
        Write-Host "  Backend SPN already owner of frontend APP (or failed: $($_.Exception.Message))"
    }

    # Configure Graph delegated SSO permissions
    $graphSpn = $resourceSpns | Where-Object { $_.appId -eq "00000003-0000-0000-c000-000000000000" }
    if ($graphSpn) {
        $desiredScopes = @("offline_access", "openid", "User.Read", "email", "profile")
        $resourceAccess = @()
        foreach ($scope in $desiredScopes) {
            $scopeDef = $graphSpn.oauth2PermissionScopes | Where-Object { $_.value -eq $scope }
            if ($scopeDef) {
                $resourceAccess += @{
                    id = $scopeDef.id
                    type = "Scope"
                }
            }
        }

        $ssoBody = @{
            requiredResourceAccess = @(
                @{
                    resourceAppId = "00000003-0000-0000-c000-000000000000"
                    resourceAccess = $resourceAccess
                }
            )
        } | ConvertTo-Json -Depth 5

        try {
            $Null = Invoke-RestMethod -ContentType "application/json" -Method PATCH -Headers $graphHeaders `
                -Uri "https://graph.microsoft.com/v1.0/applications/$($frontendApp.id)" `
                -Body $ssoBody
            Write-Host "  SSO delegated permissions configured (openid, email, profile, offline_access, User.Read)"
        } catch {
            Write-Error "  Failed to configure SSO permissions: $_" -ErrorAction Continue
        }

        # Grant admin consent for delegated scopes
        $oauth2Body = @{
            clientId    = $frontendSpn.id
            consentType = "AllPrincipals"
            resourceId  = $graphSpn.id
            scope       = "openid email profile offline_access User.Read"
        } | ConvertTo-Json -Depth 2
        try {
            $Null = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" -Body $oauth2Body
            Write-Host "  OAuth2 delegated permission grant created (admin consent)"
        } catch {
            Write-Error "  Failed to create OAuth2 permission grant: $_" -ErrorAction Continue
        }
    } else {
        Write-Host "  WARNING: Graph SPN not found in resourceSpns, skipping SSO permission configuration" -ForegroundColor DarkYellow
    }

    # Step 9: Create security groups and set ownership
    Write-Host "[9/11] Creating security groups and configuring ownership..." -ForegroundColor Yellow

    # Determine who's running this script for group ownership
    $userId = $null
    try {
        $me = Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/me" -ErrorAction Stop
        $userId = $me.id
    } catch {
        Write-Host "  WARNING: Could not determine current user. You'll need to add yourself to SEC-APP-M365Permissions-Admins manually." -ForegroundColor DarkYellow
    }

    $desiredGroups = @(
        "SEC-APP-M365Permissions-Admins"
        "SEC-APP-M365Permissions-Users"
        "SEC-SVC-M365Permissions"
    )

    $createdGroups = @{}

    foreach ($groupName in $desiredGroups) {
        $groupState = @{
            displayName     = $groupName
            mailEnabled     = $false
            mailNickname    = $groupName.Replace("-", "_")
            securityEnabled = $true
            groupTypes      = @()
        }

        $group = $null
        $group = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'").value | Select-Object -First 1

        if (-not $group) {
            try {
                $group = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups" -Body ($groupState | ConvertTo-Json)
                Write-Host "  Created security group $groupName (ID: $($group.id))"
                Start-Sleep -Seconds 3
            } catch {
                Write-Error "  Failed to create group $($groupName): $($_.Exception.Message)" -ErrorAction Continue
                continue
            }
        } else {
            Write-Host "  Group $groupName already exists (ID: $($group.id))"
        }

        $createdGroups[$groupName] = $group

        # Add backend SPN as owner
        $spnRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($spn.id)" }
        try {
            Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners/`$ref" -Body ($spnRef | ConvertTo-Json)
            Write-Host "  Backend SPN added as owner of $groupName"
        } catch {
            Write-Host "  Backend SPN already owner of $groupName (or failed: $($_.Exception.Message))"
        }

        # Add backend SPN as member to the SVC group only
        if ($groupName -eq "SEC-SVC-M365Permissions") {
            try {
                Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -Body ($spnRef | ConvertTo-Json)
                Write-Host "  Backend SPN added as member of $groupName"
            } catch {
                Write-Host "  Backend SPN already member of $groupName (or failed: $($_.Exception.Message))"
            }
        }

        # Add current user as owner, and as member for the Admins group
        if ($userId) {
            $userRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" }
            try {
                Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners/`$ref" -Body ($userRef | ConvertTo-Json)
                Write-Host "  You added as owner of $groupName"
            } catch {
                Write-Host "  You are already owner of $groupName (or failed: $($_.Exception.Message))"
            }
            if ($groupName -eq "SEC-APP-M365Permissions-Admins") {
                try {
                    Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -Body ($userRef | ConvertTo-Json)
                    Write-Host "  You added as member of $groupName"
                } catch {
                    Write-Host "  You are already member of $groupName (or failed: $($_.Exception.Message))"
                }
            }
        }
    }

    # Step 10: Define app roles on frontend app and assign groups
    Write-Host "[10/11] Configuring app roles on frontend app and assigning groups..." -ForegroundColor Yellow

    $desiredRoles = @(
        @{
            RoleValue   = "User.Read"
            GroupName   = "SEC-APP-M365Permissions-Users"
            Description = "Read-only access to the application"
            DisplayName = "User"
        },
        @{
            RoleValue   = "Admin.Full"
            GroupName   = "SEC-APP-M365Permissions-Admins"
            Description = "Full admin access to the application"
            DisplayName = "Admin"
        }
    )

    # Refresh the frontend app to get current appRoles
    $frontendApp = Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications/$($frontendApp.id)"

    $appRolesToAdd = @()
    $appRolesChanged = $false

    foreach ($roleInfo in $desiredRoles) {
        $existingRole = $frontendApp.appRoles | Where-Object { $_.value -eq $roleInfo.RoleValue }
        if (-not $existingRole) {
            Write-Host "  App role '$($roleInfo.RoleValue)' not found. Creating..."
            $appRolesChanged = $true
            $appRolesToAdd += @{
                allowedMemberTypes = @("User")
                description        = $roleInfo.Description
                displayName        = $roleInfo.DisplayName
                id                 = [guid]::NewGuid().ToString()
                isEnabled          = $true
                value              = $roleInfo.RoleValue
            }
        } else {
            Write-Host "  App role '$($roleInfo.RoleValue)' already exists"
        }
    }

    if ($appRolesChanged) {
        $updateBody = @{
            appRoles = @($frontendApp.appRoles) + $appRolesToAdd
        } | ConvertTo-Json -Depth 5

        try {
            $Null = Invoke-RestMethod -ContentType "application/json" -Method PATCH -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications/$($frontendApp.id)" -Body $updateBody
            Write-Host "  App roles updated on frontend app"
            Start-Sleep -Seconds 10
            # Refresh to get the new role IDs
            $frontendApp = Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications/$($frontendApp.id)"
        } catch {
            Write-Error "  Failed to update app roles: $_" -ErrorAction Continue
        }
    }

    # Assign security groups to the corresponding app roles on the frontend SPN
    foreach ($roleInfo in $desiredRoles) {
        $group = $createdGroups[$roleInfo.GroupName]
        $appRole = $frontendApp.appRoles | Where-Object { $_.value -eq $roleInfo.RoleValue }

        if ($group -and $appRole) {
            $assignmentBody = @{
                principalId = $group.id
                resourceId  = $frontendSpn.id
                appRoleId   = $appRole.id
            } | ConvertTo-Json -Depth 5

            try {
                $Null = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($frontendSpn.id)/appRoleAssignments" -Body $assignmentBody
                Write-Host "  Assigned group '$($roleInfo.GroupName)' to role '$($roleInfo.RoleValue)'"
            } catch {
                if ($_.Exception.Message -like "*Permission being assigned already exists*") {
                    Write-Host "  Group '$($roleInfo.GroupName)' already assigned to role '$($roleInfo.RoleValue)'"
                } else {
                    Write-Error "  Failed to assign group '$($roleInfo.GroupName)' to role '$($roleInfo.RoleValue)': $_" -ErrorAction Continue
                }
            }
        } elseif (-not $group) {
            Write-Host "  WARNING: Group '$($roleInfo.GroupName)' not found, skipping role assignment" -ForegroundColor DarkYellow
        }
    }

    # Step 11: Summary
    Write-Host "[11/11] Complete!" -ForegroundColor Yellow
    Write-Host ""
    if ($isNewApp) {
        Write-Host "Deployment steps:" -ForegroundColor Yellow
        Write-Host "  1. In the M365Permissions deployment wizard, go to the 'MSP / Cross-Tenant' tab"
        Write-Host "  2. Enable 'Cross-Tenant Scanning'"
        Write-Host "  3. Enter Backend Client ID : $clientId"
        Write-Host "  4. Enter Frontend Client ID: $frontendClientId"
        Write-Host "  5. Upload the PFX file: $pfxFilePath"
        Write-Host "  6. Enter the PFX password: $PfxPassword"
    } else {
        Write-Host "Permissions and roles have been validated/updated." -ForegroundColor Cyan
        Write-Host "Certificate was not regenerated (app already existed)." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Documentation: https://m365permissions.com/#/docs/msp-cross-tenant" -ForegroundColor Cyan
}

invoke-command -scriptblock $authorizeM365Permissions