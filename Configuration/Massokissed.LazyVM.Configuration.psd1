@{
    RootModule        = 'Massokissed.LazyVM.Configuration.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5c9b4cc9-d3ac-56fd-9e96-e5b1a32f1ee0'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Settings: loading and validating the settings files and VM profiles, and the settings shared by every module.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-LazyVMSettings',
        'Get-VMProfileNames',
        'Import-LazyVMConfiguration',
        'New-VMProfile',
        'Read-LazyVMSettings'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
