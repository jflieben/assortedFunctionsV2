#M365Permissions Cloud post-install authorization script for those who do not wish to use the automated wizard
#Author: Jos Lieben
#Help: https://m365permissions.com/#/docs/support#manual-authorization
#This script will create 3 security groups to manage access to the tool, assign the required API permissions to the managed identity of the VM and set up SSO for the frontend
#It will match our VM and frontend by search for a VM and a Web App with the correct naming convention (m365vm* and m365pf*)
#It will not touch anything else
#You have to be logged in as a Global Administrator

[scriptblock]$authorizeM365Permissions = {
    
    ########## ! REQUIRED CONFIGURATION ! #################
    $SubscriptionId = "xxxxx-xxxxxx-xxxxx-xxxxx-xxxxx" #"YOUR AZURE SUBSCRIPTION ID"
    $EnableOrchestration = $False #recommended to set to #True if your tenant has > 3500 users, required if your tenant has > 5000 users
    ########## ! END OF REQUIRED CONFIGURATION ! ##########

    Function Abort-Install($reason){
        Write-Error $reason -ErrorAction Continue
        Read-Host "Press any key to exit"
        [System.Environment]::Exit(1)
    }

    if($SubscriptionId -ne "xxxxx-xxxxxx-xxxxx-xxxxx-xxxxx"){
        # Authenticate
        try{
            Set-AzContext -SubscriptionId $SubscriptionId -Force
            $Context = Get-AzContext
            if (!$Context) {
                Throw "Please login using Connect-AzAccount before running this script, automatic login failed"
            }
        }catch{Abort-Install $_}
    }else{
        Write-Error "You did not configure `$SubscriptionId, we'll try to auto detect. If the script ends up failing, please correct and rerun the script." -ErrorAction Continue
    }

    $SubscriptionId = $Context.Subscription.Id
    $TenantId = $Context.Tenant.Id

    Write-Host "Using Subscription: $($Context.Subscription.Name) ($SubscriptionId) in Tenant $TenantId"

    # Get Graph Access Token
    try {
        $graphToken = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -As -ErrorAction Stop).Token | ConvertFrom-SecureString -AsPlainText
        $graphHeaders = @{"Authorization" = "Bearer $($graphToken)"}
    }catch{Abort-Install $_}

    # Discover Resources
    Write-Host "Searching for resources..."
    $vm = Get-AzResource -ResourceType "Microsoft.Compute/virtualMachines" | Where-Object { $_.Name -like "m365vm*" } | Select-Object -First 1
    if (!$vm) {
        Abort-Install "No VM found starting with 'm365vm' in subscription $SubscriptionId, you have to run the marketplace wizard for M365Permissions first"
    }

    $frontEnd = Get-AzResource -ResourceType "Microsoft.Web/sites" | Where-Object { $_.Name -like "m365pf*" } | Select-Object -First 1
    if (!$frontEnd) {
        Abort-Install "No Frontend Web App found starting with 'm365pf' in subscription $SubscriptionId, you have to run the marketplace wizard for M365Permissions first"
    }

    # Get Frontend URL
    $fullWebApp = Get-AzWebApp -Name $frontEnd.Name -ResourceGroupName $frontEnd.ResourceGroupName
    $frontendUrl = "https://$($fullWebApp.DefaultHostName)"
    $feName = "M365PermissionsPortal-$($frontEnd.Name) (Single Sign-On)"

    Write-Host "Installed Resource Group: $($vm.ResourceGroupName)"
    Write-Host "Frontend URL: $frontendUrl"
    Write-Host "Managed Identity Name: $($vm.Name)"
    Write-Host "Frontend Entra Object for SSO: $feName"

    # Find managed identity of the VM in Graph
    Write-Host "Getting managed identity of the VM that needs to be authorized"
    $managedIdentity = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$Filter=displayName eq '$($vm.Name)'").value | Select-Object -First 1
    if (!$managedIdentity) {
        Abort-Install "Could not find Managed Identity SPN: $($vm.Name)"
    }

    Write-Host "Got MI $($managedIdentity.id), checking SPN's of API's..."
    $appRoles = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($managedIdentity.id)/appRoleAssignments").value

    $requiredRoles = @(
        @{
            "resource" = "00000003-0000-0ff1-ce00-000000000000" #Sharepoint Online
            "id" = "Sites.FullControl.All" #Sites.FullControl.All
        }
        @{
            "resource" = "00000002-0000-0ff1-ce00-000000000000" #Exchange Online
            "id" = "Exchange.ManageAsApp" #Exchange.ManageAsApp
        }
        @{
            "resource" = "00000002-0000-0ff1-ce00-000000000000" #Exchange Online
            "id" = "full_access_as_app" #full_access_as_app
        }        
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "Directory.Read.All" #Directory.Read.All
        }   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "EntitlementManagement.Read.All" #EntitlementManagement.Read.All
        }   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "RoleEligibilitySchedule.Read.Directory" #RoleEligibilitySchedule.Read.Directory
        }   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "RoleManagement.Read.All" #RoleManagement.Read.All
        }      
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "Sites.FullControl.All" #Sites.FullControl.All
        }    
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "Application.ReadWrite.OwnedBy" #Application.ReadWrite.OwnedBy
        }            
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "Mail.Send" #Mail.Send
        }                                   
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "CloudPC.Read.All" #CloudPC.Read.All 
        }
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "PrivilegedAccess.Read.AzureAD" #PrivilegedAccess.Read.AzureAD
        } 
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "PrivilegedEligibilitySchedule.Read.AzureADGroup" #PrivilegedEligibilitySchedule.Read.AzureADGroup
        } 
        @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "DeviceManagementRBAC.Read.All" #DeviceManagementRBAC.Read.All
        }
    )    

    if($EnableOrchestration){
        Write-Host "Orchestration is enabled, adding additional roles so the MI can authorize child MI's..."
        $requiredRoles += @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "Application.ReadWrite.All" #https://graph.microsoft.com/Application.ReadWrite.All
        }
        $requiredRoles += @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "AppRoleAssignment.ReadWrite.All" #https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All
        }
        $requiredRoles += @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "Directory.ReadWrite.All" #https://graph.microsoft.com/Directory.ReadWrite.All
        }
        $requiredRoles += @{
            "resource" = "00000003-0000-0000-c000-000000000000" #Graph API
            "id" = "RoleManagement.ReadWrite.Directory" #https://graph.microsoft.com/RoleManagement.ReadWrite.Directory
        }    
    }

    #checking if base SPN's exist in the tenant, in some fringe cases they need to be registered (non destructively)
    $spns = @()
    foreach($uniqueResource in ($requiredRoles.resource | Select-Object -Unique)){
        try{
            $targetSpn = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($uniqueResource)'").value
            Write-Host "Detected required SPN $($uniqueResource) $($targetSpn.displayName) with ID $($targetSpn.id)"
        }catch { 
            $targetSpn = $null 
            Write-Host "Failed to detect required SPN $uniqueResource, we will attempt to register"
        }
        if (!$targetSpn) {
            Write-Host "Required SPN $($uniqueResource) not detected, creating..."
            $desiredState = @{
                "appId" = $uniqueResource
            }
            try {
                $targetSpn = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body ($desiredState | ConvertTo-Json)
                Write-Host "SPN registered, waiting 5 seconds..."
                Start-Sleep -s 5
                Write-Host "Created required SPN $($uniqueResource) $($targetSpn.displayName) with ID $($targetSpn.id)"
            } catch {
                Write-Error $_ -ErrorAction Continue
                $targetSpn = $null
            }
        }

        if($targetSpn){
            $spns += $targetSpn
        }
    }    

    Write-Host "SPN's checked, checking for MI's roles..."
    # Remove any roles that are not in the required list
    foreach ($appRole in $appRoles) {
        $targetSpn = $Null; $targetSpn = $spns | Where-Object { $_.id -eq $appRole.resourceId }
        $fullRole = $null; $fullRole = $targetSpn.appRoles | Where-Object { $_.id -eq $appRole.appRoleId}
        if($requiredRoles.id -notcontains $fullRole.value){
            try {
                Write-Host "Removing unneeded app role assignment $($appRole.appRoleId) from managed identity."
                $uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$($managedIdentity.id)/appRoleAssignments/$($appRole.id)"
                Invoke-RestMethod -Method DELETE -Uri $uri -Headers $graphHeaders -ErrorAction Stop
                Write-Host "Successfully removed role."
            } catch {
                Write-Error "Failed to remove app role assignment $($appRole.id): $_" -ErrorAction Continue
            }
        }
    }

    # Add any required roles that are missing
    foreach ($role in $requiredRoles) {
        if ($null -eq $role.id -or $null -eq $role.resource) { continue }
        $targetSpn = $Null; $targetSpn = $spns | Where-Object { $_.appId -eq $role.resource }
        $fullRole = $null; $fullRole = $targetSpn.appRoles | Where-Object { $_.value -eq $role.id}        
        if($fullRole -and $targetSpn -and ($appRoles | Where-Object { $_.appRoleId -eq $fullRole.id -and $_.resourceId -eq $targetSpn.id }).Count -eq 0){
            $body = @{
                principalId = $managedIdentity.Id
                resourceId  = $targetSpn.id
                appRoleId   = $fullRole.id
            }
            try {
                Write-Host "Adding approle $($role.id)..."
                Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($managedIdentity.id)/appRoleAssignments" -Body ($body | ConvertTo-Json -Depth 15)
                Write-Host "Added approle $($role.id) :)"
            }catch {
                Write-Error $_ -ErrorAction Continue
            }
        }
    }    

    Write-Host "API roles checked, checking directory roles..."

    $dirRoleId = "29232cdf-9323-42fd-ade2-1d097af3e4de" #Exchange Administrator. If desired can be replaced with 88d8e3e3-8f55-4a1e-953a-9b9898b8876b (Directory Read) but has a slight impact on functionality, see https://m365permissions.com/#/docs/support#required-permissions for more info

    $userRoles = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($managedIdentity.Id)/transitiveMemberOf").value | Where-Object { $_.'@odata.type' -eq "#microsoft.graph.directoryRole" }
    if (!$userRoles -or $userRoles.roleTemplateId -notcontains $dirRoleId) {
        Write-Host "assigning entra role..."
        $desiredState = @{
            '@odata.type'    = "#microsoft.graph.unifiedRoleAssignment"
            roleDefinitionId = $dirRoleId
            principalId      = $managedIdentity.Id
            directoryScopeId = "/"
        }
        try {
            $null = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignments" -Body ($desiredState | ConvertTo-Json)
            Write-Host "Role assigned"
        } catch {
            Write-Error "Failed to assign directory role: $_" -ErrorAction Continue
        }
    }

    Write-Host "Directory roles configured, setting SSO config on the frontend SPN...."
    $app = (Invoke-RestMethod -ContentType "application/json" -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$feName'" -Headers $graphHeaders).value | Select-Object -First 1
    if($app){
        Write-Host "Detected existing SSO SPN $($app.displayName) for Frontend"
    }else{
        Write-Host "Creating SSO SPN $feName for Frontend..."
        $desiredState = @{
            "displayName" = $feName
        }
        try {
            $app = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications" -Body ($desiredState | ConvertTo-Json)
            Write-Host "$feName created, waiting 5 seconds..."
            Start-Sleep -s 5  
        }catch{Abort-Install $_}
    }

    $spn = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$Filter=appId eq '$($app.appId)'").value
    if(!$spn){
        $desiredState = @{
            "appId" = $app.appId
        }
        try {
            $spn = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Body ($desiredState | ConvertTo-Json)
            Write-Host "SPN added to $($app.displayName)"
        }catch{Abort-Install $_}
    }    

    Write-Host "adding MI as owner of app & spn so it can manage its lifecycle"
    $owner = "{`"@odata.id`": `"https://graph.microsoft.com/v1.0/directoryObjects/$($managedIdentity.id)`"}"
    try{Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/owners/`$ref" -Body $owner}catch{}#this only goes wrong during reruns, which is fine
    try{Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)/owners/`$ref" -Body $owner}catch{}
    
    Write-Host "Ensuring only specific groups can access the frontend...."
    try {
        Invoke-RestMethod -ContentType "application/json" -Method PATCH -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spn.id)" -Body '{"appRoleAssignmentRequired": true}'
        Write-Host "Assignment requirement set for SPN $($spn.displayName)"
    }catch{Abort-Install $_}

    # determine who's running this script, so we can make that user an owner and member of the relevant security groups
    try {
        $me = Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/me" -ErrorAction Stop
        $userId = $me.id  
    }catch{
        Write-Error "Could not determine who's running this script, you'll have to add yourself as member or owner to SEC-APP-M365Permissions-Admins manually!" -ErrorAction Continue
    }     

    # Create security groups customer can use to manage access by and to the tool
    $desiredGroups = @(
        "SEC-APP-M365Permissions-Admins"
        "SEC-APP-M365Permissions-Users"
        "SEC-SVC-M365Permissions"
    )

    foreach($groupName in $desiredGroups){
        $groupState = @{
            "displayName" = $groupName
            "mailEnabled" = $false
            "mailNickname" = $groupName.Replace("-","_")
            "securityEnabled" = $true
            "groupTypes" = @()
        }
        $group = $Null; $group = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$groupName'").value
        if(!$group){
            $group = try {
                Write-Host "Creating $groupName"
                
                Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups" -Body ($groupState | ConvertTo-Json)
                Write-Host "Created security group $groupName with ID $($group.id)"
            } catch {
                Write-Error "Failed to create group $($groupName): $($_.Exception.Message)" -ErrorAction Continue
            }
        }else{
            Write-Host "Detected existing group $($groupName) with ID $($group.id)"
        }       
        
        # Add MI as owner
        $miRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($managedIdentity.Id)" }
        try {
            Write-Host "Adding MI as owner of group $groupName"
            Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners/`$ref" -Body ($miRef | ConvertTo-Json)
            Write-Host "MI added as owner of group $groupName"
        } catch {}    
        
        # Add MI as member to the SVC group only
        if($groupName -eq "SEC-SVC-M365Permissions"){
            try {
                Write-Host "Adding MI as member of group $groupName"
                Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -Body ($miRef | ConvertTo-Json)
                Write-Host "MI added as member of group $groupName"
            } catch {}    
        }         

        #add the user as owner and for the admin group as member as well
        if ($userId) {
            $userRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" }
            try {
                Write-Host "Adding you as owner of group $groupName"
                Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/owners/`$ref" -Body ($userRef | ConvertTo-Json)
                Write-Host "User added as owner of group $groupName"
            } catch {}
            if($groupName -eq "SEC-APP-M365Permissions-Admins"){
                try {
                    Write-Host "Adding you as member of group $groupName"
                    Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" -Body ($userRef | ConvertTo-Json)
                    Write-Host "Added you as member of group $groupName"
                } catch {}
            }
        }        
    }

    Write-Host "Access Groups configured, configuring SSO permissions on the SPN..."
    $graphSpn = $spns | Where-Object { $_.appId -eq "00000003-0000-0000-c000-000000000000" } # Microsoft Graph SPN
    $desiredState = @{
        "requiredResourceAccess" = @(
            @{
                "resourceAppId" = "00000003-0000-0000-c000-000000000000";
                "resourceAccess" = @(
                    @{
                        "id"= ($graphSpn.oauth2PermissionScopes | where-Object{$_.value -eq "offline_access"}).id
                        "type"= "Scope"
                    },
                    @{
                        "id"=($graphSpn.oauth2PermissionScopes | where-Object{$_.value -eq "openid"}).id
                        "type"= "Scope"
                    },
                    @{
                        "id"= ($graphSpn.oauth2PermissionScopes | where-Object{$_.value -eq "User.Read"}).id
                        "type"= "Scope"
                    },
                    @{
                        "id"= ($graphSpn.oauth2PermissionScopes | where-Object{$_.value -eq "email"}).id
                        "type"= "Scope"
                    },
                    @{
                        "id"= ($graphSpn.oauth2PermissionScopes | where-Object{$_.value -eq "profile"}).id
                        "type"= "Scope"
                    }
                )
            }
        );
        "publicClient" = @{
            "redirectUris" =@(
                "$($frontendUrl)/api/entra/response"
            )
        }      
    } | ConvertTo-Json -Depth 4

    $Null = Invoke-RestMethod -ContentType "application/json" -Method PATCH -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" -Body $desiredState

    try {
        $targetSpn = $null; $targetSpn = (Invoke-RestMethod -ContentType "application/json" -Method GET -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')")
    }catch{Abort-Install $_}

    $desiredState = @{
        "clientId"    = $spn.id
        "consentType" = "AllPrincipals"
        "resourceId"  = $targetSpn.id
        "scope"       = "openid email profile offline_access"
    } | ConvertTo-Json -Depth 2
    Write-Host "Adding OAuth2 permission grant..."
    try{
        $Null = Invoke-RestMethod -ContentType "application/json" -Method POST -Headers $graphHeaders -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" -Body $desiredState
        Write-Host "OAuth2 permission grant added"
    }catch{
        Write-Error "Failed to add OAuth2 permission grant: $_" -ErrorAction Continue
    }
    
    Write-Host "All done, waiting 10 seconds before final instructions..."
    Start-Sleep -s 10

    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!IMPORTANT!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!FINAL STEP TO FINALIZE!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Host ""
    Write-Host "Please send an email to hello@m365permissions.com with the following:"
    Write-Host "- Subscription ID: $SubscriptionId"
    Write-Host "- Tenant ID: $TenantId"
    Write-Host "- VM Name: $($vm.Name)"
    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!WITHOUT THE ABOVE, THE TOOL WILL NOT SCAN!!!!!!!!!!!!"
    Write-Host ""
    Write-Host "installation has been completed!"
    Write-Host "https://m365permissions.com/#/docs/getting-started"
    Read-Host "Press any key to exit"
    Exit 0
}

invoke-command -scriptblock $authorizeM365Permissions


