@{
    RootModule        = 'Massokissed.LazyVM.Common.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'db9d1f62-b4e8-5a46-aab1-3b3f89986f92'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Small helpers shared by the other modules.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Exit-WithError',
        'Get-FreeSpaceGB',
        'Resolve-PathForce',
        'Test-HyperVModule',
        'Test-IsoFile',
        'Test-PortableExecutable'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
