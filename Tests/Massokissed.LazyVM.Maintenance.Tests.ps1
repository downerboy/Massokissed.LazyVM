# Massokissed.LazyVM.Maintenance.Tests.ps1
# Removing a VM (-RemoveVM): what it deletes, and what it keeps because every
# VM, or another VM, still uses it. Only the planning is tested here; it reads
# nothing from disk and touches neither Hyper-V nor the Task Scheduler.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModules

    $module = 'Massokissed.LazyVM.Maintenance'
    $scriptDir = 'D:\DevVM\Scripts'

    function New-TestVMSettings {
        <# A VM's settings as Read-LazyVMSettings resolves them with the defaults, under D:\DevVM. #>
        param(
            [Parameter(Mandatory)][string]$Name,
            [hashtable]$Overrides = @{}
        )

        $settings = @{
            VMName           = $Name
            Root             = 'D:\DevVM'
            ProfileDir       = "D:\DevVM\Scripts\Config\VMs\$Name"
            VHDXRoot         = 'D:\DevVM\VMs'
            ISOPath          = 'D:\DevVM\ISO\Win11Ent_Eval.iso'
            ISOSearchRoot    = 'D:\DevVM\ISO'
            SQLInstallerPath = 'D:\DevVM\Installers\SQLServer2022-x64-ENU-Dev.exe'
            SQLDiskPath      = "D:\DevVM\SQLDisk\$Name.vhdx"
            DevDrivePath     = "D:\DevVM\DevDrive\$Name.vhdx"
            SeedDiskPath     = "D:\DevVM\VMs\$Name-Seed.vhdx"
            CheckpointDir    = "D:\DevVM\Checkpoints\$Name"
            VSSettingsBackup = "D:\DevVM\Backup\$Name\VisualStudio.vssettings"
            LogFile          = "D:\DevVM\Logs\$Name.log"
            CredStoreDir     = 'D:\DevVM\Backup'
            CredKeyFile      = 'D:\DevVM\Backup\.lazyvm.key'
            GuestCredFile    = "D:\DevVM\Backup\$Name\guest.cred"
            CertCredFile     = "D:\DevVM\Backup\$Name\certs.cred"
            StateDir         = "D:\DevVM\State\$Name"
            ResumeRegKey     = "HKLM:\SOFTWARE\LazyVM\$Name"
            ResumeTaskName   = "LazyVM-ResumeAfterReboot-$Name"
            ScheduleTaskName = "LazyVM-Maintain-$Name"
        }
        foreach ($key in $Overrides.Keys) {
            $settings[$key] = $Overrides[$key]
        }
        return $settings
    }

    function Get-TestPlan {
        <# Get-VMRemovalPlan, run inside the module, where it lives. #>
        param(
            [Parameter(Mandatory)][hashtable]$Settings,
            [hashtable[]]$OtherSettings = @(),
            [string[]]$AttachedDisks = @(),
            [string[]]$OtherVMDisks = @(),
            [string[]]$ExtraFiles = @(),
            [string[]]$ExtraFolders = @()
        )

        $arguments = @{
            Settings      = $Settings
            OtherSettings = $OtherSettings
            AttachedDisks = $AttachedDisks
            OtherVMDisks  = $OtherVMDisks
            ExtraFiles    = $ExtraFiles
            ExtraFolders  = $ExtraFolders
            ScriptDir     = $scriptDir
        }
        return InModuleScope $module -Parameters @{ Arguments = $arguments } {
            param($Arguments)
            Get-VMRemovalPlan @Arguments
        }
    }
}

