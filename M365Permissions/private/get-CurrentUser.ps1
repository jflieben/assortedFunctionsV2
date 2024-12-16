function Get-CurrentUser {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     

    if($global:octo.authMode -eq "Delegated"){
        return New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/me' -NoPagination -Method GET
    }else{
        $spnMetaData = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$($global:octo.LCClientId)')" -NoPagination -Method GET 
        return @{
            userPrincipalName = $spnMetaData.displayName
        }
    }

}