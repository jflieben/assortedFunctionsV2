login-azaccount
connect-azuread

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12
$context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
$token = ([Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://graph.microsoft.com")).AccessToken
            
$preReport = @()
$postReport = @()
$userRoles = @{}
foreach($role in (Get-AzureADDirectoryRole)){
    $members = Get-AzureADDirectoryRoleMember -ObjectId $role.ObjectId
    foreach($member in $members){
        if(!$userRoles.$($member.ObjectId)){
            $userRoles.$($member.ObjectId) = @()
        }
        if($userRoles.$($member.ObjectId) -notcontains $role.displayName){
            $userRoles.$($member.ObjectId) += $role.displayName
        }
        try{
            $lastLogin = $Null
            $lastLogin = Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/users?`$Filter=UserPrincipalName eq '$($member.UserPrincipalName)'&`$select=UserType,UserPrincipalName,Id,DisplayName,ExternalUserState,ExternalUserStateChangeDateTime,CreatedDateTime,CreationType,AccountEnabled,signInActivity" -Method GET -Headers @{"Authorization"="Bearer $token"}
        }catch{$lastLogin = $Null}
        $obj = [PSCustomObject]@{
            "DisplayName"=$member.DisplayName
            "lastSignIn"=$lastLogin.value.signInActivity.lastSignInDateTime
            "AccountEnabled" = $member.AccountEnabled
            "login"=$member.UserPrincipalName
            "userType"=$member.UserType
            "objectId"=$member.ObjectId
        }
        if($preReport -notcontains $obj){
            $preReport += $obj
        }
    }
}

foreach($user in $preReport){
    $user | add-member -MemberType NoteProperty -Name roles -Value ($userRoles.$($user.ObjectId) -Join ";")

    $postReport += $user
}

$postReport | select displayName,lastSignIn,AccountEnabled,Login,userType,Roles | ft