# TestHelpers.ps1 - shared setup for the Massokissed.LazyVM Pester tests.
# Dot-sourced from each test file's BeforeAll; not meant to be run on its own.
#
# Run every test from the Scripts folder with:
#   Invoke-Pester -Path .\Tests -Output Detailed

# The same modules, in the same order, as Build-LazyVM.ps1. Each module takes
# its reference to the shared settings table as it loads, so the order matters
# here exactly as it does in a real run.
$script:LazyVMModuleFolders = @(
    'Configuration',
    'Logging',
    'Common',
    'Credentials',
    'Guest',
    'DevDrive',
    'Tooling',
    'Host',
    'Installation',
    'Capture',
    'Restore',
    'Maintenance'
)

function Import-LazyVMModules {
    <# Imports every Massokissed.LazyVM module, fresh, into the global scope. #>
    $scriptsDir = Split-Path -Path $PSScriptRoot -Parent

    foreach ($folder in $script:LazyVMModuleFolders) {
        $moduleDir = Join-Path -Path $scriptsDir -ChildPath $folder
        $manifestPath = Join-Path -Path $moduleDir -ChildPath "Massokissed.LazyVM.$folder.psd1"
        Import-Module -Name $manifestPath -Global -Force -DisableNameChecking
    }
}