Describe 'Test-PathWithin' {
    It "returns <Expected> for '<Path>' within '<Folder>'" -ForEach @(
        @{ Path = 'D:\DevVM\State'; Folder = 'D:\DevVM\State'; Expected = $true }
        @{ Path = 'd:\devvm\state\'; Folder = 'D:\DevVM\State'; Expected = $true }
        @{ Path = 'D:\DevVM\State\Alpha\manifest.json'; Folder = 'D:\DevVM\State'; Expected = $true }
        @{ Path = 'D:\DevVM\State2'; Folder = 'D:\DevVM\State'; Expected = $false }
        @{ Path = 'D:\DevVM'; Folder = 'D:\DevVM\State'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Path = $Path; Folder = $Folder } {
            param($Path, $Folder)
            Test-PathWithin -Path $Path -Folder $Folder
        } | Should -Be $Expected
    }
}

Describe 'Get-VMRemovalPlan' {
    Context 'with no other VM on the host' {
        BeforeAll {
            $plan = Get-TestPlan -Settings (New-TestVMSettings -Name 'Alpha')
        }

        It 'deletes every disk the VM has, including the Dev Drive' {
            $plan.Files | Should -Contain 'D:\DevVM\VMs\Alpha-OS.vhdx'
            $plan.Files | Should -Contain 'D:\DevVM\SQLDisk\Alpha.vhdx'
            $plan.Files | Should -Contain 'D:\DevVM\DevDrive\Alpha.vhdx'
            $plan.Files | Should -Contain 'D:\DevVM\VMs\Alpha-Seed.vhdx'
        }

        It 'deletes its credentials, Visual Studio settings backup and log' {
            $plan.Files | Should -Contain 'D:\DevVM\Backup\Alpha\guest.cred'
            $plan.Files | Should -Contain 'D:\DevVM\Backup\Alpha\certs.cred'
            $plan.Files | Should -Contain 'D:\DevVM\Backup\Alpha\VisualStudio.vssettings'
            $plan.Files | Should -Contain 'D:\DevVM\Logs\Alpha.log'
        }

        It 'deletes the credential key, which no other VM needs' {
            $plan.Files | Should -Contain 'D:\DevVM\Backup\.lazyvm.key'
        }

        It 'deletes its checkpoints, captured state, Hyper-V configuration and profile folders' {
            $plan.Folders | Should -Be @(
                'D:\DevVM\Checkpoints\Alpha'
                'D:\DevVM\State\Alpha'
                'D:\DevVM\VMs\Alpha'
                'D:\DevVM\Scripts\Config\VMs\Alpha'
            )
        }

        It 'removes both scheduled tasks and the resume registry key' {
            $plan.Tasks | Should -Be @('LazyVM-Maintain-Alpha', 'LazyVM-ResumeAfterReboot-Alpha')
            $plan.RegistryKey | Should -Be 'HKLM:\SOFTWARE\LazyVM\Alpha'
        }

        It 'keeps nothing back' {
            $plan.Kept | Should -BeNullOrEmpty
        }
    }

    It 'keeps the credential key while another VM uses it' {
        $plan = Get-TestPlan -Settings (New-TestVMSettings -Name 'Alpha') -OtherSettings @(New-TestVMSettings -Name 'Beta')

        $plan.Files | Should -Not -Contain 'D:\DevVM\Backup\.lazyvm.key'
        $plan.Kept.Path | Should -Contain 'D:\DevVM\Backup\.lazyvm.key'
        ($plan.Kept | Where-Object { $_.Path -eq 'D:\DevVM\Backup\.lazyvm.key' }).Reason | Should -BeLike "*VM 'Beta'*"
    }

    It 'keeps a folder that holds another VM''s files' {
        # Built before VMs had their own folders, Alpha keeps its state in
        # State itself; Beta's state is in State\Beta.
        $alpha = New-TestVMSettings -Name 'Alpha' -Overrides @{ StateDir = 'D:\DevVM\State' }
        $plan = Get-TestPlan -Settings $alpha -OtherSettings @(New-TestVMSettings -Name 'Beta')

        $plan.Folders | Should -Not -Contain 'D:\DevVM\State'
        ($plan.Kept | Where-Object { $_.Path -eq 'D:\DevVM\State' }).Reason | Should -BeLike "*VM 'Beta' also uses D:\DevVM\State\Beta*"
    }

    It 'keeps a disk attached to another VM' {
        $alpha = New-TestVMSettings -Name 'Alpha' -Overrides @{ SQLDiskPath = 'D:\DevVM\SQLDisk\Shared.vhdx' }
        $plan = Get-TestPlan -Settings $alpha -OtherVMDisks @('D:\DevVM\SQLDisk\Shared.vhdx')

        $plan.Files | Should -Not -Contain 'D:\DevVM\SQLDisk\Shared.vhdx'
        ($plan.Kept | Where-Object { $_.Path -eq 'D:\DevVM\SQLDisk\Shared.vhdx' }).Reason | Should -BeLike '*attached to another VM*'
    }

    It "never deletes a folder that holds what every VM uses: '<Folder>'" -ForEach @(
        @{ Folder = 'D:\DevVM' }
        @{ Folder = 'D:\DevVM\ISO' }
        @{ Folder = 'D:\DevVM\Scripts' }
        @{ Folder = 'D:\DevVM\Backup' }
    ) {
        $alpha = New-TestVMSettings -Name 'Alpha' -Overrides @{ StateDir = $Folder }
        $plan = Get-TestPlan -Settings $alpha

        $plan.Folders | Should -Not -Contain $Folder
        ($plan.Kept | Where-Object { $_.Path -eq $Folder }).Reason | Should -BeLike '*which every VM uses*'
    }

    It 'adds the disks Hyper-V reports attached, without listing one twice' {
        $plan = Get-TestPlan -Settings (New-TestVMSettings -Name 'Alpha') -AttachedDisks @(
            'd:\devvm\sqldisk\alpha.vhdx'
            'D:\DevVM\Checkpoints\Alpha\Alpha-OS_1234.avhdx'
            'E:\Elsewhere\Extra.vhdx'
        )

        @($plan.Files | Where-Object { $_ -like '*\SQLDisk\Alpha.vhdx' }).Count | Should -Be 1
        $plan.Files | Should -Contain 'D:\DevVM\Checkpoints\Alpha\Alpha-OS_1234.avhdx'
        $plan.Files | Should -Contain 'E:\Elsewhere\Extra.vhdx'
    }

    It 'adds retired disks, rotated logs and retired configuration folders' {
        $plan = Get-TestPlan -Settings (New-TestVMSettings -Name 'Alpha') `
            -ExtraFiles @('D:\DevVM\VMs\Alpha-OS.retired-20261001-020000.vhdx', 'D:\DevVM\Logs\Alpha.20261001-020000.log') `
            -ExtraFolders @('D:\DevVM\VMs\Alpha.retired-20261001-020000')

        $plan.Files | Should -Contain 'D:\DevVM\VMs\Alpha-OS.retired-20261001-020000.vhdx'
        $plan.Files | Should -Contain 'D:\DevVM\Logs\Alpha.20261001-020000.log'
        $plan.Folders | Should -Contain 'D:\DevVM\VMs\Alpha.retired-20261001-020000'
    }

    It 'keeps a scheduled task another VM uses' {
        $alpha = New-TestVMSettings -Name 'Alpha' -Overrides @{ ScheduleTaskName = 'Shared-Task' }
        $beta = New-TestVMSettings -Name 'Beta' -Overrides @{ ScheduleTaskName = 'Shared-Task' }

        $plan = Get-TestPlan -Settings $alpha -OtherSettings @($beta)

        $plan.Tasks | Should -Be @('LazyVM-ResumeAfterReboot-Alpha')
        $plan.Kept.Path | Should -Contain 'task Shared-Task'
    }

    It 'keeps a registry key that holds another VM''s key' {
        $alpha = New-TestVMSettings -Name 'Alpha' -Overrides @{ ResumeRegKey = 'HKLM:\SOFTWARE\LazyVM' }

        $plan = Get-TestPlan -Settings $alpha -OtherSettings @(New-TestVMSettings -Name 'Beta')

        $plan.RegistryKey | Should -BeNullOrEmpty
        $plan.Kept.Path | Should -Contain 'HKLM:\SOFTWARE\LazyVM'
    }
}
