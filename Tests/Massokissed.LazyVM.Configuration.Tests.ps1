# Massokissed.LazyVM.Configuration.Tests.ps1
# Settings: merging the user's files over the defaults, choosing the root
# folder, resolving host paths, and creating and selecting VM profiles.
#
# Most of these functions are internal to the module, so each test runs its
# body with InModuleScope, with test data passed in through -Parameters.
# Config folders are built under $TestDrive with a copy of the real
# LazyVM.Defaults.psd1, so a broken defaults file fails these tests too.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModules

    $module = 'Massokissed.LazyVM.Configuration'
    $realDefaultsPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Config\LazyVM.Defaults.psd1'

    function New-TestConfigDir {
        <#
          A Config folder holding the real defaults, plus one VM profile per
          entry in $Profiles (VM name -> the text of its VM.psd1).
        #>
        param(
            [hashtable]$Profiles = @{},
            [string]$UserSettings
        )

        $configDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $configDir | Out-Null
        Copy-Item -LiteralPath $realDefaultsPath -Destination $configDir

        foreach ($name in $Profiles.Keys) {
            $profileDir = Join-Path -Path (Join-Path -Path $configDir -ChildPath 'VMs') -ChildPath $name
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $profileDir -ChildPath 'VM.psd1') -Value $Profiles[$name]
        }

        if ($UserSettings) {
            Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'LazyVM.Config.psd1') -Value $UserSettings
        }
        return $configDir
    }

    function New-TestSettingsFile {
        <# A settings file under $TestDrive with the given text. #>
        param([Parameter(Mandatory)][string]$Text)

        $path = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid().ToString('N')).psd1"
        Set-Content -LiteralPath $path -Value $Text
        return $path
    }

    function New-TestSettings {
        <# A small stand-in for the defaults, with one setting of each kind. #>
        return @{
            VMName       = 'Default'
            MemoryGB     = 8
            EnableTpm    = $true
            GuestFolders = @('C:\Setup')
            WingetApps   = @(@{ Id = 'Git.Git' })
            Network      = @{ Switch = 'Default Switch' }
            AnyList      = @()
        }
    }
}

Describe 'Merge-UserSettings' {
    It 'applies valid values and returns the names it changed, sorted' {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text "@{ MemoryGB = 16; VMName = 'Dev'; EnableTpm = `$false }"

        $changed = InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
            param($Settings, $Path)
            Merge-UserSettings -Settings $Settings -UserPath $Path
        }

        $changed | Should -Be @('EnableTpm', 'MemoryGB', 'VMName')
        $settings.MemoryGB | Should -Be 16
        $settings.VMName | Should -Be 'Dev'
        $settings.EnableTpm | Should -BeFalse
    }

    It 'matches names case-insensitively but returns the script''s spelling' {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text '@{ memorygb = 16 }'

        $changed = InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
            param($Settings, $Path)
            Merge-UserSettings -Settings $Settings -UserPath $Path
        }

        $changed | Should -BeExactly @('MemoryGB')
    }

    It 'accepts a single item where a list belongs, as a one-item list' {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text "@{ GuestFolders = 'D:\Work' }"

        InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
            param($Settings, $Path)
            Merge-UserSettings -Settings $Settings -UserPath $Path
        }

        , $settings.GuestFolders | Should -BeOfType [System.Collections.IList]
        $settings.GuestFolders | Should -Be @('D:\Work')
    }

    It 'accepts any items in a list whose default is empty' {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text "@{ AnyList = @('text', 1, `$true) }"

        InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
            param($Settings, $Path)
            Merge-UserSettings -Settings $Settings -UserPath $Path
        }

        $settings.AnyList.Count | Should -Be 3
    }

    It "rejects <Case>" -ForEach @(
        @{ Case = 'an unknown setting'; Text = '@{ Bogus = 1 }'; Message = "*'Bogus' is not a setting*" }
        @{ Case = 'the wrong kind of value'; Text = "@{ MemoryGB = 'lots' }"; Message = "*'MemoryGB' should be a number, but is text.*" }
        @{ Case = 'a table where a list of text belongs'; Text = '@{ GuestFolders = @{ A = 1 } }'; Message = "*'GuestFolders' should be a list of text, but 1 item(s) are not.*" }
        @{ Case = 'list items of the wrong kind'; Text = "@{ WingetApps = @('Git.Git') }"; Message = "*'WingetApps' should be a list of tables, but 1 item(s) are not.*" }
    ) {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text $Text

        {
            InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
                param($Settings, $Path)
                Merge-UserSettings -Settings $Settings -UserPath $Path
            }
        } | Should -Throw -ExpectedMessage $Message
    }

    It 'reports every problem together and changes nothing' {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text "@{ VMName = 'Dev'; Bogus = 1; MemoryGB = 'lots' }"

        {
            InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
                param($Settings, $Path)
                Merge-UserSettings -Settings $Settings -UserPath $Path
            }
        } | Should -Throw -ExpectedMessage '*has 2 problem(s); nothing has been changed*'

        $settings.VMName | Should -Be 'Default'
    }

    It 'explains a file that is not a valid data file' {
        $settings = New-TestSettings
        $path = New-TestSettingsFile -Text '@{ MemoryGB = (Get-Date) }'

        {
            InModuleScope $module -Parameters @{ Settings = $settings; Path = $path } {
                param($Settings, $Path)
                Merge-UserSettings -Settings $Settings -UserPath $Path
            }
        } | Should -Throw -ExpectedMessage '*Your settings file could not be read*'
    }
}

