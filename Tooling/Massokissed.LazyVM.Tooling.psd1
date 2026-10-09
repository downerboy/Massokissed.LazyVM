@{
    RootModule        = 'Massokissed.LazyVM.Tooling.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '073b1be3-335d-5f07-8cd7-874fb85ce1f3'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'The guest''s tooling: inventory, the tooling list, checkpoints, revert, and what a build installs.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-BuildTooling',
        'Get-RecordField',
        'Invoke-ToolingRevert',
        'Open-GuestSession',
        'Show-GuestTooling',
        'Show-ToolingRestorePoints',
        'Update-ToolingRecord',
        'Write-ToolingReinstallReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
