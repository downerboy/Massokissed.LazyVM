@{
    RootModule        = 'Massokissed.LazyVM.Maintenance.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '2293c278-3164-553b-a7c8-7ecd2bc5b383'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'The licence, the daily maintenance run, rebuilds, the scheduled task and removing a VM.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-Maintenance',
        'Invoke-Rebuild',
        'Register-RebuildSchedule',
        'Remove-LazyVM',
        'Show-LicenseStatus',
        'Stop-GuestGracefully'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
