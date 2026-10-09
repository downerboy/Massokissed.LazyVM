@{
    RootModule        = 'Massokissed.LazyVM.Guest.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fdda3770-e194-50ea-bf42-12deee6aa909'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'The PowerShell Direct session to the guest: running commands in it and copying files to and from it.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Connect-Guest',
        'Copy-FromGuest',
        'Copy-ToGuest',
        'Disconnect-Guest',
        'Get-GuestSqlServer',
        'Invoke-GuestScript',
        'Invoke-GuestScriptAsInteractiveUser',
        'Set-GuestSqlServer',
        'Wait-GuestReady'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
