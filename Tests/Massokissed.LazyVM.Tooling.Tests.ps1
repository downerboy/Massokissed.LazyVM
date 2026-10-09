# Massokissed.LazyVM.Tooling.Tests.ps1
# The tooling list: normalizing names, comparing lists, and carrying
# AwaitingReinstall items across a rebuild. Nothing here touches Hyper-V or a guest.
#
# Most of these functions are internal to the module, so each test runs its
# body with InModuleScope. Test data is built out here and passed in with
# -Parameters, because functions defined in this file are not visible inside
# the module's scope.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModules

    $module = 'Massokissed.LazyVM.Tooling'

    function New-TestProduct {
        param(
            [string]$ProductId = 'Microsoft.VisualStudio.Product.Community',
            [string]$ChannelId = 'VisualStudio.18.Release',
            [string]$DisplayName = 'Visual Studio Community 2026',
            [string[]]$Components = @(),
            [string[]]$Extensions = @(),
            [object[]]$UserExtensions = @()
        )

        return [ordered]@{
            ProductId      = $ProductId
            ChannelId      = $ChannelId
            DisplayName    = $DisplayName
            Components     = @($Components)
            Extensions     = @($Extensions)
            UserExtensions = @($UserExtensions)
        }
    }

    function New-TestRecord {
        param(
            [object[]]$Products = @(),
            [string[]]$WingetIds = @(),
            [string[]]$ProgramNames = @(),
            $AwaitingReinstall
        )

        $record = [ordered]@{
            Version        = 1
            Products       = @($Products)
            WingetPackages = @($WingetIds | ForEach-Object { [ordered]@{ Id = $_; Source = 'winget' } })
            Programs       = @($ProgramNames | ForEach-Object { [ordered]@{ Name = $_; Publisher = 'Test Publisher' } })
        }
        if ($AwaitingReinstall) {
            $record['AwaitingReinstall'] = $AwaitingReinstall
        }
        return $record
    }

    function ConvertTo-RecordFromDisk {
        <# The same record as Read-ToolingRecord would return it after Save-ToolingRecord. #>
        param([Parameter(Mandatory)]$Record)

        return ($Record | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }
}

Describe 'Get-NormalizedProgramName' {
    It "reduces '<Name>' to '<Expected>'" -ForEach @(
        @{ Name = 'LINQPad 9 version 9.10.20'; Expected = 'LINQPad 9' }
        @{ Name = 'JetBrains dotPeek 2026.3 EAP 5'; Expected = 'JetBrains dotPeek' }
        @{ Name = 'Notepad++ (8.7.1)'; Expected = 'Notepad++' }
        @{ Name = 'Node.js v22.11.0'; Expected = 'Node.js' }
        @{ Name = '7-Zip 24.08 (x64)'; Expected = '7-Zip (x64)' }
        @{ Name = 'Some Tool Preview 3'; Expected = 'Some Tool' }
        @{ Name = 'Some Tool RC2'; Expected = 'Some Tool' }
        @{ Name = 'WinMerge'; Expected = 'WinMerge' }
    ) {
        InModuleScope $module -Parameters @{ Name = $Name } {
            param($Name)
            Get-NormalizedProgramName -Name $Name
        } | Should -BeExactly $Expected
    }
}

