# PostConfiguration.ps1 - part of Massokissed.LazyVM.Installation. Phase 8: SQL data relocation, settings and database restore.
# Dot-sourced by Massokissed.LazyVM.Installation.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 8 — Post-Configuration
#
#  Each step is isolated, so a failure in one is logged and the remaining
#  steps still run.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase8-PostConfig {
    Write-Log 'PHASE 8 - Post-Configuration' 'PHASE'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$($CFG.VMName)' not found - skipping Phase 8" 'WARN'
        return
    }

    $credential = Get-GuestCredential
    if (-not $credential) {
        Write-Log 'No stored guest credential - skipping Phase 8' 'WARN'
        return
    }
    if ($vm.State -ne 'Running') {
        Write-Log "VM is '$($vm.State)' - skipping Phase 8 (start the VM and re-run with -FromPhase 8)" 'WARN'
        return
    }

    Connect-Guest -Credential $credential | Out-Null

    $steps = @(
        [pscustomobject]@{ Name = '8a - SQL data disk'; Action = { Confirm-SqlDataDisk } }
        [pscustomobject]@{ Name = '8b - relocate SQL data files'; Action = { Move-GuestSqlDataFile } }
        [pscustomobject]@{ Name = '8c - VS settings'; Action = { Restore-VSSettings } }
        [pscustomobject]@{ Name = '8d - database restore'; Action = { Restore-SqlDatabases } }
    )

    $failures = 0
    foreach ($step in $steps) {
        try {
            & $step.Action
        }
        catch {
            $failures++
            Write-LogError "$($step.Name) failed" $_
            Write-Log "  Continuing with the remaining Phase 8 steps." 'INFO'
        }
    }

    if ($failures -gt 0) {
        Write-Log "Phase 8 finished with $failures of $($steps.Count) steps failing" 'WARN'
    }
    else {
        Write-Log 'Phase 8 complete' 'OK'
    }
}

function Confirm-SqlDataDisk {
    $attached = @(Get-VMHardDiskDrive -VMName $CFG.VMName |
            Where-Object { $_.Path -eq $CFG.SQLDiskPath })
    if ($attached.Count -eq 0) { Add-SqlDataDisk }
    else { Write-Log 'SQL data disk attached' 'OK' }

    # Always run this, even when the disk was already attached: it is
    # idempotent, and it is what resolves the actual drive letter that the
    # restore step below needs. Running Phase 8 on its own would otherwise fall
    # back to the configured default and look in the wrong place.
    Initialize-GuestSqlDisk
}

