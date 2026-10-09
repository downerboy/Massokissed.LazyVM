# Capture.ps1 - part of Massokissed.LazyVM.Capture. Phase 9: capture guest state to the host.
# Dot-sourced by Massokissed.LazyVM.Capture.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 9 — CAPTURE
#
#  Snapshots everything that has to survive a rebuild into StateDir on
#  the HOST, which no rebuild touches.
#
#  Files come out of the guest with Copy-Item -FromSession over PowerShell
#  Direct. Copy-VMFile is host-to-guest only, so it cannot be used here.
#  Directory trees are zipped inside the guest first and pulled out as a single
#  file, which is far faster than copying thousands of small files one by one.
#
#  SQL database backups deliberately stay on the SQL data disk rather than
#  being copied to the host: that VHDX is never destroyed by a rebuild, and
#  pulling tens of GB across the VMBus would be pointless.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase9-Capture {
    Write-Log 'PHASE 9 - Capture Guest State' 'PHASE'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Exit-WithError "VM '$($CFG.VMName)' does not exist - nothing to capture." }

    $credential = Get-GuestCredential
    if (-not $credential) { Exit-WithError 'No stored guest credential. Run with -SetupCredentials first.' }

    if ($vm.State -ne 'Running') {
        Write-Log "VM is '$($vm.State)' - starting it to capture" 'INFO'
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 30 | Out-Null
    }
    Connect-Guest -Credential $credential | Out-Null

    # Resolve the data disk letter so SQL backups land in the right place.
    try { Initialize-GuestSqlDisk }
    catch { Write-Log "Could not prepare the data disk: $($_.Exception.Message)" 'WARN' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stateDir = $CFG.StateDir
    foreach ($sub in '', 'vs', 'windows', 'sql', 'projects', 'apps') {
        $path = if ($sub) { Join-Path $stateDir $sub } else { $stateDir }
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }

    $manifest = [ordered]@{
        Version      = 2
        CapturedAt   = (Get-Date).ToString('o')
        CapturedFrom = $CFG.VMName
        Stamp        = $stamp
        Guest        = $null
        VisualStudio = $null
        Sql          = $null
        Windows      = $null
        Projects     = $null
        AppSettings  = $null
        Warnings     = @()
    }

    $steps = @(
        [pscustomobject]@{ Key = 'Guest'; Name = 'guest identity'; Action = { Get-GuestIdentity } }
        [pscustomobject]@{ Key = 'VisualStudio'; Name = 'Visual Studio'; Action = { Save-GuestVisualStudioState } }
        [pscustomobject]@{ Key = 'Sql'; Name = 'SQL Server'; Action = { Save-GuestSqlState } }
        [pscustomobject]@{ Key = 'Windows'; Name = 'Windows environment'; Action = { Save-GuestWindowsState } }
        [pscustomobject]@{ Key = 'Projects'; Name = 'project files'; Action = { Save-GuestProjectFiles } }
        [pscustomobject]@{ Key = 'AppSettings'; Name = 'application settings'; Action = { Save-GuestAppSettings } }
    )

    foreach ($step in $steps) {
        try {
            Write-Log "Capturing $($step.Name)..." 'INFO'
            $manifest[$step.Key] = & $step.Action
        }
        catch {
            Write-LogError "Capture of $($step.Name) failed" $_
            $manifest.Warnings += "capture of $($step.Name) failed: $($_.Exception.Message)"
        }
    }

    $dbCount = 0
    if ($manifest.Sql -and $manifest.Sql.Databases) { $dbCount = @($manifest.Sql.Databases).Count }
    $manifest['Summary'] = "$dbCount database(s) backed up"
    # Wrapped in @() rather than assigned from an if/else: an if statement used as
    # a value unrolls its output, which saved an empty list as null and a single
    # database as a bare string instead of a one-item list.
    $manifest['Databases'] = @(
        if ($manifest.Sql -and $manifest.Sql.Databases) { $manifest.Sql.Databases | ForEach-Object { $_.Name } }
    )

    $manifestPath = Join-Path $stateDir 'manifest.json'
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stateDir "manifest-$stamp.json") -Force

    if ($manifest.Warnings.Count -gt 0) {
        Write-Log "Capture finished with $($manifest.Warnings.Count) warning(s):" 'WARN'
        foreach ($w in $manifest.Warnings) { Write-Log "  $w" 'WARN' }
    }
    Write-Log "Capture written to $manifestPath" 'OK'
    return $manifest
}

