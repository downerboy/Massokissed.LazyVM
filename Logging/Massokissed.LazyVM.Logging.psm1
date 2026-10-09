# Massokissed.LazyVM.Logging.psm1
# Logging to the console and the VM's log file.
#
# Uses: Massokissed.LazyVM.Configuration.
# Loaded by Build-LazyVM.ps1, which imports every Massokissed.LazyVM module into the
# global scope, in dependency order, so the modules can call one another.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Set by Initialize-Log once the log file is ready.
$script:LogReady = $false

# UTF-8 without a BOM, fixed rather than inherited, so the log reads identically
# whichever PowerShell version appended to it. Created by Get-LogEncoding.
$script:LogEncoding = $null

# The settings for this run. The same table in every module, filled in
# place by Import-LazyVMConfiguration, so it is current whenever it is read.
$CFG = Massokissed.LazyVM.Configuration\Get-LazyVMSettings

# The list is explicit, so a stray file dropped into this folder is never run.
$moduleFiles = @(
    'Logging.ps1'
)
foreach ($moduleFile in $moduleFiles) {
    . (Join-Path -Path $PSScriptRoot -ChildPath $moduleFile)
}
Remove-Variable -Name moduleFiles, moduleFile

# Used by the other modules or the main script. Everything else is internal.
Export-ModuleMember -Function @(
    'Format-Size',
    'Initialize-Log',
    'Write-Log',
    'Write-LogError'
)