Describe 'Resolve-SettingsRoot' {
    It 'uses <Expected> from <Source>' -ForEach @(
        @{ Override = 'E:\Override'; Configured = 'F:\Configured'; ScriptDir = 'D:\DevVM\Scripts'; Expected = 'E:\Override'; Source = 'the -Root parameter' }
        @{ Override = ''; Configured = 'F:\Configured'; ScriptDir = 'D:\DevVM\Scripts'; Expected = 'F:\Configured'; Source = 'Root in LazyVM.Config.psd1' }
        @{ Override = ''; Configured = ''; ScriptDir = 'D:\DevVM\Scripts'; Expected = 'D:\DevVM'; Source = 'the folder above D:\DevVM\Scripts' }
        @{ Override = ''; Configured = ''; ScriptDir = 'D:\DevVM\Scripts\'; Expected = 'D:\DevVM'; Source = 'the folder above D:\DevVM\Scripts' }
    ) {
        $root = InModuleScope $module -Parameters @{ Override = $Override; Configured = $Configured; ScriptDir = $ScriptDir } {
            param($Override, $Configured, $ScriptDir)
            Resolve-SettingsRoot -RootOverride $Override -ConfiguredRoot $Configured -ConfiguredIn 'LazyVM.Config.psd1' -ScriptDir $ScriptDir
        }

        $root.Path | Should -Be $Expected
        $root.Source | Should -Be $Source
    }

    It 'drops a trailing backslash' {
        $root = InModuleScope $module {
            Resolve-SettingsRoot -RootOverride 'D:\DevVM\' -ScriptDir 'D:\DevVM\Scripts'
        }

        $root.Path | Should -Be 'D:\DevVM'
    }

    It "refuses '<Root>' as the root folder" -ForEach @(
        @{ Root = 'D:\' }
        @{ Root = '\\server\share\DevVM' }
        @{ Root = 'DevVM' }
        @{ Root = 'D:\Dev"VM' }
    ) {
        {
            InModuleScope $module -Parameters @{ Root = $Root } {
                param($Root)
                Resolve-SettingsRoot -RootOverride $Root -ScriptDir 'D:\DevVM\Scripts'
            }
        } | Should -Throw -ExpectedMessage '*must be a folder on a local drive*'
    }

    It 'refuses to guess when the script is at the top of a drive' {
        {
            InModuleScope $module {
                Resolve-SettingsRoot -ScriptDir 'D:\Scripts'
            }
        } | Should -Throw -ExpectedMessage '*Could not work out the root folder*'
    }
}

Describe 'Resolve-HostPathSettings' {
    It 'joins relative paths to the root and keeps full paths as written' {
        $settings = InModuleScope $module {
            $settings = @{}
            foreach ($name in $script:HostPathSettings) {
                $settings[$name] = "Folder\$name"
            }
            $settings['VHDXRoot'] = 'E:\VMs'
            $settings['ISOPath'] = '\\nas\iso\win11.iso'
            $settings['LogFile'] = '.\Logs\Alpha.log'

            Resolve-HostPathSettings -Settings $settings -Root 'D:\DevVM'
            $settings
        }

        $settings.CheckpointDir | Should -Be 'D:\DevVM\Folder\CheckpointDir'
        $settings.VHDXRoot | Should -Be 'E:\VMs'
        $settings.ISOPath | Should -Be '\\nas\iso\win11.iso'
        $settings.LogFile | Should -Be 'D:\DevVM\Logs\Alpha.log'
    }

    It "refuses '<Value>'" -ForEach @(
        @{ Value = '' }
        @{ Value = 'D:VMs' }
        @{ Value = '\VMs' }
    ) {
        {
            InModuleScope $module -Parameters @{ Value = $Value } {
                param($Value)
                $settings = @{}
                foreach ($name in $script:HostPathSettings) {
                    $settings[$name] = 'Folder'
                }
                $settings['VHDXRoot'] = $Value

                Resolve-HostPathSettings -Settings $settings -Root 'D:\DevVM'
            }
        } | Should -Throw -ExpectedMessage "*'VHDXRoot' must be a path inside the root folder*"
    }
}

Describe 'Test-VMName' {
    It "returns <Expected> for '<Name>'" -ForEach @(
        @{ Name = 'MsDevVM'; Expected = $true }
        @{ Name = 'Dev-2026'; Expected = $true }
        @{ Name = 'A'; Expected = $true }
        @{ Name = 'Exactly15Chars1'; Expected = $true }
        @{ Name = 'SixteenCharacter'; Expected = $false }
        @{ Name = '-Dev'; Expected = $false }
        @{ Name = 'Dev VM'; Expected = $false }
        @{ Name = 'Dev_VM'; Expected = $false }
        @{ Name = ''; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } {
            param($Name)
            Test-VMName -Name $Name
        } | Should -Be $Expected
    }
}

Describe 'Expand-VMTokens' {
    It 'replaces {VM} in text settings and leaves the others alone' {
        $settings = @{
            LogFile  = 'Logs\{VM}.log'
            TaskName = 'LazyVM-Maintain-{VM}'
            MemoryGB = 8
            Folders  = @('{VM}')
        }

        InModuleScope $module -Parameters @{ Settings = $settings } {
            param($Settings)
            Expand-VMTokens -Settings $Settings -VMName 'Alpha'
        }

        $settings.LogFile | Should -Be 'Logs\Alpha.log'
        $settings.TaskName | Should -Be 'LazyVM-Maintain-Alpha'
        $settings.MemoryGB | Should -Be 8
        $settings.Folders | Should -Be @('{VM}')
    }
}

Describe 'ConvertTo-SettingsText' {
    It 'writes text that reads back as the same values' {
        $original = [ordered]@{
            Text      = "It's quoted"
            Flag      = $false
            Count     = 42
            Ratio     = 1.5
            Empty     = @()
            Folders   = @('C:\One', 'C:\Two')
            Apps      = @(@{ Id = 'Git.Git'; Scope = 'machine' })
            Network   = @{ Switch = 'Default Switch'; Vlan = 0 }
        }
        $path = Join-Path -Path $TestDrive -ChildPath 'RoundTrip.psd1'

        $text = InModuleScope $module -Parameters @{ Value = $original } {
            param($Value)
            ConvertTo-SettingsText -Value $Value
        }
        Set-Content -LiteralPath $path -Value $text
        $readBack = Import-PowerShellDataFile -LiteralPath $path

        $readBack.Text | Should -BeExactly "It's quoted"
        $readBack.Flag | Should -BeFalse
        $readBack.Count | Should -Be 42
        $readBack.Ratio | Should -Be 1.5
        $readBack.Empty.Count | Should -Be 0
        $readBack.Folders | Should -Be @('C:\One', 'C:\Two')
        $readBack.Apps[0].Id | Should -Be 'Git.Git'
        $readBack.Network.Switch | Should -Be 'Default Switch'
    }

    It 'refuses a value a settings file cannot hold' {
        {
            InModuleScope $module {
                ConvertTo-SettingsText -Value (Get-Date)
            }
        } | Should -Throw -ExpectedMessage '*cannot be written to a settings file*'
    }
}

Describe 'Resolve-VMSelection' {
    It 'picks the only VM when none is named' {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}' }

        InModuleScope $module -Parameters @{ ConfigDir = $configDir } {
            param($ConfigDir)
            Resolve-VMSelection -ConfigDir $ConfigDir
        } | Should -Be 'Alpha'
    }

    It 'returns the named VM with its folder''s spelling' {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}'; MsDevVM = '@{}' }

        InModuleScope $module -Parameters @{ ConfigDir = $configDir } {
            param($ConfigDir)
            Resolve-VMSelection -ConfigDir $ConfigDir -Requested 'msdevvm'
        } | Should -BeExactly 'MsDevVM'
    }

    It 'ignores a folder with no VM.psd1' {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}' }
        New-Item -ItemType Directory -Path (Join-Path -Path (Join-Path -Path $configDir -ChildPath 'VMs') -ChildPath 'Stray') | Out-Null

        InModuleScope $module -Parameters @{ ConfigDir = $configDir } {
            param($ConfigDir)
            Resolve-VMSelection -ConfigDir $ConfigDir
        } | Should -Be 'Alpha'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a VM that does not exist'; Profiles = @{ Alpha = '@{}' }; Requested = 'Beta'; Message = "*no VM profile named 'Beta' (VMs on this host: Alpha)*" }
        @{ Case = 'to run with no VMs'; Profiles = @{}; Requested = ''; Message = '*No VM profiles exist yet*' }
        @{ Case = 'to guess between several VMs'; Profiles = @{ Alpha = '@{}'; Beta = '@{}' }; Requested = ''; Message = '*several VMs (Alpha, Beta)*' }
    ) {
        $configDir = New-TestConfigDir -Profiles $Profiles

        {
            InModuleScope $module -Parameters @{ ConfigDir = $configDir; Requested = $Requested } {
                param($ConfigDir, $Requested)
                Resolve-VMSelection -ConfigDir $ConfigDir -Requested $Requested
            }
        } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'New-VMProfile' {
    It 'creates an empty profile from the defaults' {
        $configDir = New-TestConfigDir

        $path = New-VMProfile -ConfigDir $configDir -Name 'Alpha'

        $path | Should -Exist
        (Import-PowerShellDataFile -LiteralPath $path).Count | Should -Be 0
    }

    It 'sets the maintenance time an hour after the latest one in use, wrapping at midnight' {
        $configDir = New-TestConfigDir -Profiles @{
            Alpha = "@{ MaintenanceTime = '02:00' }"
            Beta  = "@{ MaintenanceTime = '23:30' }"
        }

        $path = New-VMProfile -ConfigDir $configDir -Name 'Gamma'

        (Import-PowerShellDataFile -LiteralPath $path).MaintenanceTime | Should -Be '00:30'
    }

    It 'counts a VM with no maintenance time of its own as using the default' {
        $defaultTime = (Import-PowerShellDataFile -LiteralPath $realDefaultsPath).MaintenanceTime
        $expected = [datetime]::ParseExact($defaultTime, 'HH:mm', $null).AddHours(1).ToString('HH:mm')
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}' }

        $path = New-VMProfile -ConfigDir $configDir -Name 'Beta'

        (Import-PowerShellDataFile -LiteralPath $path).MaintenanceTime | Should -Be $expected
    }

    It 'with -From, copies the shared settings and the tooling list, but not the per-VM ones' {
        $configDir = New-TestConfigDir -Profiles @{
            Alpha = "@{ MemoryGB = 32; LogFile = 'Logs\Alpha-Old.log'; GuestComputerName = 'ALPHA'; ScheduleTaskName = 'Alpha-Task' }"
        }
        $alphaDir = Join-Path -Path (Join-Path -Path $configDir -ChildPath 'VMs') -ChildPath 'Alpha'
        Set-Content -LiteralPath (Join-Path -Path $alphaDir -ChildPath 'Tooling.json') -Value '{ "Version": 1 }'

        $path = New-VMProfile -ConfigDir $configDir -Name 'Beta' -From 'Alpha'
        $profile = Import-PowerShellDataFile -LiteralPath $path

        $profile.MemoryGB | Should -Be 32
        $profile.Keys | Should -Not -Contain 'LogFile'
        $profile.Keys | Should -Not -Contain 'GuestComputerName'
        $profile.Keys | Should -Not -Contain 'ScheduleTaskName'
        Join-Path -Path (Split-Path -Path $path -Parent) -ChildPath 'Tooling.json' | Should -Exist
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an invalid name'; Name = 'Not Valid'; From = ''; Message = "*'Not Valid' cannot be used as a VM name*" }
        @{ Case = 'a name already in use'; Name = 'Alpha'; From = ''; Message = "*'Alpha' already exists*" }
        @{ Case = 'copying a VM that does not exist'; Name = 'Beta'; From = 'Nope'; Message = "*no VM profile named 'Nope' to copy*" }
    ) {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}' }

        { New-VMProfile -ConfigDir $configDir -Name $Name -From $From } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'Import-LazyVMConfiguration' {
    AfterAll {
        (Get-LazyVMSettings).Clear()
    }

    It 'layers the defaults, the user file and the VM profile, then names and roots everything' {
        $configDir = New-TestConfigDir -UserSettings '@{ MemMaxGB = 12 }' -Profiles @{
            Alpha = "@{ GuestComputerName = 'ALPHA-PC' }"
        }

        $result = Import-LazyVMConfiguration -ConfigDir $configDir -ScriptDir 'D:\DevVM\Scripts' -RootOverride 'E:\Lazy'
        $settings = $result.Settings

        $result.VMName | Should -Be 'Alpha'
        $result.Root | Should -Be 'E:\Lazy'
        $result.RootSource | Should -Be 'the -Root parameter'
        $result.ChangedKeys | Should -Be @('MemMaxGB')
        $result.ProfileKeys | Should -Be @('GuestComputerName')
        $settings.MemMaxGB | Should -Be 12
        $settings.GuestComputerName | Should -Be 'ALPHA-PC'
        $settings.ScheduleTaskName | Should -Be 'LazyVM-Maintain-Alpha'
        $settings.LogFile | Should -Be 'E:\Lazy\Logs\Alpha.log'
    }

    It 'fills the shared settings table in place, so every module sees the new values' {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}' }
        $shared = Get-LazyVMSettings

        $result = Import-LazyVMConfiguration -ConfigDir $configDir -ScriptDir 'D:\DevVM\Scripts'

        [object]::ReferenceEquals($result.Settings, $shared) | Should -BeTrue
        $shared.VMName | Should -Be 'Alpha'
    }

    It 'takes the root from the user file when there is no -Root' {
        $configDir = New-TestConfigDir -UserSettings "@{ Root = 'F:\FromUserFile' }" -Profiles @{ Alpha = '@{}' }

        $result = Import-LazyVMConfiguration -ConfigDir $configDir -ScriptDir 'D:\DevVM\Scripts'

        $result.Root | Should -Be 'F:\FromUserFile'
        $result.RootSource | Should -BeLike 'Root in *LazyVM.Config.psd1'
    }

    It 'reports a bad setting in the VM profile' {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{ Bogus = 1 }' }

        { Import-LazyVMConfiguration -ConfigDir $configDir -ScriptDir 'D:\DevVM\Scripts' } |
            Should -Throw -ExpectedMessage "*'Bogus' is not a setting*"
    }
}

Describe 'Read-LazyVMSettings' {
    AfterAll {
        (Get-LazyVMSettings).Clear()
    }

    It 'reads another VM''s settings without changing the shared ones' {
        $configDir = New-TestConfigDir -Profiles @{ Alpha = '@{}'; Beta = '@{}' }
        Import-LazyVMConfiguration -ConfigDir $configDir -ScriptDir 'D:\DevVM\Scripts' -VMName 'Alpha' | Out-Null

        $beta = Read-LazyVMSettings -ConfigDir $configDir -ScriptDir 'D:\DevVM\Scripts' -VMName 'Beta'

        $beta.Settings.VMName | Should -Be 'Beta'
        $beta.Settings.LogFile | Should -Be 'D:\DevVM\Logs\Beta.log'
        (Get-LazyVMSettings).VMName | Should -Be 'Alpha'
        [object]::ReferenceEquals($beta.Settings, (Get-LazyVMSettings)) | Should -BeFalse
    }
}
