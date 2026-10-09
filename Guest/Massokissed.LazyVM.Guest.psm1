# Massokissed.LazyVM.Guest.psm1
# The PowerShell Direct session to the guest: running commands in it and copying files to and from it.
#
# Uses: Massokissed.LazyVM.Configuration, Massokissed.LazyVM.Common, Massokissed.LazyVM.Logging.
# Loaded by Build-LazyVM.ps1, which imports every Massokissed.LazyVM module into the
# global scope, in dependency order, so the modules can call one another.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The PowerShell Direct session every guest call goes through.
$script:GuestSession = $null

# Connection target for guest-side SQL work. Refined to localhost\<instance>
# by Set-GuestSqlServer once the real instance name is known.
$script:GuestSqlServer = 'localhost'

# The settings for this run. The same table in every module, filled in
# place by Import-LazyVMConfiguration, so it is current whenever it is read.
$CFG = Massokissed.LazyVM.Configuration\Get-LazyVMSettings

# The list is explicit, so a stray file dropped into this folder is never run.
$moduleFiles = @(
    'GuestExecution.ps1'
)
foreach ($moduleFile in $moduleFiles) {
    . (Join-Path -Path $PSScriptRoot -ChildPath $moduleFile)
}
Remove-Variable -Name moduleFiles, moduleFile

# Used by the other modules or the main script. Everything else is internal.
Export-ModuleMember -Function @(
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
