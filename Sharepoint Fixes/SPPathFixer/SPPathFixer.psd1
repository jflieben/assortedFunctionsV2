@{
    RootModule           = 'SPPathFixer.psm1'
    ModuleVersion        = '1.0.1'
    CompatiblePSEditions = @('Core')
    GUID                 = 'f7a3c2e1-4b8d-4e6f-9a1c-3d5e7f2b8c4a'
    Author               = 'Jos Lieben (jos@lieben.nu)'
    CompanyName          = 'Lieben Consultancy'
    Copyright            = 'https://www.lieben.nu/liebensraum/commercial-use/'
    Description          = @'
SPPathFixer - SharePoint Online Long Path Scanner & Fixer

Scans SharePoint Online sites for files and folders exceeding path length limits.
Provides multiple fix strategies: shorten names, move up hierarchy, flatten paths.

USAGE:
    Import-Module SPPathFixer   # Opens GUI automatically

Free for non-commercial use. See https://www.lieben.nu/liebensraum/commercial-use/
Use at own risk
'@
    PowerShellVersion    = '7.4'

    RequiredAssemblies   = @(
        'lib\SPPathFixer.Engine.dll',
        'lib\Microsoft.Data.Sqlite.dll',
        'lib\SQLitePCLRaw.core.dll',
        'lib\SQLitePCLRaw.provider.e_sqlite3.dll',
        'lib\SQLitePCLRaw.batteries_v2.dll',
        'lib\ClosedXML.dll',
        'lib\DocumentFormat.OpenXml.dll',
        'lib\SixLabors.Fonts.dll'
    )

    FunctionsToExport    = @(
        'Connect-SPFix',
        'Disconnect-SPFix',
        'Start-SPFixScan',
        'Get-SPFixScanStatus',
        'Get-SPFixResults',
        'Export-SPFixResults',
        'Start-SPFixRepair',
        'Set-SPFixConfig',
        'Get-SPFixConfig',
        'Start-SPFixGUI',
        'Stop-SPFixGUI'
    )

    CmdletsToExport      = @()
    VariablesToExport     = @()
    AliasesToExport       = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('SharePoint', 'PathLength', 'LongPath', 'Fix', 'Scanner', 'Office365')
            LicenseUri   = 'https://www.lieben.nu/liebensraum/commercial-use/'
            ReleaseNotes = 'Improve performance, visibility of intermediate results and reliability'
        }
    }
}