Describe 'Get-SetChange' {
    It 'lists additions then removals, each sorted, with the label' {
        $changes = InModuleScope $module {
            @(Get-SetChange -Label 'winget' -Old @('B', 'A', 'C') -New @('C', 'E', 'D'))
        }

        $changes | Should -Be @('+ winget: D', '+ winget: E', '- winget: A', '- winget: B')
    }

    It 'ignores case, so a re-cased name is not a change' {
        $changes = InModuleScope $module {
            @(Get-SetChange -Label 'program' -Old @('LINQPad 9') -New @('linqpad 9'))
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'ignores empty items and duplicates' {
        $changes = InModuleScope $module {
            @(Get-SetChange -Label 'winget' -Old @('A', '', $null) -New @('A', 'A'))
        }

        $changes | Should -BeNullOrEmpty
    }
}

Describe 'Get-RecordField' {
    It 'reads a field from a list built in memory' {
        Get-RecordField -Item ([ordered]@{ Name = 'Git' }) -Name 'Name' | Should -Be 'Git'
    }

    It 'reads a field from a list read back from disk' {
        Get-RecordField -Item ([pscustomobject]@{ Name = 'Git' }) -Name 'Name' | Should -Be 'Git'
    }

    It 'returns $null for a missing field in either form' {
        Get-RecordField -Item ([ordered]@{ Name = 'Git' }) -Name 'Publisher' | Should -BeNullOrEmpty
        Get-RecordField -Item ([pscustomobject]@{ Name = 'Git' }) -Name 'Publisher' | Should -BeNullOrEmpty
    }

    It 'returns $null for no item' {
        Get-RecordField -Item $null -Name 'Name' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProductExtensionIdentities' {
    It 'uses the marketplace link where known, and name and id otherwise' {
        $product = New-TestProduct -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.exported') -UserExtensions @(
            [ordered]@{ Id = 'linked-id'; DisplayName = 'Linked'; MarketplaceItem = 'pub.linked' }
            [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; MarketplaceItem = '' }
        )

        $identities = InModuleScope $module -Parameters @{ Product = $product } {
            param($Product)
            @(Get-ProductExtensionIdentities -Product $Product)
        }

        $identities | Should -Be @(
            'https://marketplace.visualstudio.com/items?itemName=pub.exported'
            'https://marketplace.visualstudio.com/items?itemName=pub.linked'
            'Local Only [local-id]'
        )
    }
}

Describe 'Test-ToolingExcluded' {
    BeforeAll {
        $settings = Get-LazyVMSettings
        $settings['ToolingWingetExclude'] = @('Microsoft.VisualStudio.*', 'Microsoft.Edge')
    }

    AfterAll {
        (Get-LazyVMSettings).Clear()
    }

    It "returns <Expected> for '<PackageId>'" -ForEach @(
        @{ PackageId = 'Microsoft.VisualStudio.2026.Community'; Expected = $true }
        @{ PackageId = 'Microsoft.Edge'; Expected = $true }
        @{ PackageId = 'Microsoft.EdgeWebView2Runtime'; Expected = $false }
        @{ PackageId = 'Git.Git'; Expected = $false }
    ) {
        InModuleScope $module -Parameters @{ PackageId = $PackageId } {
            param($PackageId)
            Test-ToolingExcluded -PackageId $PackageId
        } | Should -Be $Expected
    }
}

Describe 'ConvertTo-ToolingRecord' {
    BeforeAll {
        $settings = Get-LazyVMSettings
        $settings['ToolingWingetExclude'] = @('Microsoft.VisualStudio.*')

        # Shaped like Get-GuestToolingInventory's result, which arrives from
        # the guest as objects rather than dictionaries.
        $inventory = [pscustomobject]@{
            Products       = @(
                [pscustomobject]@{
                    ProductId          = 'Microsoft.VisualStudio.Product.Community'
                    ChannelId          = 'VisualStudio.18.Release'
                    DisplayName        = 'Visual Studio Community 2026'
                    Version            = '18.0.1'
                    Components         = @('Microsoft.Component.MSBuild', 'Component.OpenJDK', 'Microsoft.Component.MSBuild')
                    ExportedExtensions = @('https://marketplace.visualstudio.com/items?itemName=pub.ext')
                    UserExtensions     = @(
                        [pscustomobject]@{ Id = 'z-ext'; DisplayName = 'Zed'; Publisher = 'P'; MoreInfo = ''; Version = '2.0' }
                        [pscustomobject]@{ Id = 'a-ext'; DisplayName = 'Aye'; Publisher = 'P'; MoreInfo = ''; Version = '1.0' }
                    )
                }
            )
            WingetPackages = @(
                [pscustomobject]@{ Id = 'Microsoft.VisualStudio.2026.Community'; Source = 'winget'; Version = '18.0' }
                [pscustomobject]@{ Id = 'LINQPad.LINQPad.9'; Source = 'winget'; Version = '9.10' }
                [pscustomobject]@{ Id = 'Git.Git'; Source = 'winget'; Version = '2.47' }
            )
            Programs       = @(
                [pscustomobject]@{ Name = 'LINQPad 9 version 9.10.20'; Publisher = 'Joseph Albahari' }
                [pscustomobject]@{ Name = 'LINQPad 9 version 9.10.21'; Publisher = 'Joseph Albahari' }
                [pscustomobject]@{ Name = 'Git version 2.47.1'; Publisher = 'The Git Development Community' }
            )
        }

        $record = InModuleScope $module -Parameters @{ Inventory = $inventory } {
            param($Inventory)
            ConvertTo-ToolingRecord -Inventory $Inventory
        }
    }

    AfterAll {
        (Get-LazyVMSettings).Clear()
    }

    It 'leaves out excluded winget packages and sorts the rest by id' {
        @($record.WingetPackages | ForEach-Object { $_.Id }) | Should -Be @('Git.Git', 'LINQPad.LINQPad.9')
    }

    It 'strips versions from program names and keeps one entry per name' {
        @($record.Programs | ForEach-Object { $_.Name }) | Should -Be @('Git', 'LINQPad 9')
    }

    It 'sorts components and removes duplicates' {
        $record.Products[0].Components | Should -Be @('Component.OpenJDK', 'Microsoft.Component.MSBuild')
    }

    It 'keeps the exported extensions' {
        $record.Products[0].Extensions | Should -Be @('https://marketplace.visualstudio.com/items?itemName=pub.ext')
    }

    It 'sorts user extensions by id and records no versions' {
        $userExtensions = @($record.Products[0].UserExtensions)

        @($userExtensions | ForEach-Object { $_.Id }) | Should -Be @('a-ext', 'z-ext')
        $userExtensions[0].Keys | Should -Not -Contain 'Version'
    }
}

Describe 'Compare-ToolingRecord' {
    It 'finds no changes between identical lists' {
        $old = New-TestRecord -Products @(New-TestProduct -Components @('A')) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9')
        $new = New-TestRecord -Products @(New-TestProduct -Components @('A')) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'finds no changes between a list in memory and the same list read back from disk' {
        $product = New-TestProduct -Components @('A', 'B') -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.ext') -UserExtensions @(
            [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P'; MoreInfo = ''; MarketplaceItem = '' }
        )
        $inMemory = New-TestRecord -Products @($product) -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9') -AwaitingReinstall ([ordered]@{
                Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                Extensions = @()
            })
        $fromDisk = ConvertTo-RecordFromDisk -Record $inMemory

        $changes = InModuleScope $module -Parameters @{ Old = $fromDisk; New = $inMemory } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'reports a product added and a product removed' {
        $old = New-TestRecord -Products @(New-TestProduct -ProductId 'Old.Product' -ChannelId 'C1' -DisplayName 'Old Product')
        $new = New-TestRecord -Products @(New-TestProduct -ProductId 'New.Product' -ChannelId 'C1' -DisplayName 'New Product')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -Be @('+ product: New Product [New.Product, C1]', '- product: Old Product [Old.Product, C1]')
    }

    It 'treats the same product on another channel as a different product' {
        $old = New-TestRecord -Products @(New-TestProduct -ChannelId 'VisualStudio.18.Release' -DisplayName 'VS')
        $new = New-TestRecord -Products @(New-TestProduct -ChannelId 'VisualStudio.18.Preview' -DisplayName 'VS')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes.Count | Should -Be 2
    }

    It 'reports components added and removed within a product' {
        $old = New-TestRecord -Products @(New-TestProduct -DisplayName 'VS' -Components @('Keep', 'Gone'))
        $new = New-TestRecord -Products @(New-TestProduct -DisplayName 'VS' -Components @('Keep', 'Added'))

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -Be @('+ VS component: Added', '- VS component: Gone')
    }

    It 'matches a per-user extension with the same extension reinstalled for all users' {
        $old = New-TestRecord -Products @(New-TestProduct -UserExtensions @(
                [ordered]@{ Id = 'ext-id'; DisplayName = 'Ext'; MarketplaceItem = 'pub.ext' }
            ))
        $new = New-TestRecord -Products @(New-TestProduct -Extensions @('https://marketplace.visualstudio.com/items?itemName=pub.ext'))

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -BeNullOrEmpty
    }

    It 'reports winget packages and programs added and removed' {
        $old = New-TestRecord -WingetIds @('Git.Git') -ProgramNames @('LINQPad 9')
        $new = New-TestRecord -WingetIds @('Microsoft.PowerShell') -ProgramNames @('JetBrains dotPeek')

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -Be @(
            '+ winget: Microsoft.PowerShell'
            '- winget: Git.Git'
            '+ program: JetBrains dotPeek'
            '- program: LINQPad 9'
        )
    }

    It 'reports an item leaving the awaiting-reinstall list' {
        $old = New-TestRecord -AwaitingReinstall ([ordered]@{ Programs = @([ordered]@{ Name = 'Old Tool' }); Extensions = @() })
        $new = New-TestRecord -AwaitingReinstall ([ordered]@{ Programs = @(); Extensions = @() })

        $changes = InModuleScope $module -Parameters @{ Old = $old; New = $new } {
            param($Old, $New)
            @(Compare-ToolingRecord -Old $Old -New $New)
        }

        $changes | Should -Be @('- awaiting reinstall: program Old Tool')
    }
}

Describe 'Merge-AwaitingReinstall' {
    BeforeAll {
        Mock Write-Log -ModuleName $module
    }

    It 'keeps a program that is still missing, both in the list and as awaiting' {
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                    Extensions = @()
                }))
        $record = New-TestRecord -ProgramNames @('LINQPad 9')

        InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            Merge-AwaitingReinstall -Record $Record -Previous $Previous
        }

        @($record.Programs | ForEach-Object { $_.Name }) | Should -Be @('LINQPad 9', 'Old Tool')
        @($record.AwaitingReinstall.Programs | ForEach-Object { $_.Name }) | Should -Be @('Old Tool')
        Should -Invoke Write-Log -ModuleName $module -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'drops a program from the awaiting list once it is installed again' {
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @([ordered]@{ Name = 'Old Tool'; Publisher = 'P' })
                    Extensions = @()
                }))
        $record = New-TestRecord -ProgramNames @('Old Tool')

        InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            Merge-AwaitingReinstall -Record $Record -Previous $Previous
        }

        @($record.Programs | ForEach-Object { $_.Name }) | Should -Be @('Old Tool')
        $record.AwaitingReinstall.Programs | Should -BeNullOrEmpty
    }

    It 'puts a still-missing extension back under its product and keeps it awaiting' {
        $productKey = 'Microsoft.VisualStudio.Product.Community|VisualStudio.18.Release'
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @()
                    Extensions = @([ordered]@{ ProductKey = $productKey; Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P' })
                }))
        $record = New-TestRecord -Products @(New-TestProduct)

        InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            Merge-AwaitingReinstall -Record $Record -Previous $Previous
        }

        @($record.Products[0].UserExtensions | ForEach-Object { $_.Id }) | Should -Be @('local-id')
        @($record.AwaitingReinstall.Extensions | ForEach-Object { $_.Id }) | Should -Be @('local-id')
    }

    It 'drops an extension from the awaiting list once it is installed again' {
        $productKey = 'Microsoft.VisualStudio.Product.Community|VisualStudio.18.Release'
        $previous = ConvertTo-RecordFromDisk -Record (New-TestRecord -AwaitingReinstall ([ordered]@{
                    Programs   = @()
                    Extensions = @([ordered]@{ ProductKey = $productKey; Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P' })
                }))
        $record = New-TestRecord -Products @(New-TestProduct -UserExtensions @(
                [ordered]@{ Id = 'local-id'; DisplayName = 'Local Only'; Publisher = 'P'; MoreInfo = '' }
            ))

        InModuleScope $module -Parameters @{ Record = $record; Previous = $previous } {
            param($Record, $Previous)
            Merge-AwaitingReinstall -Record $Record -Previous $Previous
        }

        @($record.Products[0].UserExtensions).Count | Should -Be 1
        $record.AwaitingReinstall.Extensions | Should -BeNullOrEmpty
    }

    It 'records an empty awaiting list when there is no previous list' {
        $record = New-TestRecord -ProgramNames @('LINQPad 9')

        InModuleScope $module -Parameters @{ Record = $record } {
            param($Record)
            Merge-AwaitingReinstall -Record $Record -Previous $null
        }

        $record.AwaitingReinstall.Programs | Should -BeNullOrEmpty
        $record.AwaitingReinstall.Extensions | Should -BeNullOrEmpty
        Should -Invoke Write-Log -ModuleName $module -Times 0 -Exactly -Scope It
    }
}
