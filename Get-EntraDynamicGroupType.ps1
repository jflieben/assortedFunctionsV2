function Get-EntraDynamicGroupType{
    <#
        Copyright/License: Free to use / modify / distribute, but leave author details intact.
        Author:            Jos Lieben (Lieben Consultancy)
        Blog:              https://www.lieben.nu
        Purpose:           For a given entra group GUID, which high efficiency / speed, return 'AllUsers', 'AllInternalUsers', 'AllGuests' or Null depending on who's in it
                           optionally, use a wider drift ratio if your tenant is small and has large user delta's while using this function
    #>    
    Param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$groupId,
        [Parameter(Mandatory = $false)]
        [Double]$maxDriftRatio = 0.05
    )

    if([string]::IsNullOrEmpty($global:totalTenantUserCount)){
        [Int]$global:totalTenantUserCount = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/users?$top=1' -Method GET -ComplexFilter -justReturnCount
    }
    if([string]::IsNullOrEmpty($global:totalTenantGuestCount)){
        [Int]$global:totalTenantGuestCount = New-GraphQuery -Uri 'https://graph.microsoft.com/v1.0/users?$filter=userType eq ''Guest''&$top=1' -Method GET -ComplexFilter -justReturnCount
    }    

    [Int]$totalTenantMemberCount = $global:totalTenantUserCount - $global:totalTenantGuestCount

    try{
        $groupMemberCount = 0; $groupMemberCount = New-GraphQuery -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/transitiveMembers/microsoft.graph.user/`$count" -ComplexFilter
    }catch{
        $groupMemberCount = 0
    }

    if($groupMemberCount -le 0){
        Write-LogMessage -message "No members found in group: $groupId" -level 6
        return $Null
    }

    # calculate drift and decide match for all internal users type
    $diffRatio = if ($totalTenantMemberCount -gt 0) { [math]::Abs($groupMemberCount - $totalTenantMemberCount) / $totalTenantMemberCount } else { 1 }
    if ($diffRatio -le $maxDriftRatio){
        Write-LogMessage -message "Detected group with all internal users: $groupId" -level 6
        return "AllInternalUsers"
    }

    # calculate drift and decide match for all users type
    $diffRatio = if ($global:totalTenantUserCount -gt 0) { [math]::Abs($groupMemberCount - $global:totalTenantUserCount) / $global:totalTenantUserCount } else { 1 }
    if ($diffRatio -le $maxDriftRatio){
        Write-LogMessage -message "Detected group with all users: $groupId" -level 6
        return "AllUsers"
    }

    # calculate drift and decide match for all users type
    $diffRatio = if ($global:totalTenantGuestCount -gt 0) { [math]::Abs($groupMemberCount - $global:totalTenantGuestCount) / $global:totalTenantGuestCount } else { 1 }
    if ($diffRatio -le $maxDriftRatio){
        Write-LogMessage -message "Detected group with all users: $groupId" -level 6
        return "AllGuests"
    }

    return $Null
}