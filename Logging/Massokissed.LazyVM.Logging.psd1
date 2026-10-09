@{
    RootModule        = 'Massokissed.LazyVM.Logging.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '2003644b-7fd7-544e-8297-129587579fe4'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Logging to the console and the VM''s log file.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Format-Size',
        'Initialize-Log',
        'Write-Log',
        'Write-LogError'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
