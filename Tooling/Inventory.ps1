# Inventory.ps1 - part of Massokissed.LazyVM.Tooling. Inventory of the tooling installed in the guest (-ShowTooling).
# Dot-sourced by Massokissed.LazyVM.Tooling.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  TOOLING INVENTORY
#
#  Reads what is installed in the guest without changing anything:
#    - every product the Visual Studio Installer manages (Visual Studio of any
#      version and edition, SSMS 21+, Build Tools), each with its exported
#      .vsconfig of workloads and components
#    - Visual Studio extensions, both instance-wide (in the export) and the
#      per-user ones installed from Manage Extensions (read from their
#      manifests, which the export does not include)
#    - winget packages, by identifier and source
#    - every other program in the Windows uninstall list
#
#  -ShowTooling runs this on its own and saves the result on the host, so the
#  data can be checked before anything is built on it.
# ─────────────────────────────────────────────────────────────────────────────

function Get-GuestToolingInventory {
    $inventory = Invoke-GuestScript -Activity 'tooling inventory' -TimeoutMinutes 30 `
        -ArgumentList @($CFG.GuestSetupDir, @($CFG.ToolingWingetCheck)) -ScriptBlock {
        param($setupDir, $wingetCheck)
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

        $notes = [System.Collections.Generic.List[string]]::new()

        # ── products managed by the Visual Studio Installer ────────────────
        $products = @()
        $installerDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
        $vswhere = Join-Path $installerDir 'vswhere.exe'
        $vsInstaller = Join-Path $installerDir 'vs_installer.exe'

        if (Test-Path $vswhere) {
            $raw = & $vswhere -all -prerelease -products * -format json -utf8 2>$null
            # Windows PowerShell 5.1 hands a JSON array down the pipeline as ONE
            # object, so @(... | ConvertFrom-Json) would be a one-item list whose
            # item is the whole array. Enumerating it with foreach splits it.
            $instances = @()
            if ($raw) {
                $parsed = ($raw -join "`n") | ConvertFrom-Json
                foreach ($item in $parsed) { $instances += $item }
            }

            foreach ($instance in $instances) {
                $product = [ordered]@{
                    InstanceId     = $instance.instanceId
                    ProductId      = $instance.productId
                    ChannelId      = $instance.channelId
                    DisplayName    = $instance.displayName
                    Version        = $instance.installationVersion
                    ProductLine    = $instance.catalog.productLineVersion
                    InstallPath    = $instance.installationPath
                    IsComplete     = $instance.isComplete
                    Components     = @()
                    ExportedExtensions = @()
                    UserExtensions = @()
                }

                # Workloads, components and instance-wide marketplace extensions,
                # as the installer itself would reproduce them.
                if (Test-Path $vsInstaller) {
                    $configPath = Join-Path $setupDir "inventory-$($instance.instanceId).vsconfig"
                    Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                    $proc = Start-Process -FilePath $vsInstaller -Wait -PassThru -NoNewWindow -ArgumentList @(
                        'export', '--installPath', "`"$($instance.installationPath)`"", '--config', "`"$configPath`"", '--quiet'
                    )
                    if (Test-Path $configPath) {
                        try {
                            $config = Get-Content $configPath -Raw | ConvertFrom-Json
                            $product.Components = @($config.components)
                            if ($config.PSObject.Properties['extensions']) { $product.ExportedExtensions = @($config.extensions) }
                        }
                        catch { $notes.Add("could not read the exported configuration for $($instance.displayName): $($_.Exception.Message)") }
                        Remove-Item $configPath -Force -ErrorAction SilentlyContinue
                    }
                    else { $notes.Add("export produced no configuration for $($instance.displayName) (exit $($proc.ExitCode))") }
                }

                # Per-user extensions live in a folder named <version>_<instanceId>,
                # which ties each one to its product instance.
                $userRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio'
                $instanceDirs = @(Get-ChildItem -Path $userRoot -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like "*_$($instance.instanceId)" })
                foreach ($dir in $instanceDirs) {
                    $extensionsDir = Join-Path $dir.FullName 'Extensions'
                    foreach ($manifestFile in @(Get-ChildItem -Path $extensionsDir -Filter 'extension.vsixmanifest' -Recurse -File -ErrorAction SilentlyContinue)) {
                        try {
                            [xml]$manifest = Get-Content -Path $manifestFile.FullName -Raw
                            $metadata = $manifest.PackageManifest.Metadata
                            if (-not $metadata -or -not $metadata.Identity) { continue }
                            $product.UserExtensions += [ordered]@{
                                Id          = $metadata.Identity.Id
                                Version     = $metadata.Identity.Version
                                Publisher   = $metadata.Identity.Publisher
                                DisplayName = "$($metadata.DisplayName)"
                                MoreInfo    = "$($metadata.MoreInfo)"
                                Folder      = $manifestFile.Directory.FullName.Substring($extensionsDir.Length).TrimStart('\')
                            }
                        }
                        catch { $notes.Add("could not read $($manifestFile.FullName): $($_.Exception.Message)") }
                    }
                }

                $products += $product
            }
        }
        else { $notes.Add('vswhere.exe not found: no Visual Studio Installer products are installed') }

        # ── winget packages ─────────────────────────────────────────────────
        $winget = $null
        $cmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($cmd) { $winget = $cmd.Source }
        else {
            $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path $candidate) { $winget = $candidate }
            else {
                $found = @(Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending)
                if ($found.Count -gt 0) { $winget = $found[0].FullName }
            }
        }

        $wingetPackages = @()
        if ($winget) {
            $exportFile = Join-Path $setupDir 'inventory-winget.json'
            Remove-Item $exportFile -Force -ErrorAction SilentlyContinue
            & $winget export --output $exportFile --include-versions --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            if (Test-Path $exportFile) {
                $export = Get-Content $exportFile -Raw | ConvertFrom-Json
                foreach ($source in @($export.Sources)) {
                    foreach ($package in @($source.Packages)) {
                        $wingetPackages += [ordered]@{
                            Id      = $package.PackageIdentifier
                            Version = "$($package.Version)"
                            Source  = $source.SourceDetails.Name
                        }
                    }
                }
                Remove-Item $exportFile -Force -ErrorAction SilentlyContinue
            }
            else { $notes.Add("winget export produced no file (exit $LASTEXITCODE)") }

            # Packages winget can match but leaves out of its export.
            foreach ($id in @($wingetCheck)) {
                if (-not $id) { continue }
                if (@($wingetPackages | Where-Object { $_.Id -eq $id }).Count -gt 0) { continue }
                $listed = & $winget list --id $id --exact --accept-source-agreements --disable-interactivity 2>&1
                if ($LASTEXITCODE -eq 0 -and ($listed -join ' ') -match [regex]::Escape($id)) {
                    $wingetPackages += [ordered]@{ Id = $id; Version = ''; Source = 'winget' }
                }
            }
        }
        else { $notes.Add('winget is not available in the guest') }

        # ── everything in the Windows uninstall list ───────────────────────
        # Updates, components of other products and entries with no name are
        # left out: they are not things anyone installs on their own.
        $uninstallKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $programs = @()
        foreach ($key in $uninstallKeys) {
            foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
                $properties = $entry.PSObject.Properties
                if (-not $properties['DisplayName'] -or -not $entry.DisplayName) { continue }
                if ($properties['SystemComponent'] -and $entry.SystemComponent -eq 1) { continue }
                if ($properties['ParentKeyName'] -and $entry.ParentKeyName) { continue }
                if ($properties['ReleaseType'] -and "$($entry.ReleaseType)" -match 'Update|Hotfix') { continue }
                $programs += [ordered]@{
                    Name      = "$($entry.DisplayName)"
                    Version   = if ($properties['DisplayVersion']) { "$($entry.DisplayVersion)" } else { '' }
                    Publisher = if ($properties['Publisher']) { "$($entry.Publisher)" } else { '' }
                    Key       = $entry.PSChildName
                    InstallDate = if ($properties['InstallDate']) { "$($entry.InstallDate)" } else { '' }
                    Scope     = if ($key -like 'HKCU:*') { 'user' } else { 'machine' }
                }
            }
        }
        # The same program can be listed under both registry views.
        $programs = @($programs | Group-Object { "$($_.Name)|$($_.Version)" } |
                ForEach-Object { $_.Group[0] } | Sort-Object { $_.Name })

        return [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            UserName       = $env:USERNAME
            TakenAt        = (Get-Date).ToString('o')
            Products       = @($products)
            WingetPackages = @($wingetPackages)
            Programs       = @($programs)
            Notes          = @($notes)
        }
    }

    return $inventory
}

