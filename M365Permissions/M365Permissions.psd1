@{
    # Script module or binary module file associated with this manifest.
    RootModule           = 'M365Permissions.psm1'

    # Version number of this module.
    ModuleVersion        = "1.0.4"
    
    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID                 = "748c97a1-b861-4bc5-8455-53494b565526"
    
    # Author of this module
    Author               = "Jos Lieben (jos@lieben.nu)"

    # Company or vendor of this module
    CompanyName          = "Lieben Consultancy"

    # Copyright statement for this module
    Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"

    # Code and readme locations
    HelpInfoURI          = "https://github.com/jflieben/assortedFunctionsV2/tree/main/M365Permissions"

    # Description of the functionality provided by this module
    Description          = "
    SUMMARY:

    Report on permissions in a Microsoft 365 tenant. Provides a 360° view of what a given identity can see and do.

    INSTALLATION:

    Install-PSResource -Name M365Permissions -Repository PSGallery

    EXAMPLES:

    Get-AllM365Permissions -OutputFormat XLSX -expandGroups -ignoreCurrentUser
    
    Get-SpOPermissions -siteUrl `"https://tenant.sharepoint.com/sites/site`" -ExpandGroups -OutputFormat Default
    
    Get-SpOPermissions -teamName `"INT-Finance Department`" -OutputFormat XLSX,CSV
    
    get-AllSPOPermissions -ExpandGroups -OutputFormat XLSX -ignoreCurrentUser -IncludeOneDriveSites -ExcludeOtherSites
    
    Get-EntraPermissions -OutputFormat XLSX -expandGroups

    Get-ExOPermissions -OutputFormat XLSX -expandGroups -ignoreCurrentUser 

    Please note that this module is provided AS-IS, no guarantees or warranties provided. Use at your own risk."

    # Minimum version of the Windows PowerShell engine required by this module
    PowerShellVersion    = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules      = @(
        'PnP.PowerShell',
        'ImportExcel'
    )

    # Variables to export from this module
    VariablesToExport    = '*'

    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
    AliasesToExport      = '*'
}