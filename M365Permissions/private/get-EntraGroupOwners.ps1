function Get-EntraGroupOwners {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>     
    Param(
        [Parameter(Mandatory=$true)]$groupId
    )

    $groupMembers = new-GraphQuery -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/owners" | Where-Object {$_ -and $_."@odata.type" -ne "#microsoft.graph.group" }
    return $groupMembers
}