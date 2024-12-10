function Get-EntraGroupType {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     
    Param(
        [Parameter(Mandatory=$true)]$group
    )

    if($group.groupTypes -contains "Unified"){
        $groupType = "Microsoft 365 Group"
    }elseif($group.mailEnabled -and $group.securityEnabled){
        $groupType = "Mail-enabled Security Group"
    }elseif($group.mailEnabled -and -not $group.securityEnabled){
        $groupType = "Distribution Group"
    }elseif($group.membershipRule){
        $groupType = "Dynamic Security Group"
    }else{
        $groupType = "Security Group"
    }

    return $groupType
}