function Show-GuestTooling {
    <#
      -ShowTooling: take an inventory, save it on the host and log a summary.
      Read-only in the guest.
    #>
    Write-Log 'Guest Tooling Inventory' 'PHASE'
    Open-GuestSession -Purpose 'take the inventory' | Out-Null

    $inventory = Get-GuestToolingInventory

    $toolingDir = Join-Path $CFG.StateDir 'tooling'
    if (-not (Test-Path -LiteralPath $toolingDir)) { New-Item -ItemType Directory -Path $toolingDir -Force | Out-Null }
    $path = Join-Path $toolingDir ('inventory-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8

    foreach ($product in @($inventory.Products)) {
        Write-Log "$($product.DisplayName) $($product.Version)  [$($product.ProductId), $($product.ChannelId)]" 'OK'
        Write-Log "  $(@($product.Components).Count) workload/component id(s), $(@($product.ExportedExtensions).Count) instance-wide extension(s), $(@($product.UserExtensions).Count) per-user extension(s)" 'INFO'
        foreach ($extension in @($product.ExportedExtensions)) {
            Write-Log "    instance-wide: $extension" 'INFO'
        }
        foreach ($extension in @($product.UserExtensions)) {
            Write-Log "    per-user: $($extension.DisplayName) $($extension.Version)  [$($extension.Id)]" 'INFO'
        }
    }

    $packages = @($inventory.WingetPackages | Sort-Object { $_.Id })
    Write-Log "winget packages: $($packages.Count)" 'OK'
    foreach ($package in $packages) {
        Write-Log ("  {0}  {1}  ({2})" -f $package.Id, $package.Version, $package.Source) 'INFO'
    }

    $programs = @($inventory.Programs)
    Write-Log "Installed programs (Windows uninstall list): $($programs.Count)" 'OK'
    foreach ($program in $programs) {
        $details = @($program.Version, $program.Publisher, $program.Scope) | Where-Object { $_ }
        Write-Log ("  {0}  ({1})" -f $program.Name, ($details -join ', ')) 'INFO'
    }
    foreach ($note in @($inventory.Notes)) { Write-Log "  $note" 'WARN' }
    Write-Log "Inventory saved to $path" 'OK'

    # What the next maintenance run (or -RecordTooling) would adopt. Nothing is recorded here.
    $recorded = Read-ToolingRecord -Path (Get-ToolingPaths).Record

    # Which per-user extensions a rebuild could reinstall from the marketplace.
    $resolved = ConvertTo-ToolingRecord -Inventory $inventory
    Add-MarketplaceItems -Record $resolved -Previous $recorded
    foreach ($product in @($resolved.Products)) {
        foreach ($extension in @($product.UserExtensions)) {
            $item = Get-RecordField -Item $extension -Name 'MarketplaceItem'
            if ($item) { Write-Log "  marketplace match: $($extension.DisplayName) -> $item" 'OK' }
            else { Write-Log "  no marketplace match: $($extension.DisplayName) [$($extension.Id)] - a rebuild lists it for reinstalling by hand" 'WARN' }
        }
    }

    if (-not $recorded) {
        Write-Log 'No tooling list recorded yet: the next run records this as the first one.' 'INFO'
        return
    }
    $observed = ConvertTo-ToolingRecord -Inventory $inventory
    Add-MarketplaceItems -Record $observed -Previous $recorded
    Merge-AwaitingReinstall -Record $observed -Previous $recorded
    $changes = @(Compare-ToolingRecord -Old $recorded -New $observed)
    if ($changes.Count -eq 0) {
        Write-Log 'Matches the recorded tooling list: nothing to adopt.' 'OK'
    }
    else {
        Write-Log "The next run would adopt $($changes.Count) change(s):" 'INFO'
        foreach ($change in $changes) { Write-Log "  $change" 'INFO' }
    }
}
