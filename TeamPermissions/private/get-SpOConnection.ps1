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
    if($Type -eq "Admin"){
        $resource = "https://$($global:tenantName)-admin.sharepoint.com"
    }else{
        $resource = "https://$($global:tenantName).sharepoint.com"
    }
    Connect-PnPOnline -Url $Url -ReturnConnection -AccessToken (get-AccessToken -resource $resource) -ErrorAction Stop 
}