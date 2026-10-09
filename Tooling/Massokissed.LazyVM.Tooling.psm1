# Massokissed.LazyVM.Tooling.psm1
# The guest's tooling: inventory, the tooling list, checkpoints, revert, and what a build installs.
#
# Uses: Massokissed.LazyVM.Configuration, Massokissed.LazyVM.Common, Massokissed.LazyVM.Credentials, Massokissed.LazyVM.Guest, Massokissed.LazyVM.Logging.
# Loaded by Build-LazyVM.ps1, which imports every Massokissed.LazyVM module into the
# global scope, in dependency order, so the modules can call one another.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The settings for this run. The same table in every module, filled in
# place by Import-LazyVMConfiguration, so it is current whenever it is read.
$CFG = Massokissed.LazyVM.Configuration\Get-LazyVMSettings

# The list is explicit, so a stray file dropped into this folder is never run.
$moduleFiles = @(
    'Inventory.ps1',
    'ToolingRecord.ps1',
    'Marketplace.ps1',
    'AwaitingReinstall.ps1',
    'BuildTooling.ps1'
)
foreach ($moduleFile in $moduleFiles) {
    . (Join-Path -Path $PSScriptRoot -ChildPath $moduleFile)
}
Remove-Variable -Name moduleFiles, moduleFile

# Used by the other modules or the main script. Everything else is internal.
Export-ModuleMember -Function @(
    'Get-BuildTooling',
    'Get-RecordField',
    'Invoke-ToolingRevert',
    'Open-GuestSession',
    'Show-GuestTooling',
    'Show-ToolingRestorePoints',
    'Update-ToolingRecord',
    'Write-ToolingReinstallReport'
)
