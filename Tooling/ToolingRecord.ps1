# ToolingRecord.ps1 - part of Massokissed.LazyVM.Tooling. The tooling list: recording changes, checkpoints, restore points and revert.
# Dot-sourced by Massokissed.LazyVM.Tooling.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  TOOLING RECORD
#
#  Each VM's tooling list is Config\VMs\<Name>\Tooling.json. The daily
#  maintenance run compares the guest with it and adopts any change, after
#  first taking a Hyper-V checkpoint, so every recorded version of the list
#  has a checkpoint of the VM as it was then:
#
#    checkpoint  "Tooling <stamp>"                 the VM when it was recorded
#    file        History\Tooling-<stamp>.json      the list recorded with it
#
#  -Revert <stamp> applies both. A dated copy of the list is also kept for
#  every day the check runs (History\Daily), whether or not it changed.
#
#  Only additions and removals count as changes. Versions are not compared,
#  and version numbers are stripped from program names, so routine updates of
#  Visual Studio, SDKs or runtimes never cause a checkpoint.
# ─────────────────────────────────────────────────────────────────────────────

function Get-RecordField {
    <#
      A field of a tooling-list entry, or $null. Lists built in memory are
      dictionaries and lists read back from disk are objects; this reads
      either, so the same entry compares equal whichever form it is in.
    #>
    param(
        $Item,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $property = $Item.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-NormalizedProgramName {
    <# "LINQPad 9 version 9.10.20" -> "LINQPad 9"; "JetBrains dotPeek 2026.3 EAP 5" -> "JetBrains dotPeek". #>
    param([string]$Name)

    $normalized = $Name
    $normalized = $normalized -replace '\(\s*\d+(\.\d+)+\s*\)', ''
    $normalized = $normalized -replace '\b(version\s+)?v?\d+(\.\d+)+\b', ''
    $normalized = $normalized -replace '\b(EAP|Preview|RC|Beta)\s*\d*\b', ''
    $normalized = $normalized -replace '\s+-\s*$', ''
    $normalized = $normalized -replace '\s{2,}', ' '
    return $normalized.Trim(' ', '-')
}

function Test-ToolingExcluded {
    <# True for winget packages that are part of Windows or managed by the Visual Studio Installer. #>
    param([string]$PackageId)

    foreach ($pattern in @($CFG.ToolingWingetExclude)) {
        if ($PackageId -like $pattern) { return $true }
    }
    return $false
}

function ConvertTo-ToolingRecord {
    <# Reduces an inventory to the tooling list: what is installed, without versions. #>
    param([Parameter(Mandatory)]$Inventory)

    $products = @()
    foreach ($product in @($Inventory.Products)) {
        $userExtensions = @()
        foreach ($extension in @($product.UserExtensions)) {
            $userExtensions += [ordered]@{
                Id          = $extension.Id
                DisplayName = $extension.DisplayName
                Publisher   = $extension.Publisher
                MoreInfo    = $extension.MoreInfo
            }
        }
        $products += [ordered]@{
            ProductId      = $product.ProductId
            ChannelId      = $product.ChannelId
            DisplayName    = $product.DisplayName
            Components     = @(@($product.Components) | Sort-Object -Unique)
            Extensions     = @(@($product.ExportedExtensions) | Sort-Object -Unique)
            UserExtensions = @($userExtensions | Sort-Object { $_.Id })
        }
    }

    $packages = @()
    foreach ($package in @($Inventory.WingetPackages)) {
        if (Test-ToolingExcluded $package.Id) { continue }
        $packages += [ordered]@{ Id = $package.Id; Source = $package.Source }
    }

    $programs = @()
    foreach ($program in @($Inventory.Programs)) {
        $programs += [ordered]@{ Name = Get-NormalizedProgramName $program.Name; Publisher = $program.Publisher }
    }
    $programs = @($programs | Group-Object { $_.Name } | ForEach-Object { $_.Group[0] } | Sort-Object { $_.Name })

    return [ordered]@{
        Version        = 1
        RecordedAt     = (Get-Date).ToString('o')
        Products       = @($products | Sort-Object { "$($_.ProductId)|$($_.ChannelId)" })
        WingetPackages = @($packages | Sort-Object { $_.Id })
        Programs       = $programs
    }
}

function Get-SetChange {
    <# "+ label: item" for each item only in New, "- label: item" for each only in Old. #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [string[]]$Old = @(),
        [string[]]$New = @()
    )

    $oldSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $newSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Old) { if ($item) { [void]$oldSet.Add($item) } }
    foreach ($item in $New) { if ($item) { [void]$newSet.Add($item) } }

    $changes = @()
    foreach ($item in @($newSet | Sort-Object)) { if (-not $oldSet.Contains($item)) { $changes += "+ ${Label}: $item" } }
    foreach ($item in @($oldSet | Sort-Object)) { if (-not $newSet.Contains($item)) { $changes += "- ${Label}: $item" } }
    return $changes
}

