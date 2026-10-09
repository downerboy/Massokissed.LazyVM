# Configuration.ps1 - part of Massokissed.LazyVM.Configuration. Loads and validates the settings files, and creates VM profiles.
# Dot-sourced by Massokissed.LazyVM.Configuration.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION
#
#  Settings come from two data-only files in the Config folder:
#    LazyVM.Defaults.psd1  every setting and its default; replaced on update
#    LazyVM.Config.psd1    optional; the user's own values, never shipped
#    VMs\<Name>\VM.psd1    one per VM; that VM's own settings, applied last
#  The user file may list any subset of settings. Each one replaces the default
#  of the same name, after checking the name exists and the value is the same
#  kind as the default. Every problem is reported together, so one run is
#  enough to see them all.
#
#  ROOT FOLDER
#  Host paths are written relative to one root folder, chosen in this order:
#    1. the -Root parameter
#    2. Root in LazyVM.Config.psd1
#    3. the folder above the one holding Build-LazyVM.ps1, so a kit unpacked
#       to D:\DevVM (script in D:\DevVM\Scripts) uses D:\DevVM with no setup
#  A host path given as a full path (D:\ISOs\win11.iso) is used as written,
#  which is how a single large item can live on another drive.
# ─────────────────────────────────────────────────────────────────────────────

# Settings that name a file or folder on the HOST, and so are resolved against
# the root folder. Paths inside the guest (GuestSetupDir, GuestSqlDataDir,
# GuestProjectPaths, ...) are deliberately absent: they are not host paths.
$script:HostPathSettings = @(
    'VHDXRoot'
    'ISOPath'
    'ISOSearchRoot'
    'SQLInstallerPath'
    'SQLDiskPath'
    'DevDrivePath'
    'SeedDiskPath'
    'CheckpointDir'
    'VSSettingsBackup'
    'LogFile'
    'CredStoreDir'
    'CredKeyFile'
    'GuestCredFile'
    'CertCredFile'
    'StateDir'
)

function Get-SettingKind {
    <# Plain-language kind of a settings value, for comparison and messages. #>
    param($Value)

    if ($null -eq $Value) { return 'empty' }
    if ($Value -is [bool]) { return 'true or false' }
    if ($Value -is [string]) { return 'text' }
    if ($Value -is [System.Collections.IDictionary]) { return 'a table' }
    if ($Value -is [System.Collections.IList]) { return 'a list' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return 'a number' }
    return $Value.GetType().Name
}

function Test-FullHostPath {
    <# True for D:\folder or \\server\share; false for anything relative. #>
    param([string]$Path)

    return ($Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]')
}

function Merge-UserSettings {
    <#
      Applies the user's settings file on top of the defaults. Updates
      $Settings in place and returns the names of the settings it changed.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$UserPath
    )

    try {
        $userSettings = Import-PowerShellDataFile -LiteralPath $UserPath
    }
    catch {
        throw "Your settings file could not be read: $UserPath`n  $($_.Exception.Message)`n  It may contain only text, numbers, `$true/`$false, lists @() and tables @{}."
    }

    $problems = [System.Collections.Generic.List[string]]::new()

    # Checked values are held here and applied only once every setting has
    # passed, so a file with any problem leaves $Settings untouched.
    $accepted = @{}

    foreach ($userKey in $userSettings.Keys) {
        # Match names case-insensitively, but keep the spelling the script uses.
        $name = $Settings.Keys | Where-Object { $_ -eq $userKey } | Select-Object -First 1
        if (-not $name) {
            $problems.Add("'$userKey' is not a setting. Check the spelling against LazyVM.Defaults.psd1.")
            continue
        }

        $value = $userSettings[$userKey]
        $expectedKind = Get-SettingKind $Settings[$name]
        $actualKind = Get-SettingKind $value

        # A single item where a list belongs is accepted as a one-item list.
        if ($expectedKind -eq 'a list' -and $actualKind -ne 'a list' -and $actualKind -ne 'empty') {
            $value = @($value)
            $actualKind = 'a list'
        }

        if ($actualKind -ne $expectedKind) {
            $problems.Add("'$name' should be $expectedKind, but is $actualKind.")
            continue
        }

        # Items in a list must be the same kind as the default's items, so a
        # tool list cannot end up holding plain text where tables belong.
        if ($expectedKind -eq 'a list' -and @($Settings[$name]).Count -gt 0) {
            $itemKind = Get-SettingKind @($Settings[$name])[0]
            $wrongItems = @($value | Where-Object { (Get-SettingKind $_) -ne $itemKind })
            if ($wrongItems.Count -gt 0) {
                $itemLabel = switch ($itemKind) {
                    'a table' { 'tables' }
                    'a number' { 'numbers' }
                    'a list' { 'lists' }
                    'true or false' { 'true/false values' }
                    default { $itemKind }
                }
                $problems.Add("'$name' should be a list of $itemLabel, but $($wrongItems.Count) item(s) are not.")
                continue
            }
        }

        $accepted[$name] = $value
    }

    if ($problems.Count -gt 0) {
        $list = ($problems | Sort-Object | ForEach-Object { "  - $_" }) -join "`n"
        throw "Your settings file has $($problems.Count) problem(s); nothing has been changed:`n  $UserPath`n$list"
    }

    foreach ($name in $accepted.Keys) {
        $Settings[$name] = $accepted[$name]
    }
    return @($accepted.Keys | Sort-Object)
}

