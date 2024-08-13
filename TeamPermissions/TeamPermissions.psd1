@{
    # Script module or binary module file associated with this manifest.
    RootModule           = 'TeamPermissions.psm1'

    # Version number of this module.
    ModuleVersion        = "1.0.6"
    
    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID                 = "748c97a1-b861-4bc5-8455-53494b565525"
    
    # Author of this module
    Author               = "Jos Lieben (jos@lieben.nu)"

    # Company or vendor of this module
    CompanyName          = "Lieben Consultancy"

    # Copyright statement for this module
    Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"

    # Description of the functionality provided by this module
    Description          = "Reporting on ALL permissions in a Team site (or sharepoint or onedrive...). Note: for now a proof of concept. Features to be added soon:
    
    -Scanning multiple teams / sites
    -Paralellization / multi-threading
    "

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