function Get-ProductExtensionIdentities {
    <#
      How a product's extensions are compared: by marketplace link wherever
      one is known, so an extension that a rebuild reinstalled for all users
      matches the per-user one recorded before; by name and id otherwise.
    #>
    param([Parameter(Mandatory)]$Product)

    $identities = @(@($Product.Extensions) | Where-Object { $_ })
    foreach ($extension in @($Product.UserExtensions)) {
        $item = Get-RecordField -Item $extension -Name 'MarketplaceItem'
        if ($item) {
            $identities += "https://marketplace.visualstudio.com/items?itemName=$item"
        }
        else {
            $identities += "$($extension.DisplayName) [$($extension.Id)]"
        }
    }
    return @($identities | Sort-Object -Unique)
}

function Compare-ToolingRecord {
    <# The additions and removals between two tooling lists, as readable lines. #>
    param(
        [Parameter(Mandatory)]$Old,
        [Parameter(Mandatory)]$New
    )

    $changes = @()
    $oldProducts = @{}
    foreach ($product in @($Old.Products)) { $oldProducts["$($product.ProductId)|$($product.ChannelId)"] = $product }
    $newProducts = @{}
    foreach ($product in @($New.Products)) { $newProducts["$($product.ProductId)|$($product.ChannelId)"] = $product }

    foreach ($key in @($newProducts.Keys | Sort-Object)) {
        $product = $newProducts[$key]
        if (-not $oldProducts.ContainsKey($key)) {
            $changes += "+ product: $($product.DisplayName) [$($product.ProductId), $($product.ChannelId)]"
            continue
        }
        $before = $oldProducts[$key]
        $name = $product.DisplayName
        $changes += Get-SetChange -Label "$name component" -Old @($before.Components) -New @($product.Components)
        $changes += Get-SetChange -Label "$name extension" `
            -Old @(Get-ProductExtensionIdentities -Product $before) -New @(Get-ProductExtensionIdentities -Product $product)
    }
    foreach ($key in @($oldProducts.Keys | Sort-Object)) {
        if (-not $newProducts.ContainsKey($key)) {
            $product = $oldProducts[$key]
            $changes += "- product: $($product.DisplayName) [$($product.ProductId), $($product.ChannelId)]"
        }
    }

    $changes += Get-SetChange -Label 'winget' -Old @(@($Old.WingetPackages) | ForEach-Object { $_.Id }) -New @(@($New.WingetPackages) | ForEach-Object { $_.Id })
    $changes += Get-SetChange -Label 'program' -Old @(@($Old.Programs) | ForEach-Object { $_.Name }) -New @(@($New.Programs) | ForEach-Object { $_.Name })
    $changes += Get-SetChange -Label 'awaiting reinstall' -Old @(Get-AwaitingNames -Record $Old) -New @(Get-AwaitingNames -Record $New)
    return @($changes)
}

function Get-ToolingPaths {
    $historyDir = Join-Path $CFG.ProfileDir 'History'
    return [pscustomobject]@{
        Record     = Join-Path $CFG.ProfileDir 'Tooling.json'
        HistoryDir = $historyDir
        DailyDir   = Join-Path $historyDir 'Daily'
    }
}

function Read-ToolingRecord {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Save-ToolingRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Path
    )

    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $Record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-ToolingStamp {
    <#
      A date-time no existing tooling checkpoint uses. Two checkpoints in the
      same second would otherwise share a name, and -Revert would pick the
      wrong one.
    #>
    $existing = @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    while ($true) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        if (-not ($existing | Where-Object { $_ -eq "Tooling $stamp" -or $_ -like "Tooling $stamp *" })) { return $stamp }
        Start-Sleep -Seconds 1
    }
}

function Enable-ToolingCheckpoints {
    <#
      Tooling tracking needs checkpoints. A VM set up by hand can have them
      switched off entirely; this turns on production checkpoints (consistent,
      using the guest's Volume Shadow Copy, falling back to a standard
      checkpoint when that is unavailable). While the VM has no checkpoints, it
      also stores them in CheckpointDir, as a VM this script builds does:
      Hyper-V allows that change only then. Automatic checkpoints stay off.
    #>
    $vm = Get-VM -Name $CFG.VMName -ErrorAction Stop

    if ("$($vm.CheckpointType)" -eq 'Disabled') {
        Write-Log "Checkpoints are switched off for '$($CFG.VMName)' - turning on production checkpoints, which tooling tracking needs" 'INFO'
        Set-VM -Name $CFG.VMName -CheckpointType Production -ErrorAction Stop
    }

    # A checkpoint creates a differencing disk (.avhdx) beside each of the
    # VM's disks, as the VM's own account. Folders made outside Hyper-V's
    # defaults do not let it create files, which fails with "Access is
    # denied" (0x80070005). Microsoft's fix is to grant the VM's account on
    # the folder; here it is granted on each folder holding this VM's disks,
    # and on the folder only, not on the other VMs' files inside it.
    $account = "NT VIRTUAL MACHINE\$("$($vm.Id)".ToUpperInvariant())"
    $folders = @(Get-VMHardDiskDrive -VMName $CFG.VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } | ForEach-Object { Split-Path -Path $_.Path -Parent } | Sort-Object -Unique)
    foreach ($folder in $folders) {
        $granted = @((Get-Acl -LiteralPath $folder).Access | Where-Object { "$($_.IdentityReference)" -eq $account })
        if ($granted.Count -gt 0) { continue }
        $output = & icacls.exe $folder /grant "${account}:(F)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not grant the VM access to $folder for checkpoints: $output" }
        Write-Log "Gave '$($CFG.VMName)' access to $folder, so checkpoints can be created there" 'INFO'
    }

    $hasCheckpoints = @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasCheckpoints -and "$($vm.SnapshotFileLocation)".TrimEnd('\') -ne $CFG.CheckpointDir.TrimEnd('\')) {
        if (-not (Test-Path -LiteralPath $CFG.CheckpointDir)) { New-Item -ItemType Directory -Path $CFG.CheckpointDir -Force | Out-Null }
        Set-VM -Name $CFG.VMName -SnapshotFileLocation $CFG.CheckpointDir -ErrorAction Stop
        Write-Log "Checkpoints for '$($CFG.VMName)' are stored in $($CFG.CheckpointDir)" 'INFO'
    }
}

function New-ToolingCheckpoint {
    <#
      Takes the checkpoint paired with a tooling version, then removes the
      oldest tooling checkpoints beyond ToolingCheckpointsToKeep. Throws if the
      checkpoint cannot be taken, so the caller records nothing without one.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,

        # A revert's safety checkpoint must not prune: the oldest checkpoint
        # could be the very one being reverted to.
        [switch]$SkipPrune
    )

    Enable-ToolingCheckpoints
    Checkpoint-VM -Name $CFG.VMName -SnapshotName $Name -ErrorAction Stop
    Write-Log "Checkpoint taken: '$Name'" 'OK'
    if ($SkipPrune) { return }

    $tooling = @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Tooling *' } | Sort-Object CreationTime)
    $surplus = $tooling.Count - [int]$CFG.ToolingCheckpointsToKeep
    for ($index = 0; $index -lt $surplus; $index++) {
        $old = $tooling[$index]
        try {
            Remove-VMSnapshot -VMSnapshot $old -Confirm:$false -ErrorAction Stop
            Write-Log "  removed the older checkpoint '$($old.Name)'" 'INFO'
        }
        catch { Write-Log "  could not remove the checkpoint '$($old.Name)': $($_.Exception.Message)" 'WARN' }
    }
}

function Update-ToolingRecord {
    <#
      The daily tooling step, also run by -RecordTooling. Needs an open guest
      session. Returns the list of changes adopted (empty when none).
    #>
    Write-Log "Tooling Check - $($CFG.VMName)" 'PHASE'

    $paths = Get-ToolingPaths
    $current = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory)
    $previous = Read-ToolingRecord -Path $paths.Record
    Add-MarketplaceItems -Record $current -Previous $previous
    Merge-AwaitingReinstall -Record $current -Previous $previous

    # The day's copy, kept whether or not anything changed.
    $daily = Join-Path $paths.DailyDir ('Tooling-{0}.json' -f (Get-Date -Format 'yyyyMMdd'))
    Save-ToolingRecord -Record $current -Path $daily
    $cutoff = (Get-Date).AddDays(-[int]$CFG.ToolingHistoryDays)
    Get-ChildItem -LiteralPath $paths.DailyDir -Filter 'Tooling-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue

    if ($previous) {
        $changes = @(Compare-ToolingRecord -Old $previous -New $current)
        if ($changes.Count -eq 0) {
            Write-Log 'No tooling changes since the last recorded version' 'OK'
            return @()
        }
        Write-Log "$($changes.Count) tooling change(s) found:" 'INFO'
        foreach ($change in $changes) { Write-Log "  $change" 'INFO' }
    }
    else {
        $changes = @('first recording of this VM''s tooling')
        Write-Log 'No tooling list recorded yet - recording the first one' 'INFO'
    }

    $stamp = Get-ToolingStamp
    try {
        New-ToolingCheckpoint -Name "Tooling $stamp"
    }
    catch {
        Write-LogError 'Could not take the checkpoint, so the changes were NOT recorded; the next run tries again' $_
        return @()
    }

    Save-ToolingRecord -Record $current -Path (Join-Path $paths.HistoryDir "Tooling-$stamp.json")
    Save-ToolingRecord -Record $current -Path $paths.Record
    Write-Log "Tooling list recorded as version $stamp ($($paths.Record))" 'OK'
    return $changes
}

function Open-GuestSession {
    <# Starts the VM if needed and opens the guest session. Returns $true if it had to start it. #>
    param([Parameter(Mandatory)][string]$Purpose)

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Exit-WithError "VM '$($CFG.VMName)' does not exist." }

    $credential = Get-GuestCredential
    if (-not $credential) { Exit-WithError 'No stored guest credential. Run with -SetupCredentials first.' }

    $started = $false
    if ($vm.State -ne 'Running') {
        Write-Log "VM is '$($vm.State)' - starting it to $Purpose" 'INFO'
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 20 | Out-Null
        $started = $true
    }
    Connect-Guest -Credential $credential | Out-Null
    return $started
}

function Show-ToolingRestorePoints {
    <# -ListRestorePoints: the tooling versions that still have their checkpoint. #>
    Write-Log "Tooling Restore Points - $($CFG.VMName)" 'PHASE'

    $paths = Get-ToolingPaths
    $checkpoints = @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Tooling *' } | Sort-Object CreationTime)
    if ($checkpoints.Count -eq 0) {
        Write-Log 'No tooling checkpoints yet. One is taken whenever a tooling change is recorded.' 'INFO'
        return
    }

    foreach ($checkpoint in $checkpoints) {
        $stamp = ($checkpoint.Name -replace '^Tooling\s+', '') -replace '\s.*$', ''
        $file = Join-Path $paths.HistoryDir "Tooling-$stamp.json"
        $note = if (Test-Path -LiteralPath $file) { '' } else { '  (no matching tooling list - the VM can be reverted, the list cannot)' }
        Write-Log ("  {0}   taken {1}{2}" -f $checkpoint.Name, $checkpoint.CreationTime.ToString('yyyy-MM-dd HH:mm'), $note) 'INFO'
    }
    Write-Log 'To go back to one: .\Build-LazyVM.ps1 -Revert <stamp>, for example -Revert 20261008-193000' 'INFO'
}

function Invoke-ToolingRevert {
    <#
      -Revert <stamp>: returns the VM to a recorded tooling version by applying
      its checkpoint and restoring the matching tooling list. A checkpoint of
      the current state is taken first, so the revert itself can be undone.
    #>
    param(
        [Parameter(Mandatory)][string]$Stamp,
        [switch]$Confirmed
    )

    Write-Log "Revert - $($CFG.VMName) to tooling version $Stamp" 'PHASE'

    $paths = Get-ToolingPaths
    $checkpoint = Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Tooling $Stamp" -or $_.Name -eq "Tooling $Stamp before revert" } | Select-Object -First 1
    if (-not $checkpoint) { Exit-WithError "There is no checkpoint 'Tooling $Stamp'. See -ListRestorePoints." }
    $listFile = Join-Path $paths.HistoryDir "Tooling-$Stamp.json"
    if (-not (Test-Path -LiteralPath $listFile)) { Exit-WithError "The tooling list for $Stamp is missing: $listFile" }

    if (-not $Confirmed) {
        Write-Host ''
        Write-Host "  This returns '$($CFG.VMName)' to how it was at $($checkpoint.CreationTime.ToString('yyyy-MM-dd HH:mm'))." -ForegroundColor Yellow
        Write-Host '  ALL of its disks go back to that point, including the Dev Drive and the SQL' -ForegroundColor Yellow
        Write-Host '  data disk: unpushed code and later database changes are lost.' -ForegroundColor Yellow
        Write-Host '  A checkpoint of the current state is taken first, so this can be undone.' -ForegroundColor Yellow
        Write-Host ''
        $answer = Read-Host 'Continue? (y/N)'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Log 'Revert cancelled' 'INFO'
            return
        }
    }

    # The current state, as an ordinary tooling version, so the revert can be reverted.
    $now = Get-ToolingStamp
    New-ToolingCheckpoint -Name "Tooling $now before revert" -SkipPrune
    if (Test-Path -LiteralPath $paths.Record) {
        Copy-Item -LiteralPath $paths.Record -Destination (Join-Path $paths.HistoryDir "Tooling-$now.json") -Force
    }

    $wasRunning = ((Get-VM -Name $CFG.VMName).State -eq 'Running')
    Disconnect-Guest
    Restore-VMSnapshot -VMSnapshot $checkpoint -Confirm:$false -ErrorAction Stop
    Copy-Item -LiteralPath $listFile -Destination $paths.Record -Force
    Write-Log "VM returned to '$($checkpoint.Name)' and its tooling list restored" 'OK'
    Write-Log "  To undo this revert: .\Build-LazyVM.ps1 -Revert $now" 'INFO'

    if ($wasRunning -and (Get-VM -Name $CFG.VMName).State -ne 'Running') {
        Start-VM -Name $CFG.VMName | Out-Null
        Write-Log 'VM started' 'INFO'
    }
}
