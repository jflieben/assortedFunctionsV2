function get-SpOSharingLinkInfo{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>

    Param(
        [Parameter(Mandatory=$true)]$sharingLinkGuid
    )
    
    return $global:sharedLinks | Where-Object {$_.ShareId -eq $sharingLinkGuid -and $_.IsActive}
}