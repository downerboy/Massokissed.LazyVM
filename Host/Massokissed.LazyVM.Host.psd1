@{
    RootModule        = 'Massokissed.LazyVM.Host.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '175c83d1-aa7e-5911-886b-7e307a194a33'
    Author            = 'Massokissed'
    CompanyName       = 'Massokissed'
    Copyright         = '(c) Massokissed. All rights reserved.'
    Description       = 'Host preparation and the VM itself: Phases 0 to 6 and the unattended Setup seed disk.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-ResumePhase',
        'Invoke-Phase0-ServiceCheck',
        'Invoke-Phase1-CPUCheck',
        'Invoke-Phase2-HyperVFeature',
        'Invoke-Phase3-FolderSetup',
        'Invoke-Phase4-AssetCheck',
        'Invoke-Phase5-SQLDisk',
        'Invoke-Phase5b-DevDrive',
        'Invoke-Phase6-VMBuild',
        'New-UnattendSeedDisk',
        'Remove-UnattendSeedDisk',
        'Resolve-InstallationIso',
        'Unregister-ResumeTask'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