function Resolve-SettingsRoot {
    <# Picks the root folder by the precedence above and checks it is usable. #>
    param(
        [string]$RootOverride,
        [string]$ConfiguredRoot,
        [string]$ConfiguredIn,
        [Parameter(Mandatory)][string]$ScriptDir
    )

    if ($RootOverride) {
        $root = $RootOverride
        $source = 'the -Root parameter'
    }
    elseif ($ConfiguredRoot) {
        $root = $ConfiguredRoot
        $source = "Root in $ConfiguredIn"
    }
    else {
        # Text-based rather than Split-Path, so the rule is exactly "drop the
        # last folder" whatever the current location or provider.
        $scriptFolder = $ScriptDir.TrimEnd('\')
        $cut = $scriptFolder.LastIndexOf('\')
        $root = if ($cut -gt 0) { $scriptFolder.Substring(0, $cut) } else { '' }
        $source = "the folder above $scriptFolder"

        if ($root -notmatch '^[A-Za-z]:\\[^\\]') {
            throw ("Could not work out the root folder from where the script is ($scriptFolder).`n" +
                "  Keep Build-LazyVM.ps1 in a Scripts folder under the root (for example D:\DevVM\Scripts),`n" +
                "  set Root in Config\LazyVM.Config.psd1, or pass -Root D:\DevVM.")
        }
    }

    $root = $root.Trim().TrimEnd('\')

    # A folder on a local drive, not the top of a drive: Hyper-V disks belong
    # on local storage, and a bare drive root would scatter folders across it.
    # Double quotes are refused because the path is quoted into the
    # scheduled-task command lines.
    if ($root -notmatch '^[A-Za-z]:\\[^\\]' -or $root.Contains('"')) {
        throw "The root folder must be a folder on a local drive, such as D:\DevVM. Got '$root' from $source."
    }

    return [pscustomobject]@{
        Path   = $root
        Source = $source
    }
}

function Resolve-HostPathSettings {
    <# Joins every relative host path to the root. Updates $Settings in place. #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Root
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $script:HostPathSettings) {
        $value = [string]$Settings[$name]

        if (Test-FullHostPath $value) {
            continue
        }
        if (-not $value -or $value -match '^[A-Za-z]:' -or $value.StartsWith('\')) {
            $problems.Add("'$name' must be a path inside the root folder (like 'VMs') or a full path (like 'E:\VMs'), not '$value'.")
            continue
        }

        $relative = $value -replace '^\.\\', ''
        $Settings[$name] = "$Root\$relative"
    }

    if ($problems.Count -gt 0) {
        $list = ($problems | Sort-Object | ForEach-Object { "  - $_" }) -join "`n"
        throw "$($problems.Count) path setting(s) cannot be used:`n$list"
    }
}

function Test-VMName {
    <#
      VM names become file names, task names and, by default, the guest's
      computer name, which Windows limits to 15 characters.
    #>
    param([string]$Name)

    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')
}

function Get-VMProfileNames {
    <# The VMs this host knows about: one folder per VM under Config\VMs. #>
    param([Parameter(Mandatory)][string]$ConfigDir)

    $profilesDir = Join-Path -Path $ConfigDir -ChildPath 'VMs'
    $folders = @(Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'VM.psd1') -PathType Leaf })
    return @($folders | ForEach-Object { $_.Name } | Sort-Object)
}

function Resolve-VMSelection {
    <#
      Which VM this run is for: the one named by -VM, or the only one there is.
      Several VMs and no -VM is an error rather than a guess, because the
      wrong guess would maintain or rebuild the wrong machine.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$Requested
    )

    $names = @(Get-VMProfileNames -ConfigDir $ConfigDir)

    if ($Requested) {
        $match = $names | Where-Object { $_ -eq $Requested } | Select-Object -First 1
        if (-not $match) {
            $known = if ($names.Count -gt 0) { $names -join ', ' } else { 'none yet' }
            throw "There is no VM profile named '$Requested' (VMs on this host: $known). Create one with -NewVM $Requested."
        }
        return $match
    }

    if ($names.Count -eq 1) {
        return $names[0]
    }
    if ($names.Count -eq 0) {
        throw "No VM profiles exist yet. Create the first one with: .\Build-LazyVM.ps1 -NewVM <Name>"
    }
    throw "This host has several VMs ($($names -join ', ')). Say which one with -VM <Name>."
}