function Move-GuestSqlDataFile {
    <#
      Relocates an existing SQL Server instance's files onto the data disk.

      This matters for a guest where SQL was installed before the data disk
      existed: its databases sit on C: and stay there, because setup's
      /SQLUSERDBDIR only applies at install time.

      Scope and safety:
        * User databases and tempdb only. master, model and msdb are NOT
          touched — moving those needs startup-parameter surgery and a
          single-user-mode restart, which does not belong in a build script.
        * Files already on the target disk are skipped, so this is idempotent.
        * Files are COPIED, verified by length, and the originals deleted only
          after the database comes back online. Any failure rolls the metadata
          back to the original paths and brings the database up where it was.
        * Free space is checked before anything is touched.
        * tempdb is metadata-only: SQL recreates its files on restart, so the
          old ones are simply removed afterwards.
    #>
    if (-not $CFG.MoveSqlDataToDataDisk) {
        Write-Log 'SQL data relocation disabled in config (MoveSqlDataToDataDisk) - skipping' 'INFO'
        return
    }

    $instance = Get-GuestSqlInstance
    if (-not $instance) {
        Write-Log 'No SQL Server instance in the guest - nothing to relocate' 'INFO'
        return
    }

    Set-GuestSqlServer -Instance $instance.Instance
    $serviceName = if ($instance.Instance -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$($instance.Instance)" }

    Write-Log "Relocating SQL data files for instance '$($instance.Instance)' onto $($CFG.GuestDataDriveLetter):..." 'INFO'

    $report = Invoke-GuestScript -Activity 'SQL data file relocation' -TimeoutMinutes 120 -ArgumentList @(
        (Get-GuestSqlServer), $serviceName, $instance.Instance,
        $CFG.GuestSqlDataDir, $CFG.GuestSqlLogDir, $CFG.GuestSqlTempDir, $CFG.GuestSqlBackupDir,
        $CFG.GuestDataDriveLetter
    ) -ScriptBlock {
        param($server, $serviceName, $instanceName, $dataDir, $logDir, $tempDir, $backupDir, $letter)
        $ErrorActionPreference = 'Stop'
        $log = @()
        # Initialised up front: the restart block below runs outside the try,
        # and the guest session does not inherit the caller's StrictMode.
        $tempdbMoved = $false
        $oldTempFiles = @()

        foreach ($dir in @($dataDir, $logDir, $tempDir, $backupDir)) {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }

        $connectionString = "Server=$server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()

        function Invoke-Sql($conn, $sql, $timeout = 600) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $sql
            $cmd.CommandTimeout = $timeout
            return $cmd.ExecuteNonQuery()
        }

        function Get-Rows($conn, $sql) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $sql
            $reader = $cmd.ExecuteReader()
            $rows = @()
            try {
                while ($reader.Read()) {
                    $row = @{}
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) { $row[$reader.GetName($i)] = $reader.GetValue($i) }
                    $rows += [pscustomobject]$row
                }
            }
            finally { $reader.Close() }
            return $rows
        }

        try {
            # database_id 1..4 are master/tempdb/model/msdb. Take user
            # databases plus tempdb; deliberately leave the rest alone.
            # @() so a single-row result does not unroll to a scalar on return.
            $files = @(Get-Rows $connection @'
SELECT d.name AS DbName, d.database_id AS DbId, d.state_desc AS State,
       mf.name AS LogicalName, mf.physical_name AS PhysicalName, mf.type_desc AS FileType
FROM sys.master_files mf
JOIN sys.databases d ON d.database_id = mf.database_id
WHERE d.database_id > 4 OR d.database_id = 2
ORDER BY d.name, mf.file_id
'@)

            if ($files.Count -eq 0) {
                return @('no user databases or tempdb files found')
            }

            $targetRoot = "${letter}:\"
            $groups = $files | Group-Object DbName

            # ---- tempdb: metadata only, files are recreated on restart ----
            $tempdbGroup = $groups | Where-Object { $_.Name -eq 'tempdb' }
            $tempdbMoved = $false
            if ($tempdbGroup) {
                $oldTempFiles = @()
                foreach ($f in $tempdbGroup.Group) {
                    if ($f.PhysicalName -like "$targetRoot*") { continue }
                    $leaf = [IO.Path]::GetFileName($f.PhysicalName)
                    $dest = Join-Path $tempDir $leaf
                    $logical = $f.LogicalName.Replace("'", "''")
                    $destEsc = $dest.Replace("'", "''")
                    Invoke-Sql $connection "ALTER DATABASE [tempdb] MODIFY FILE (NAME = N'$logical', FILENAME = N'$destEsc')" | Out-Null
                    $oldTempFiles += $f.PhysicalName
                    $tempdbMoved = $true
                }
                if ($tempdbMoved) {
                    $log += "tempdb: repointed to $tempDir (takes effect on restart)"
                }
                else { $log += 'tempdb: already on the data disk' }
            }

            # ---- user databases: copy, repoint, verify, then clean up ----
            foreach ($group in ($groups | Where-Object { $_.Name -ne 'tempdb' })) {
                $dbName = $group.Name
                $dbFiles = @($group.Group)

                if ($dbFiles[0].State -ne 'ONLINE') {
                    $log += "skipped $dbName (state is $($dbFiles[0].State))"
                    continue
                }

                $toMove = @($dbFiles | Where-Object { $_.PhysicalName -notlike "$targetRoot*" })
                if ($toMove.Count -eq 0) {
                    $log += "skipped $dbName (already on ${letter}:)"
                    continue
                }

                $missing = @($toMove | Where-Object { -not (Test-Path $_.PhysicalName) })
                if ($missing.Count -gt 0) {
                    $log += "skipped $dbName (files not found on disk: $(($missing.PhysicalName) -join ', '))"
                    continue
                }

                $needBytes = ($toMove | ForEach-Object { (Get-Item $_.PhysicalName).Length } | Measure-Object -Sum).Sum
                $freeBytes = (Get-PSDrive -Name $letter).Free
                if ($needBytes -gt ($freeBytes * 0.95)) {
                    $log += "skipped $dbName (needs $([math]::Round($needBytes/1GB,1)) GB, only $([math]::Round($freeBytes/1GB,1)) GB free on ${letter}:)"
                    continue
                }

                $quoted = '[' + $dbName.Replace(']', ']]') + ']'
                $plan = @()
                foreach ($f in $toMove) {
                    $destDir = if ($f.FileType -eq 'LOG') { $logDir } else { $dataDir }
                    $dest = Join-Path $destDir ([IO.Path]::GetFileName($f.PhysicalName))
                    # Belt and braces alongside the drive-root check above: never
                    # let Copy-Item be handed the same path twice, which throws
                    # "cannot overwrite the item with itself" and would send a
                    # perfectly healthy database down the rollback path.
                    if ([IO.Path]::GetFullPath($dest) -eq [IO.Path]::GetFullPath($f.PhysicalName)) { continue }
                    $plan += [pscustomobject]@{
                        Logical = $f.LogicalName
                        Source  = $f.PhysicalName
                        Dest    = $dest
                    }
                }
                if ($plan.Count -eq 0) {
                    $log += "skipped $dbName (files are already in their target folders)"
                    continue
                }

                $offline = $false
                $repointed = @()
                try {
                    Invoke-Sql $connection "ALTER DATABASE $quoted SET OFFLINE WITH ROLLBACK IMMEDIATE" | Out-Null
                    $offline = $true

                    foreach ($item in $plan) {
                        Copy-Item -LiteralPath $item.Source -Destination $item.Dest -Force
                        $srcLen = (Get-Item -LiteralPath $item.Source).Length
                        $dstLen = (Get-Item -LiteralPath $item.Dest).Length
                        if ($srcLen -ne $dstLen) {
                            throw "copy of $($item.Source) is $dstLen bytes, expected $srcLen"
                        }
                    }

                    foreach ($item in $plan) {
                        $l = $item.Logical.Replace("'", "''")
                        $d = $item.Dest.Replace("'", "''")
                        Invoke-Sql $connection "ALTER DATABASE $quoted MODIFY FILE (NAME = N'$l', FILENAME = N'$d')" | Out-Null
                        $repointed += $item
                    }

                    Invoke-Sql $connection "ALTER DATABASE $quoted SET ONLINE" 900 | Out-Null
                    $offline = $false

                    # Only now are the originals expendable.
                    foreach ($item in $plan) {
                        Remove-Item -LiteralPath $item.Source -Force -ErrorAction SilentlyContinue
                    }
                    $log += "moved $dbName ($($plan.Count) file(s), $([math]::Round($needBytes/1MB)) MB) to ${letter}:"
                }
                catch {
                    $reason = $_.Exception.Message
                    # Roll back: point the metadata at the originals, bring the
                    # database up where it was, and discard the copies.
                    try {
                        foreach ($item in $repointed) {
                            $l = $item.Logical.Replace("'", "''")
                            $s = $item.Source.Replace("'", "''")
                            Invoke-Sql $connection "ALTER DATABASE $quoted MODIFY FILE (NAME = N'$l', FILENAME = N'$s')" | Out-Null
                        }
                        if ($offline) { Invoke-Sql $connection "ALTER DATABASE $quoted SET ONLINE" 900 | Out-Null }
                        foreach ($item in $plan) {
                            if ((Test-Path $item.Dest) -and (Test-Path $item.Source)) {
                                Remove-Item -LiteralPath $item.Dest -Force -ErrorAction SilentlyContinue
                            }
                        }
                        $log += "FAILED $dbName - $reason (rolled back, database is online at its original location)"
                    }
                    catch {
                        $log += "FAILED $dbName - $reason; ROLLBACK ALSO FAILED: $($_.Exception.Message). Database may be OFFLINE - check it by hand."
                    }
                }
            }

            # ---- defaults for databases created from here on ----
            try {
                # Look up THIS instance's internal key name, not whichever one
                # happens to be listed first.
                $instanceKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                $internal = $instanceKey.$instanceName
                if (-not $internal) { throw "instance '$instanceName' not found in the registry" }
                $settingsKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$internal\MSSQLServer"
                Set-ItemProperty -Path $settingsKey -Name 'DefaultData' -Value $dataDir
                Set-ItemProperty -Path $settingsKey -Name 'DefaultLog'  -Value $logDir
                Set-ItemProperty -Path $settingsKey -Name 'BackupDirectory' -Value $backupDir
                $log += "default data/log/backup directories set to ${letter}: (applies to new databases)"
            }
            catch {
                $log += "could not set default directories: $($_.Exception.Message)"
            }
        }
        finally { $connection.Close() }

        # ---- restart so tempdb and the new defaults take effect ----
        if ($tempdbMoved) {
            try {
                $svc = Get-Service -Name $serviceName -ErrorAction Stop
                $dependents = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
                Restart-Service -Name $serviceName -Force -ErrorAction Stop
                (Get-Service -Name $serviceName).WaitForStatus('Running', [TimeSpan]::FromMinutes(5))
                foreach ($dep in $dependents) { Start-Service -Name $dep -ErrorAction SilentlyContinue }
                $log += "restarted $serviceName"

                foreach ($old in $oldTempFiles) {
                    if (Test-Path $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
                }
            }
            catch {
                $log += "could not restart ${serviceName}: $($_.Exception.Message) - restart it to activate the tempdb move"
            }
        }

        return $log
    }

    foreach ($line in @($report)) {
        if ($line -like 'FAILED*') { Write-Log "  $line" 'ERROR' }
        elseif ($line -like 'skipped*' -or $line -like 'no user*') { Write-Log "  $line" 'INFO' }
        elseif ($line -like 'could not*') { Write-Log "  $line" 'WARN' }
        else { Write-Log "  $line" 'OK' }
    }
    Write-Log 'SQL data relocation complete' 'OK'
}

