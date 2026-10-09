@{
    RootModule        = 'Massokissed.LazyVM.Credentials.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b1739cc5-a7e6-5350-8667-b32f08216ca3'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'The encrypted credential store and -SetupCredentials.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertTo-PlainText',
        'Get-GuestCredential',
        'Get-StoredCredential',
        'Invoke-CredentialSetup',
        'New-RandomPassword',
        'Save-StoredCredential',
        'Sync-GuestUserFromStore'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
