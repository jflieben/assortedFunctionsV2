function get-Invitee{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$invitee,
        [Parameter(Mandatory=$true)]$siteUrl
    )

    $retVal = @{}

    #type 1 = internal user
    #type 2 = group?
    #type 3 = external user
    if($invitee.Type -in @(1,2)){
        $usr = $Null;$usr = Get-PnPUser -Connection (Get-SpOConnection -Type User -Url $siteUrl) -Identity 18
        if($usr){
            return $usr
        }else{
            $retVal.Title = "Internal User"
            $retVal.LoginName = "Unknown (deleted?)"
            $retVal.Email = "Unknown (deleted?)"
            $retVal.PrincipalType = "User"        
        }
    }else{
        $retVal.Title = "External User"
        $retVal.Email = $invitee.Email
        $retVal.LoginName = $invitee.Email
        $retVal.PrincipalType = "User" 
    }

    return $retVal
}