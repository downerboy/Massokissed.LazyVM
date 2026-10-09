@{
    RootModule        = 'Massokissed.LazyVM.Capture.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a2d7b349-485f-5533-a8eb-80fdd05afb55'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Phase 9: capturing guest state to the host.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-CaptureManifest',
        'Invoke-Phase9-Capture'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