function Expand-VMTokens {
    <# Replaces {VM} in every text setting with the VM's name. Updates $Settings in place. #>
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$VMName
    )

    foreach ($name in @($Settings.Keys)) {
        $value = $Settings[$name]
        if ($value -is [string] -and $value.Contains('{VM}')) {
            $Settings[$name] = $value.Replace('{VM}', $VMName)
        }
    }
}

function ConvertTo-SettingsText {
    <#
      Writes a value in PowerShell data-file syntax, for the profile files the
      script creates. Covers the kinds of value a settings file may hold.
    #>
    param(
        $Value,
        [int]$Indent = 0
    )

    $pad = ' ' * $Indent
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $lines = @('@{')
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $lines += "$pad    $key = $(ConvertTo-SettingsText -Value $Value[$key] -Indent ($Indent + 4))"
        }
        $lines += "$pad}"
        return ($lines -join "`r`n")
    }
    if ($Value -is [System.Collections.IList]) {
        $lines = @('@(')
        foreach ($item in $Value) {
            $lines += "$pad    $(ConvertTo-SettingsText -Value $item -Indent ($Indent + 4))"
        }
        $lines += "$pad)"
        return ($lines -join "`r`n")
    }
    throw "A value of type $($Value.GetType().Name) cannot be written to a settings file."
}

function New-VMProfile {
    <#
      -NewVM: creates Config\VMs\<Name>\VM.psd1. With -From, the new VM takes
      the source VM's settings, except the ones that must differ between VMs:
      file locations, task and registry names, the guest computer name and the
      maintenance time. Those come from the defaults, which name everything
      after the VM. The maintenance time is set an hour after the latest
      existing VM's, so two VMs are never maintained at once.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$From
    )

    if (-not (Test-VMName $Name)) {
        throw "'$Name' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit."
    }

    $existing = @(Get-VMProfileNames -ConfigDir $ConfigDir)
    if ($existing | Where-Object { $_ -eq $Name }) {
        throw "A VM profile named '$Name' already exists."
    }

    $defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $ConfigDir -ChildPath 'LazyVM.Defaults.psd1')
    $perVM = @($script:HostPathSettings) + @('GuestComputerName', 'ResumeRegKey', 'ResumeTaskName', 'ScheduleTaskName', 'MaintenanceTime')

    $settings = @{}
    if ($From) {
        $source = $existing | Where-Object { $_ -eq $From } | Select-Object -First 1
        if (-not $source) { throw "There is no VM profile named '$From' to copy." }
        $sourceSettings = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $ConfigDir -ChildPath "VMs\$source\VM.psd1")
        foreach ($key in $sourceSettings.Keys) {
            if ($perVM -notcontains $key) { $settings[$key] = $sourceSettings[$key] }
        }
    }

    # An hour after the latest maintenance time in use, wrapping at midnight.
    $latest = $null
    foreach ($vmName in $existing) {
        $vmSettings = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $ConfigDir -ChildPath "VMs\$vmName\VM.psd1")
        $time = if ($vmSettings.ContainsKey('MaintenanceTime')) { $vmSettings['MaintenanceTime'] } else { $defaults['MaintenanceTime'] }
        $parsed = [datetime]::ParseExact($time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        if (-not $latest -or $parsed.TimeOfDay -gt $latest.TimeOfDay) { $latest = $parsed }
    }
    if ($latest) {
        $settings['MaintenanceTime'] = $latest.AddHours(1).ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }

    $origin = if ($From) { "created from $From" } else { 'created from the defaults' }
    $lines = @(
        "# VM profile for $Name, $origin on $(Get-Date -Format 'yyyy-MM-dd')."
        '# Settings here apply to this VM only and override LazyVM.Defaults.psd1 and'
        '# LazyVM.Config.psd1. Any setting from LazyVM.Defaults.psd1 may be added.'
        '@{'
    )
    foreach ($key in @($settings.Keys | Sort-Object)) {
        $lines += "    $key = $(ConvertTo-SettingsText -Value $settings[$key] -Indent 4)"
    }
    $lines += '}'

    $folder = Join-Path -Path $ConfigDir -ChildPath "VMs\$Name"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $path = Join-Path -Path $folder -ChildPath 'VM.psd1'
    [IO.File]::WriteAllText($path, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))

    # The source VM's tooling list is what the new VM is built with. Its
    # history and checkpoints belong to the source VM and stay there.
    if ($From) {
        $sourceTooling = Join-Path -Path $ConfigDir -ChildPath "VMs\$From\Tooling.json"
        if (Test-Path -LiteralPath $sourceTooling -PathType Leaf) {
            Copy-Item -LiteralPath $sourceTooling -Destination (Join-Path -Path $folder -ChildPath 'Tooling.json')
        }
    }
    return $path
}

