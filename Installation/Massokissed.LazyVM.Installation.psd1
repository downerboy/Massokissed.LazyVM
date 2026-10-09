@{
    RootModule        = 'Massokissed.LazyVM.Installation.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fe2e6e71-69f4-5d9f-8047-b25b5c168767'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Phases 7 and 8: installing the tooling list in the guest, then post-configuration.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-GuestInstallerProducts',
        'Get-GuestSqlInstance',
        'Get-GuestVisualStudio',
        'Initialize-GuestSqlDisk',
        'Invoke-Phase7-SilentInstalls',
        'Invoke-Phase8-PostConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
