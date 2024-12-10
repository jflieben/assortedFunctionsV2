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

    if(!$global:pnpUrlAuthCaches){
        $global:pnpUrlAuthCaches = @{}
    }

    if($Type -eq "Admin"){
        $resource = "https://$($global:octo.tenantName)-admin.sharepoint.com"
    }else{
        $resource = "https://$($global:octo.tenantName).sharepoint.com"
    }

    if(!$global:pnpUrlAuthCaches.$Url){
        $global:pnpUrlAuthCaches.$Url = @{}
    }

    if(!$global:pnpUrlAuthCaches.$Url.$resource){
        $global:pnpUrlAuthCaches.$Url.$resource = @{
            PnPConnObj = Connect-PnPOnline -Url $Url -ReturnConnection -AccessToken (get-AccessToken -resource $resource) -ErrorAction Stop
            LastUpdated = Get-Date
        }
    }elseif($global:pnpUrlAuthCaches.$Url.$resource.LastUpdated -lt (Get-Date).AddMinutes(-15)){
        $global:pnpUrlAuthCaches.$Url.$resource.PnPConnObj = Connect-PnPOnline -Url $Url -ReturnConnection -AccessToken (get-AccessToken -resource $resource) -ErrorAction Stop
        $global:pnpUrlAuthCaches.$Url.$resource.LastUpdated = Get-Date
    }

    return $global:pnpUrlAuthCaches.$Url.$resource.PnPConnObj
}