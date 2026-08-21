#
# Module manifest for module 'ADDRS'
# Azure Dynamic Desktop Right Sizing
#
# Author: Jos Lieben
# Updated: 2026-03-25
#

@{
    RootModule        = 'ADDRS.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'bbd6707a-392d-4db8-97c3-2634f029e2f0'
    Author            = 'Jos Lieben'
    CompanyName       = 'JSolve B.V.'
    Copyright         = 'https://jsolve.nl/commercial-use.html (Free for non-commercial use with headers intact)'
    Description       = 'Azure Dynamic Desktop Right Sizing - Automatically right-sizes Azure VMs based on CPU/memory telemetry from Azure Monitor, pricing data, and performance benchmarks. Ideal for Azure Virtual Desktop (AVD) environments. Use Get-Help Get-VMRightSize, Set-VMRightSize, or Set-ResourceGroupRightSize for details.'

    PowerShellVersion = '7.0'

    RequiredModules   = @(
        @{ ModuleName = 'Az.Compute';            ModuleVersion = '7.0.0' }
        @{ ModuleName = 'Az.OperationalInsights'; ModuleVersion = '3.2.0' }
        @{ ModuleName = 'Az.Resources';           ModuleVersion = '7.0.0' }
        @{ ModuleName = 'Az.Accounts';            ModuleVersion = '3.0.0' }
    )

    FunctionsToExport = @(
        'Get-VMRightSize'
        'Set-VMRightSize'
        'Set-ResourceGroupRightSize'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()

    AliasesToExport    = @(
        'get-vmRightSize'
        'set-vmRightSize'
        'set-rsgRightSize'
    )

    PrivateData = @{
        PSData = @{
            Tags       = @(
                'Azure', 'RightSizing', 'VirtualMachines', 'CostOptimization',
                'PerformanceMonitoring', 'AVD', 'AzureVirtualDesktop', 'FinOps'
            )
            LicenseUri = 'https://www.lieben.nu/liebensraum/commercial-use'
            ProjectUri = 'https://www.lieben.nu/liebensraum/2022/05/automatic-modular-rightsizing-of-azure-vms-with-special-focus-on-azure-virtual-desktop/'
            ReleaseNotes = 'v2.0.0 (2026-03-25): Major rewrite - PS7 required, ShouldProcess support, bug fixes, updated APIs, performance improvements. See README for full changelog.'
        }
    }

    HelpInfoURI = 'https://www.lieben.nu/liebensraum/2022/05/automatic-modular-rightsizing-of-azure-vms-with-special-focus-on-azure-virtual-desktop/'
}