function Get-CaptureManifest {
    $path = Join-Path $CFG.StateDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch {
        Write-Log "Capture manifest at $path is unreadable: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-GuestIdentity {
    return Invoke-GuestScript -Activity 'guest identity' -TimeoutMinutes 5 -ScriptBlock {
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            UserName     = $env:USERNAME
            OsCaption    = $os.Caption
            OsBuild      = $os.BuildNumber
            InstallDate  = $os.InstallDate.ToString('o')
            TimeZone     = (Get-TimeZone).Id
        }
    }
}

# ── Visual Studio ────────────────────────────────────────────────────────────
function Save-GuestVisualStudioState {
    $vs = Get-GuestVisualStudio
    if (-not $vs) {
        Write-Log '  Visual Studio is not installed - skipping' 'INFO'
        return $null
    }

    $vsDir = Join-Path $CFG.StateDir 'vs'

    $info = Invoke-GuestScript -Activity 'Visual Studio capture' -TimeoutMinutes 20 -ArgumentList @(
        $vs.InstallPath, $CFG.GuestSetupDir, $vs.InstanceId, "$($vs.ProductLine)"
    ) -ScriptBlock {
        param($installPath, $setupDir, $instanceId, $productLine)
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

        $out = [ordered]@{
            DisplayName = ''
            Version     = ''
            VsConfig    = $null
            Settings    = $null
            NuGetConfig = $null
            GitConfig   = $null
            UserItems   = $null
            Notes       = @()
        }

        # -- installed workloads and components, as a .vsconfig --------------
        # This is the supported way to reproduce an installation: the new
        # install consumes it with --config and gets the same workloads.
        $configPath = Join-Path $setupDir 'vs.vsconfig'
        $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vs_installer.exe'
        if (Test-Path $installer) {
            $proc = Start-Process -FilePath $installer -Wait -PassThru -NoNewWindow -ArgumentList @(
                'export', '--installPath', "`"$installPath`"", '--config', "`"$configPath`"", '--quiet'
            )
            if ((Test-Path $configPath) -and (Get-Item $configPath).Length -gt 0) { $out.VsConfig = $configPath }
            else { $out.Notes += "vs_installer export produced nothing (exit $($proc.ExitCode)); workloads will fall back to the configured defaults" }
        }
        else { $out.Notes += 'vs_installer.exe not found; workloads cannot be exported' }

        # -- settings --------------------------------------------------------
        # Visual Studio writes a .vssettings backup every time it closes, so
        # the newest one in the Settings folder is the live configuration.
        # That is far more reliable than automating the export wizard. The
        # folder is named <version>_<instance id>, which ties it to this
        # Visual Studio rather than to any other version installed.
        $settingsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio'
        $candidates = @(Get-ChildItem -Path $settingsRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*_$instanceId" } |
                ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'Settings') -Filter '*.vssettings' -File -ErrorAction SilentlyContinue } |
                Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -gt 0) {
            $out.Settings = $candidates[0].FullName
        }
        else {
            $out.Notes += 'no .vssettings backup found (open and close Visual Studio once to create one)'
        }

        # Extensions are recorded in the tooling list, and reinstalled from it.

        # -- developer config files -----------------------------------------
        $nuget = Join-Path $env:APPDATA 'NuGet\NuGet.Config'
        if (Test-Path $nuget) { $out.NuGetConfig = $nuget }
        $gitconfig = Join-Path $env:USERPROFILE '.gitconfig'
        if (Test-Path $gitconfig) { $out.GitConfig = $gitconfig }

        # -- snippets, templates, and other user items ----------------------
        $userItems = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Visual Studio $productLine"
        $zip = Join-Path $setupDir 'vs-useritems.zip'
        if (Test-Path $userItems) {
            $keep = @('Code Snippets', 'Templates', 'Settings')
            $staging = Join-Path $setupDir 'vs-useritems'
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            foreach ($name in $keep) {
                $src = Join-Path $userItems $name
                if (Test-Path $src) { Copy-Item -Path $src -Destination $staging -Recurse -Force -ErrorAction SilentlyContinue }
            }
            if (@(Get-ChildItem $staging -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) {
                Remove-Item $zip -Force -ErrorAction SilentlyContinue
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
                $out.UserItems = $zip
            }
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject]$out
    }

    # Pull the produced files out of the guest.
    $captured = [ordered]@{
        DisplayName = $vs.DisplayName
        Version     = $vs.Version
        ProductLine = "$($vs.ProductLine)"
        Notes       = @($info.Notes)
        Files       = [ordered]@{}
    }

    $pulls = @(
        [pscustomobject]@{ Guest = $info.VsConfig; Name = 'vs.vsconfig'; Key = 'VsConfig' }
        [pscustomobject]@{ Guest = $info.Settings; Name = 'VisualStudio.vssettings'; Key = 'Settings' }
        [pscustomobject]@{ Guest = $info.NuGetConfig; Name = 'NuGet.Config'; Key = 'NuGetConfig' }
        [pscustomobject]@{ Guest = $info.GitConfig; Name = 'gitconfig'; Key = 'GitConfig' }
        [pscustomobject]@{ Guest = $info.UserItems; Name = 'vs-useritems.zip'; Key = 'UserItems' }
    )
    foreach ($pull in $pulls) {
        if (-not $pull.Guest) { continue }
        $dest = Join-Path $vsDir $pull.Name
        try {
            Copy-FromGuest -GuestPath $pull.Guest -HostPath $dest
            $captured.Files[$pull.Key] = $dest
            Write-Log "  $($pull.Name)" 'OK'
        }
        catch {
            Write-Log "  could not retrieve $($pull.Name): $($_.Exception.Message)" 'WARN'
        }
    }

    # The settings backup is also what Phase 8d restores, so keep it where
    # that step already looks.
    if ($captured.Files.Contains('Settings')) {
        Copy-Item -LiteralPath $captured.Files['Settings'] -Destination $CFG.VSSettingsBackup -Force -ErrorAction SilentlyContinue
    }

    Write-Log "  Visual Studio: $($vs.DisplayName)" 'OK'
    foreach ($note in @($info.Notes)) { Write-Log "  $note" 'WARN' }
    return [pscustomobject]$captured
}

