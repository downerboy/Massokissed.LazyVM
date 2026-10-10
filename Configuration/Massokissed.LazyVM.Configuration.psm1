# Massokissed.LazyVM.Configuration.psm1
# Settings: loading and validating the settings files and VM profiles, and the settings shared by every module.
#
# Uses: none.
# Loaded by Build-LazyVM.ps1, which imports every Massokissed.LazyVM module into the
# global scope, in dependency order, so the modules can call one another.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The settings for this run, shared by every module: see Get-LazyVMSettings.
$script:Settings = @{}

# The list is explicit, so a stray file dropped into this folder is never run.
$moduleFiles = @(
    'Configuration.ps1'
)
foreach ($moduleFile in $moduleFiles) {
    . (Join-Path -Path $PSScriptRoot -ChildPath $moduleFile)
}
Remove-Variable -Name moduleFiles, moduleFile

# Used by the other modules or the main script. Everything else is internal.
Export-ModuleMember -Function @(
    'Get-LazyVMSettings',
    'Get-VMProfileNames',
    'Import-LazyVMConfiguration',
    'New-VMProfile',
    'Read-LazyVMSettings'
)
