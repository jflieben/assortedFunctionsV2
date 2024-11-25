Function get-AllPBIPermissions{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -expandGroups: if set, group memberships will be expanded to individual users
        -outputFormat: 
            XLSX
            CSV
            Default (output to Out-GridView)
            Any combination of above is possible
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
    #>        
    Param(
        [Switch]$expandGroups,
        [Switch]$includeCurrentUser,
        [ValidateSet('XLSX','CSV','Default')]
        [String[]]$outputFormat="XLSX"
    )

    $global:octo.includeCurrentUser = $includeCurrentUser.IsPresent

    Write-Progress -Id 1 -PercentComplete 1 -Activity "Scanning PowerBI" -Status "Scanning Workspaces..."
    get-PbIWorkspaces -outputFormat $outputFormat -expandGroups:$expandGroups.IsPresent
}