function Import-LazyVMConfiguration {
    <#
      Loads the settings for one VM, in layers: the defaults, then the user's
      host-wide file, then the VM's own profile. Then names everything after
      the VM, picks the root folder and resolves every host path against it.
      Returns the settings together with what the startup log reports.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ScriptDir,
        [string]$RootOverride,
        [string]$VMName
    )

    $defaultsPath = Join-Path -Path $ConfigDir -ChildPath 'LazyVM.Defaults.psd1'
    $userPath = Join-Path -Path $ConfigDir -ChildPath 'LazyVM.Config.psd1'

    if (-not (Test-Path -LiteralPath $defaultsPath -PathType Leaf)) {
        throw "Missing settings file: $defaultsPath. Copy the whole Config folder alongside Build-LazyVM.ps1."
    }
    $settings = Import-PowerShellDataFile -LiteralPath $defaultsPath

    $userFile = $null
    $changedKeys = @()
    if (Test-Path -LiteralPath $userPath -PathType Leaf) {
        $changedKeys = @(Merge-UserSettings -Settings $settings -UserPath $userPath)
        $userFile = $userPath
    }

    $vm = Resolve-VMSelection -ConfigDir $ConfigDir -Requested $VMName
    $profilePath = Join-Path -Path $ConfigDir -ChildPath "VMs\$vm\VM.psd1"
    $profileKeys = @(Merge-UserSettings -Settings $settings -UserPath $profilePath)

    $settings.VMName = $vm
    # Set by the script, not a user setting: where this VM's profile and
    # tooling list live.
    $settings.ProfileDir = Split-Path -Path $profilePath -Parent
    Expand-VMTokens -Settings $settings -VMName $vm

    $configuredIn = if ($profileKeys -contains 'Root') { $profilePath } elseif ($userFile) { $userFile } else { $defaultsPath }
    $root = Resolve-SettingsRoot -RootOverride $RootOverride -ConfiguredRoot $settings.Root `
        -ConfiguredIn $configuredIn -ScriptDir $ScriptDir

    $settings.Root = $root.Path
    Resolve-HostPathSettings -Settings $settings -Root $root.Path

    # Filled in place rather than replaced: every module holds a reference to
    # this one table (see Get-LazyVMSettings).
    $script:Settings.Clear()
    foreach ($key in @($settings.Keys)) { $script:Settings[$key] = $settings[$key] }

    return [pscustomobject]@{
        Settings    = $script:Settings
        UserFile    = $userFile
        ChangedKeys = $changedKeys
        VMName      = $vm
        ProfilePath = $profilePath
        ProfileKeys = $profileKeys
        Root        = $root.Path
        RootSource  = $root.Source
    }
}

function Get-LazyVMSettings {
    <#
      The settings for this run: one table shared by every module. Each module
      takes a reference to it when it loads, as $CFG, and
      Import-LazyVMConfiguration fills it in place.
    #>
    return $script:Settings
}
