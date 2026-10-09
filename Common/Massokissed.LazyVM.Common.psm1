# Massokissed.LazyVM.Common.psm1
# Small helpers shared by the other modules.
#
# Uses: none.
# Loaded by Build-LazyVM.ps1, which imports every Massokissed.LazyVM module into the
# global scope, in dependency order, so the modules can call one another.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The list is explicit, so a stray file dropped into this folder is never run.
$moduleFiles = @(
    'Helpers.ps1'
)
foreach ($moduleFile in $moduleFiles) {
    . (Join-Path -Path $PSScriptRoot -ChildPath $moduleFile)
}
Remove-Variable -Name moduleFiles, moduleFile

# Used by the other modules or the main script. Everything else is internal.
Export-ModuleMember -Function @(
    'Exit-WithError',
    'Get-FreeSpaceGB',
    'Resolve-PathForce',
    'Test-HyperVModule',
    'Test-IsoFile',
    'Test-PortableExecutable'
)
