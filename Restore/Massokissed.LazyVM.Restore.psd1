@{
    RootModule        = 'Massokissed.LazyVM.Restore.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '4840e049-1001-560b-b0f9-b0351e777471'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Phase 10: restoring captured state into a guest.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-Phase10-Restore'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
