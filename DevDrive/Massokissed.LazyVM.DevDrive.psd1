@{
    RootModule        = 'Massokissed.LazyVM.DevDrive.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'f47a306e-a910-5230-bbd6-3f63e3e434c0'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'The Dev Drive: its disk on the host and its volume in the guest.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Add-DevDriveDisk',
        'Enable-GuestEnhancedSession',
        'Initialize-GuestDevDrive',
        'New-DevDriveDisk'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
