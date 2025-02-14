Function connect-M365{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Switch]$Delegated,
        [Switch]$ServicePrincipal
    )

    $connected = $True

    #choose auth mode, env var trumps passed in param, trumps default / persisted from set-M365PermissionsConfig
    if($Env:LCAUTHMODE){
        $global:octo.authMode = $Env:LCAUTHMODE
    }elseif($ServicePrincipal){
        $global:octo.authMode = "ServicePrincipal"
    }elseif($Delegated){
        $global:octo.authMode = "Delegated"
    }

    #if we're doing delegated auth, use my multi-tenant app id
    if($global:octo.authMode -eq "Delegated"){
        Write-Host "Using default $($global:octo.authMode) authentication..."
        $global:octo.LCClientId = "0ee7aa45-310d-4b82-9cb5-11cc01ad38e4"
    }

    #SPN auth requires a clientid and tenantid by the customer either through env vars or set-M365PermissionsConfig
    if($global:octo.authMode -eq "ServicePrincipal"){
        Write-Host "Using $($global:octo.authMode) authentication..."
        if($Env:LCCLIENTID){
            $global:octo.LCClientId = $Env:LCCLIENTID
        }
        if($Env:LCTENANTID){
            $global:octo.LCTenantId = $Env:LCTENANTID
        }   
        if(!$global:octo.LCClientId -or !$global:octo.LCTenantId){
            $connected = $False
            Write-Error "Service Principal authentication requires a ClientId and TenantId to be set, please run set-M365PermissionsConfig -LCClientId <clientid> -LCTenantId <tenantid> before connecting or configure LCCLIENTID and LCTENANTID as env variables" -ErrorAction Continue
        }
    }
    
    if($connected){
        Write-Host ""
        $global:octo.currentUser = Get-CurrentUser
        $global:octo.OnMicrosoft = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' | Where-Object -Property isInitial -EQ $true).id 
        $global:octo.tenantName = $($global:octo.OnMicrosoft).Split(".")[0]
        Write-Host "Authenticated successfully! Here are some examples using this module:"
        Write-Host ""
        Write-Host ">> Get-AllM365Permissions -expandGroups" -ForegroundColor Magenta
        
        Write-Host ">> Get-AllExOPermissions -includeFolderLevelPermissions" -ForegroundColor Magenta
        
        Write-Host ">> Get-ExOPermissions -recipientIdentity `$mailbox.Identity -includeFolderLevelPermissions" -ForegroundColor Magenta
        
        Write-Host ">> Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`" -ExpandGroups" -ForegroundColor Magenta
        
        Write-Host ">> Get-SpOPermissions -teamName `"INT-Finance Department`"" -ForegroundColor Magenta
        
        Write-Host ">> get-AllSPOPermissions -ExpandGroups -IncludeOneDriveSites -ExcludeOtherSites" -ForegroundColor Magenta
        
        Write-Host ">> get-AllEntraPermissions -excludeGroupsAndUsers" -ForegroundColor Magenta    

        Write-Host ">> get-AllPBIPermissions" -ForegroundColor Magenta 
        
        Write-Host ">> Get-ChangedPermissions" -ForegroundColor Magenta   

        Write-Host ""
    }  
}