function Restore-VSSettings {
    if (-not (Test-Path -LiteralPath $CFG.VSSettingsBackup)) {
        Write-Log "No VS settings backup at $($CFG.VSSettingsBackup) - skipping" 'INFO'
        Write-Log '  Create one with: Visual Studio -> Tools -> Import/Export Settings -> Export all settings' 'INFO'
        return
    }

    $destination = Join-Path $CFG.GuestSetupDir 'VisualStudio.vssettings'
    Copy-VMFile -Name $CFG.VMName -SourcePath $CFG.VSSettingsBackup -DestinationPath $destination `
        -CreateFullPath -FileSource Host -Force -ErrorAction Stop
    Write-Log 'VS settings file copied into the guest' 'OK'

    # devenv is located with vswhere rather than assuming the Community path,
    # so Professional and Enterprise installs work too.
    $vs = Get-GuestVisualStudio
    if (-not $vs) {
        Write-Log 'Visual Studio is not installed in the guest - skipping the settings restore' 'WARN'
        return
    }
    Write-Log "Found $($vs.DisplayName) at $($vs.DevEnvPath)" 'INFO'

    # devenv /ResetSettings writes to the per-user settings store and needs a
    # real desktop session, so it runs as the interactive user.
    $script = @"
    `$devenv = '$($vs.DevEnvPath)'
    if (-not (Test-Path `$devenv)) { throw "devenv.exe not found at `$devenv" }
    `$proc = Start-Process -FilePath `$devenv -ArgumentList '/ResetSettings','"$destination"' -Wait -PassThru
    if (`$proc.ExitCode -ne 0) { throw "devenv exited with `$(`$proc.ExitCode)" }
"@

    Invoke-GuestScriptAsInteractiveUser -ScriptText $script -TaskName 'LazyVM-VSSettings' `
        -Activity 'Visual Studio settings restore' -TimeoutMinutes 20

    Write-Log 'Visual Studio settings restored' 'OK'
}

function Restore-SqlDatabases {
    <#
      Rewritten for safety. The previous version used Invoke-Sqlcmd with
      -ErrorAction SilentlyContinue for its "does this database exist?" check:
      if the SqlServer module was missing — and nothing installed it — the
      check returned null, the guard passed, and the restore ran WITH REPLACE,
      silently overwriting a live database.

      This version uses System.Data.SqlClient (always present, no module to
      install), fails closed if the existence check cannot run, reads the real
      logical file names with RESTORE FILELISTONLY instead of assuming they
      match the database name, and never passes REPLACE.
    #>
    Write-Log "Checking $($CFG.GuestSqlBackupDir) for databases to restore..." 'INFO'

    $results = Invoke-GuestScript -Activity 'SQL database restore' -TimeoutMinutes 60 `
        -ArgumentList @($CFG.GuestSqlBackupDir, $CFG.GuestSqlDataDir, $CFG.GuestSqlLogDir, (Get-GuestSqlServer)) -ScriptBlock {
        param($backupDir, $dataDir, $logDir, $server)
        $ErrorActionPreference = 'Stop'
        $log = @()

        if (-not (Test-Path $backupDir)) {
            return @("no backup directory at $backupDir")
        }
        $backups = @(Get-ChildItem -Path $backupDir -Filter '*.bak' -File -ErrorAction SilentlyContinue)
        if ($backups.Count -eq 0) {
            return @("no .bak files in $backupDir")
        }

        $connectionString = "Server=$server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()

        try {
            foreach ($backup in $backups) {
                $dbName = [IO.Path]::GetFileNameWithoutExtension($backup.Name)
                # Bracket-quote and escape so an odd filename cannot alter the batch.
                $quotedName = '[' + $dbName.Replace(']', ']]') + ']'
                $literalName = "N'" + $dbName.Replace("'", "''") + "'"
                $literalPath = "N'" + $backup.FullName.Replace("'", "''") + "'"

                # Existence check. Any failure here aborts THIS database
                # rather than falling through to a destructive restore.
                $check = $connection.CreateCommand()
                $check.CommandText = "SELECT COUNT(*) FROM sys.databases WHERE name = $literalName"
                $exists = [int]$check.ExecuteScalar()
                if ($exists -gt 0) {
                    $log += "skipped (already exists): $dbName"
                    continue
                }

                # Real logical file names, rather than assuming <db> and <db>_log.
                $fileList = $connection.CreateCommand()
                $fileList.CommandText = "RESTORE FILELISTONLY FROM DISK = $literalPath"
                $reader = $fileList.ExecuteReader()
                $moves = @()
                try {
                    while ($reader.Read()) {
                        $logicalName = $reader['LogicalName']
                        $type = "$($reader['Type'])".ToUpperInvariant()
                        $originalPath = "$($reader['PhysicalName'])"
                        $leaf = [IO.Path]::GetFileName($originalPath)
                        $targetDir = if ($type -eq 'L') { $logDir } else { $dataDir }
                        $target = Join-Path $targetDir $leaf
                        $moves += "MOVE N'" + $logicalName.Replace("'", "''") + "' TO N'" + $target.Replace("'", "''") + "'"
                    }
                }
                finally { $reader.Close() }

                if ($moves.Count -eq 0) {
                    $log += "skipped (no file list): $dbName"
                    continue
                }

                $restore = $connection.CreateCommand()
                $restore.CommandTimeout = 3600
                # No REPLACE: the existence check above already established
                # that nothing is being overwritten.
                $restore.CommandText = "RESTORE DATABASE $quotedName FROM DISK = $literalPath WITH $($moves -join ', '), STATS = 10"
                $restore.ExecuteNonQuery() | Out-Null
                $log += "restored: $dbName"
            }
        }
        finally { $connection.Close() }

        return $log
    }

    foreach ($line in @($results)) {
        if ($line -like 'restored:*') { Write-Log "  $line" 'OK' } else { Write-Log "  $line" 'INFO' }
    }
    Write-Log 'Database restore check complete' 'OK'
}