# ── SQL Server ───────────────────────────────────────────────────────────────
function Save-GuestSqlState {
    $instance = Get-GuestSqlInstance
    if (-not $instance) {
        Write-Log '  SQL Server is not installed - skipping' 'INFO'
        return $null
    }
    Set-GuestSqlServer -Instance $instance.Instance

    $result = Invoke-GuestScript -Activity 'SQL capture' -TimeoutMinutes 180 -ArgumentList @(
        (Get-GuestSqlServer), $CFG.GuestSqlBackupDir
    ) -ScriptBlock {
        param($server, $backupDir)
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

        $cs = "Server=$server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
        $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
        $conn.Open()

        function Get-Rows($c, $sql) {
            $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
            $r = $cmd.ExecuteReader(); $rows = @()
            try {
                while ($r.Read()) {
                    $h = @{}
                    for ($i = 0; $i -lt $r.FieldCount; $i++) { $h[$r.GetName($i)] = $r.GetValue($i) }
                    $rows += [pscustomobject]$h
                }
            }
            finally { $r.Close() }
            return $rows
        }
        function Invoke-Sql($c, $sql, $timeout = 3600) {
            $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = $timeout
            return $cmd.ExecuteNonQuery()
        }

        $out = [ordered]@{
            Instance     = ''
            Version      = ''
            Edition      = ''
            BackupDir    = $backupDir
            Databases    = @()
            Logins       = @()
            Configs      = @()
            NotMigrated  = @()
            Notes        = @()
        }

        $ver = Get-Rows $conn "SELECT SERVERPROPERTY('ProductVersion') AS V, SERVERPROPERTY('Edition') AS E, @@SERVICENAME AS S"
        $out.Version = "$($ver[0].V)"; $out.Edition = "$($ver[0].E)"; $out.Instance = "$($ver[0].S)"

        # -- user databases --------------------------------------------------
        $dbs = @(Get-Rows $conn @'
SELECT name, recovery_model_desc AS Recovery, compatibility_level AS CompatLevel, collation_name AS Collation
FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' AND is_read_only = 0
'@)

        foreach ($db in $dbs) {
            $name = "$($db.name)"
            $quoted = '[' + $name.Replace(']', ']]') + ']'
            $file = Join-Path $backupDir "$name.bak"
            $fileEsc = $file.Replace("'", "''")

            # COMPRESSION is unavailable on some editions; retry without it.
            try {
                Invoke-Sql $conn "BACKUP DATABASE $quoted TO DISK = N'$fileEsc' WITH INIT, FORMAT, CHECKSUM, COMPRESSION, STATS = 10" | Out-Null
            }
            catch {
                Invoke-Sql $conn "BACKUP DATABASE $quoted TO DISK = N'$fileEsc' WITH INIT, FORMAT, CHECKSUM, STATS = 10" | Out-Null
            }

            # Prove the backup is readable before it is ever relied upon.
            Invoke-Sql $conn "RESTORE VERIFYONLY FROM DISK = N'$fileEsc' WITH CHECKSUM" | Out-Null

            $out.Databases += [pscustomobject]@{
                Name        = $name
                BackupFile  = $file
                SizeBytes   = (Get-Item $file).Length
                Recovery    = "$($db.Recovery)"
                CompatLevel = [int]$db.CompatLevel
                Collation   = "$($db.Collation)"
            }
        }

        # -- logins ----------------------------------------------------------
        # SID and password hash are preserved so database users do not become
        # orphaned when the databases are restored into a new instance.
        $logins = @(Get-Rows $conn @'
SELECT sp.name, sp.type_desc AS TypeDesc, sp.is_disabled AS IsDisabled,
       sp.default_database_name AS DefaultDb, sp.default_language_name AS DefaultLang,
       CONVERT(varchar(max), sp.sid, 1) AS SidHex,
       CONVERT(varchar(max), sl.password_hash, 1) AS HashHex,
       sl.is_policy_checked AS PolicyChecked, sl.is_expiration_checked AS ExpirationChecked
FROM sys.server_principals sp
LEFT JOIN sys.sql_logins sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S','U','G') AND sp.name NOT LIKE '##%' AND sp.name NOT LIKE 'NT %'
  AND sp.name <> 'sa' AND sp.name NOT LIKE 'BUILTIN\%'
'@)
        foreach ($l in $logins) {
            $roles = @(Get-Rows $conn ("SELECT r.name FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id = m.role_principal_id JOIN sys.server_principals p ON p.principal_id = m.member_principal_id WHERE p.name = N'" + "$($l.name)".Replace("'", "''") + "'") | ForEach-Object { "$($_.name)" })
            $out.Logins += [pscustomobject]@{
                Name              = "$($l.name)"
                TypeDesc          = "$($l.TypeDesc)"
                IsDisabled        = [bool]$l.IsDisabled
                DefaultDb         = "$($l.DefaultDb)"
                DefaultLang       = "$($l.DefaultLang)"
                SidHex            = "$($l.SidHex)"
                HashHex           = "$($l.HashHex)"
                PolicyChecked     = [bool]$l.PolicyChecked
                ExpirationChecked = [bool]$l.ExpirationChecked
                ServerRoles       = $roles
            }
        }

        # -- instance settings ----------------------------------------------
        $out.Configs = @(Get-Rows $conn "SELECT name, value_in_use FROM sys.configurations WHERE value <> value_in_use OR value_in_use <> 0" |
                ForEach-Object { [pscustomobject]@{ Name = "$($_.name)"; Value = "$($_.value_in_use)" } })

        # -- things this script knowingly does NOT migrate -------------------
        $jobs = @(Get-Rows $conn "SELECT name FROM msdb.dbo.sysjobs" | ForEach-Object { "$($_.name)" })
        if ($jobs.Count -gt 0) { $out.NotMigrated += "SQL Agent jobs: $($jobs -join ', ')" }
        $linked = @(Get-Rows $conn "SELECT name FROM sys.servers WHERE server_id <> 0" | ForEach-Object { "$($_.name)" })
        if ($linked.Count -gt 0) { $out.NotMigrated += "linked servers: $($linked -join ', ')" }
        $creds = @(Get-Rows $conn "SELECT name FROM sys.credentials" | ForEach-Object { "$($_.name)" })
        if ($creds.Count -gt 0) { $out.NotMigrated += "credentials: $($creds -join ', ')" }

        $conn.Close()
        return [pscustomobject]$out
    }

    $total = 0
    foreach ($db in @($result.Databases)) { $total += $db.SizeBytes }
    Write-Log "  SQL $($result.Version) ($($result.Edition)): $(@($result.Databases).Count) database(s), $(Format-Size $total) of backups, $(@($result.Logins).Count) login(s)" 'OK'
    Write-Log "  Backups stay on the data disk ($($result.BackupDir)), which survives the rebuild" 'INFO'
    foreach ($item in @($result.NotMigrated)) {
        Write-Log "  NOT migrated automatically - $item" 'WARN'
    }
    return $result
}

# ── Windows environment ──────────────────────────────────────────────────────
function Save-GuestWindowsState {
    $windowsDir = Join-Path $CFG.StateDir 'windows'

    # A password for the certificate PFXs, kept in the existing credential store.
    $certCred = Get-StoredCredential -Path $CFG.CertCredFile
    if (-not $certCred) {
        $secure = ConvertTo-SecureString -String (New-RandomPassword) -AsPlainText -Force
        Save-StoredCredential -Path $CFG.CertCredFile -UserName 'certs' -Password $secure
        $certCred = Get-StoredCredential -Path $CFG.CertCredFile
    }
    $certPassword = ConvertTo-PlainText $certCred.Password

    $result = Invoke-GuestScript -Activity 'Windows environment capture' -TimeoutMinutes 30 -ArgumentList @(
        $CFG.GuestSetupDir, $certPassword, $CFG.ExcludeTaskPrefix
    ) -ScriptBlock {
        param($setupDir, $certPassword, $excludePrefix)
        $ErrorActionPreference = 'Stop'
        $staging = Join-Path $setupDir 'winstate'
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $staging 'certs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $staging 'tasks') -Force | Out-Null

        $out = [ordered]@{
            EnvMachine = @{}
            EnvUser    = @{}
            PathEntries = @{ Machine = @(); User = @() }
            Certificates = @()
            FirewallRules = 0
            ScheduledTasks = @()
            MappedDrives = @()
            Notes = @()
        }

        # -- environment variables -------------------------------------------
        # PATH is captured separately: restoring it wholesale onto a fresh
        # install would wipe entries the new installers added.
        foreach ($scope in 'Machine', 'User') {
            $vars = [Environment]::GetEnvironmentVariables($scope)
            $table = @{}
            foreach ($key in $vars.Keys) {
                if ($key -in 'Path', 'PSModulePath', 'TEMP', 'TMP') { continue }
                $table[$key] = $vars[$key]
            }
            if ($scope -eq 'Machine') { $out.EnvMachine = $table } else { $out.EnvUser = $table }
            $out.PathEntries[$scope] = @(([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ })
        }

        # -- hosts file -------------------------------------------------------
        $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
        if (Test-Path $hosts) {
            $lines = @(Get-Content $hosts | Where-Object { $_ -match '^\s*[^#\s]' })
            if ($lines.Count -gt 0) {
                Copy-Item $hosts (Join-Path $staging 'hosts') -Force
                $out.Notes += "hosts file has $($lines.Count) active entr(ies)"
            }
        }

        # -- certificates -----------------------------------------------------
        # Personal stores, plus self-signed roots, which is where developer and
        # local HTTPS certificates live. The stock Microsoft trust list is left
        # alone: it comes back with a fresh Windows install anyway.
        $stores = @('Cert:\LocalMachine\My', 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\Root')
        $securePwd = ConvertTo-SecureString -String $certPassword -AsPlainText -Force
        foreach ($store in $stores) {
            foreach ($cert in @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue)) {
                if ($store -eq 'Cert:\LocalMachine\Root' -and $cert.Issuer -ne $cert.Subject) { continue }
                if ($store -eq 'Cert:\LocalMachine\Root' -and $cert.Subject -match '(?i)microsoft|verisign|digicert|globalsign|baltimore|thawte|entrust|sectigo|comodo|go daddy|symantec|starfield|usertrust') { continue }
                $file = Join-Path $staging "certs\$($cert.Thumbprint).pfx"
                $exported = $false
                try {
                    Export-PfxCertificate -Cert $cert -FilePath $file -Password $securePwd -ErrorAction Stop | Out-Null
                    $exported = $true
                }
                catch {
                    # No exportable private key: a .cer still restores trust.
                    try {
                        $file = Join-Path $staging "certs\$($cert.Thumbprint).cer"
                        Export-Certificate -Cert $cert -FilePath $file -ErrorAction Stop | Out-Null
                        $exported = $true
                    }
                    catch {
                        $out.Notes += "certificate $($cert.Thumbprint) could not be exported: $($_.Exception.Message)"
                    }
                }
                if ($exported) {
                    $out.Certificates += [pscustomobject]@{
                        Thumbprint = $cert.Thumbprint
                        Subject    = "$($cert.Subject)"
                        Store      = $store
                        File       = [IO.Path]::GetFileName($file)
                        HasKey     = ($file -like '*.pfx')
                        NotAfter   = $cert.NotAfter.ToString('o')
                    }
                }
            }
        }

        # -- custom firewall rules ----------------------------------------------
        # Built-in rules belong to a Group; anything ungrouped was added locally.
        $rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Group -and $_.Enabled -eq 'True' -and $_.DisplayName -notlike "$excludePrefix*" })
        $ruleData = @()
        foreach ($rule in $rules) {
            $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $addrFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            $ruleData += [pscustomobject]@{
                DisplayName = $rule.DisplayName
                Direction   = "$($rule.Direction)"
                Action      = "$($rule.Action)"
                Protocol    = "$($portFilter.Protocol)"
                LocalPort   = @($portFilter.LocalPort)
                RemoteAddress = @($addrFilter.RemoteAddress)
                Profile     = "$($rule.Profile)"
            }
        }
        $ruleData | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $staging 'firewall.json') -Encoding UTF8
        $out.FirewallRules = $ruleData.Count

        # -- user-created scheduled tasks ---------------------------------------
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -notlike "$excludePrefix*" })) {
            try {
                $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
                $safe = ($task.TaskName -replace '[\\/:*?"<>|]', '_')
                $xml | Set-Content (Join-Path $staging "tasks\$safe.xml") -Encoding Unicode
                $out.ScheduledTasks += $task.TaskName
            }
            catch {
                $out.Notes += "scheduled task '$($task.TaskName)' could not be exported: $($_.Exception.Message)"
            }
        }

        # -- mapped drives -------------------------------------------------------
        foreach ($drive in @(Get-CimInstance Win32_NetworkConnection -ErrorAction SilentlyContinue)) {
            $out.MappedDrives += [pscustomobject]@{ Letter = "$($drive.LocalName)"; Path = "$($drive.RemoteName)" }
        }

        ([pscustomobject]$out) | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $staging 'environment.json') -Encoding UTF8

        # One zip out rather than a file-by-file crawl over the VMBus.
        $zip = Join-Path $setupDir 'winstate.zip'
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)

        return [pscustomobject]@{ Zip = $zip; Summary = [pscustomobject]$out }
    }

    $zipDest = Join-Path $windowsDir 'winstate.zip'
    Copy-FromGuest -GuestPath $result.Zip -HostPath $zipDest

    $summary = $result.Summary
    Write-Log ("  environment: {0} machine + {1} user variable(s), {2} certificate(s), {3} firewall rule(s), {4} task(s)" -f `
        (@($summary.EnvMachine.PSObject.Properties).Count), (@($summary.EnvUser.PSObject.Properties).Count),
        (@($summary.Certificates).Count), $summary.FirewallRules, (@($summary.ScheduledTasks).Count)) 'OK'
    foreach ($note in @($summary.Notes)) { Write-Log "  $note" 'INFO' }

    return [pscustomobject]@{
        Archive        = $zipDest
        Certificates   = @($summary.Certificates)
        FirewallRules  = $summary.FirewallRules
        ScheduledTasks = @($summary.ScheduledTasks)
        MappedDrives   = @($summary.MappedDrives)
    }
}

# ── Project files held on the guest ──────────────────────────────────────────
function Save-GuestProjectFiles {
    <#
      Anything kept on the guest's own disk. Source on the Dev Drive needs no
      capture: that disk persists across rebuilds, and source control backs it.
    #>
    $projectsDir = Join-Path $CFG.StateDir 'projects'

    $result = Invoke-GuestScript -Activity 'project capture' -TimeoutMinutes 60 -ArgumentList @(
        $CFG.GuestSetupDir, $CFG.GuestProjectPaths, $CFG.ProjectExcludeDirs, $CFG.MaxProjectCaptureGB
    ) -ScriptBlock {
        param($setupDir, $paths, $excludes, $maxGB)
        $ErrorActionPreference = 'Stop'

        $staging = Join-Path $setupDir 'projects'
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        $included = @(); $skipped = @(); $bytes = 0
        foreach ($raw in $paths) {
            $path = [Environment]::ExpandEnvironmentVariables($raw)
            if (-not (Test-Path $path)) { continue }

            $name = (Split-Path $path -Leaf)
            $dest = Join-Path $staging $name
            $i = 1
            while (Test-Path $dest) { $dest = Join-Path $staging "$name-$i"; $i++ }

            # Build outputs and package caches are regenerable; copying them
            # would balloon the archive for no benefit.
            $robocopyArgs = @($path, $dest, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
            if ($excludes.Count -gt 0) { $robocopyArgs += '/XD'; $robocopyArgs += $excludes }
            & robocopy.exe @robocopyArgs | Out-Null
            if ($LASTEXITCODE -ge 8) { $skipped += "$path (robocopy exit $LASTEXITCODE)"; continue }

            $size = (Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if (-not $size) { $size = 0 }
            if (($bytes + $size) -gt ($maxGB * 1GB)) {
                Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
                $skipped += "$path (would exceed the ${maxGB} GB capture limit)"
                continue
            }
            $bytes += $size
            $included += [pscustomobject]@{ Source = $path; Bytes = $size }
        }

        if ($included.Count -eq 0) {
            Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Zip = $null; Included = @(); Skipped = $skipped; Bytes = 0 }
        }

        $zip = Join-Path $setupDir 'projects.zip'
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue

        return [pscustomobject]@{ Zip = $zip; Included = $included; Skipped = $skipped; Bytes = $bytes }
    }

    foreach ($skip in @($result.Skipped)) { Write-Log "  skipped $skip" 'WARN' }

    if (-not $result.Zip) {
        Write-Log '  no guest-side project files found' 'INFO'
        return $null
    }

    $dest = Join-Path $projectsDir 'projects.zip'
    Copy-FromGuest -GuestPath $result.Zip -HostPath $dest
    Write-Log "  projects: $(@($result.Included).Count) folder(s), $(Format-Size $result.Bytes) -> $(Format-Size (Get-Item $dest).Length) compressed" 'OK'

    return [pscustomobject]@{
        Archive  = $dest
        Included = @($result.Included | ForEach-Object { $_.Source })
        Bytes    = $result.Bytes
    }
}

# ── Application settings ─────────────────────────────────────────────────────
function Save-GuestAppSettings {
    <#
      Exports each registry key in AppSettings to <StateDir>\apps\<Name>.reg.
      A key that does not exist yet (the application was never started) is
      skipped, not an error.
    #>
    $entries = @($CFG.AppSettings)
    if ($entries.Count -eq 0) { return @() }

    $appsDir = Join-Path $CFG.StateDir 'apps'
    $saved = @()
    foreach ($entry in $entries) {
        $name = "$($entry['Name'])"
        $key = "$($entry['RegistryKey'])"
        $guestFile = Join-Path $CFG.GuestSetupDir "app-$name.reg"

        $exported = Invoke-GuestScript -Activity "$name settings export" -TimeoutMinutes 5 `
            -ArgumentList @($key, $guestFile, $CFG.GuestSetupDir) -ScriptBlock {
            param($key, $file, $setupDir)
            if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            & reg.exe export $key $file /y 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0 -and (Test-Path $file))
        }

        if (-not $exported) {
            Write-Log "  $name - no settings in the registry yet ($key)" 'INFO'
            continue
        }
        $hostFile = Join-Path $appsDir "$name.reg"
        Copy-FromGuest -GuestPath $guestFile -HostPath $hostFile
        Write-Log "  $name settings" 'OK'
        $saved += [pscustomobject]@{ Name = $name; RegistryKey = $key; File = $hostFile }
    }
    return @($saved)
}
