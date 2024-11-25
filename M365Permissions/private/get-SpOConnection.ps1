Function Get-SpOConnection{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)][ValidateSet("Admin","User")]$Type,
        [Parameter(Mandatory=$true)][string]$Url
    )

    if(!$global:octo.pnpUrlAuthCaches){
        $global:octo.pnpUrlAuthCaches = @{}
    }

    if($Type -eq "Admin"){
        $resource = "https://$($global:octo.tenantName)-admin.sharepoint.com"
    }else{
        $resource = "https://$($global:octo.tenantName).sharepoint.com"
    }

    if(!$global:octo.pnpUrlAuthCaches.$Url){
        $global:octo.pnpUrlAuthCaches.$Url = @{}
    }

    if(!$global:octo.pnpUrlAuthCaches.$Url.$resource){
        $global:octo.pnpUrlAuthCaches.$Url.$resource = @{
            PnPConnObj = Connect-PnPOnline -Url $Url -ReturnConnection -AccessToken (get-AccessToken -resource $resource) -ErrorAction Stop
            LastUpdated = Get-Date
        }
    }elseif($global:octo.pnpUrlAuthCaches.$Url.$resource.LastUpdated -lt (Get-Date).AddMinutes(-15)){
        $global:octo.pnpUrlAuthCaches.$Url.$resource.PnPConnObj = Connect-PnPOnline -Url $Url -ReturnConnection -AccessToken (get-AccessToken -resource $resource) -ErrorAction Stop
        $global:octo.pnpUrlAuthCaches.$Url.$resource.LastUpdated = Get-Date
    }

    return $global:octo.pnpUrlAuthCaches.$Url.$resource.PnPConnObj
}