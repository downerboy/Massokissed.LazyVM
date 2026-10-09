# HostPreparation.ps1 - part of Massokissed.LazyVM.Host. Phases 0-5: Hyper-V service check, readiness, feature enable, folders, assets, SQL disk.
# Dot-sourced by Massokissed.LazyVM.Host.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 0 — Hyper-V Service Health Check
#
#  Only vmms (and, if disabled, vmcompute) are corrected. The vmic* services
#  are GUEST-side integration components: on a Hyper-V host they are
#  trigger-start Manual by design, and the host's copies play no part in
#  Copy-VMFile or PowerShell Direct — those are served by vmms worker
#  processes. The previous version forced all ten to Automatic, which fought
#  Windows' defaults for no benefit, so they are now reported only.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase0-ServiceCheck {
    Write-Log 'PHASE 0 - Hyper-V Service Health Check' 'PHASE'

    $needsFeatureInstall = $false

    # Services the host genuinely needs, with the startup type they should have.
    $hostServices = @(
        [pscustomobject]@{ Name = 'vmms'; Display = 'Hyper-V Virtual Machine Management'; Want = 'Automatic'; MustRun = $true }
        [pscustomobject]@{ Name = 'vmcompute'; Display = 'Hyper-V Host Compute Service'; Want = 'Manual'; MustRun = $false }
    )

    # Guest-side components. Reported for diagnostics; never reconfigured.
    $guestServices = @(
        'vmicheartbeat', 'vmickvpexchange', 'vmicguestinterface', 'vmicrdv',
        'vmicshutdown', 'vmictimesync', 'vmicvmsession', 'vmicvss'
    )

    foreach ($svc in $hostServices) {
        # Win32_Service is used for reading because ServiceController.StartType
        # is not present on every PowerShell 5.1 / .NET combination, and
        # StrictMode turns a missing property into a terminating error.
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue

        if (-not $cim) {
            Write-Log "$($svc.Display) - NOT FOUND. Hyper-V feature is not installed." 'WARN'
            $needsFeatureInstall = $true
            continue
        }

        $startMode = $cim.StartMode      # Auto | Manual | Disabled | Boot | System
        $wantMode = if ($svc.Want -eq 'Automatic') { 'Auto' } else { $svc.Want }

        if ($startMode -eq 'Disabled' -or ($svc.Want -eq 'Automatic' -and $startMode -ne 'Auto')) {
            Write-Log "$($svc.Display) - StartMode='$startMode' -> setting $($svc.Want)" 'WARN'
            try {
                Set-Service -Name $svc.Name -StartupType $svc.Want -ErrorAction Stop
                Write-Log "$($svc.Display) - startup type set to $($svc.Want)" 'OK'
            }
            catch {
                Write-LogError "$($svc.Display) - could not set startup type" $_
                $needsFeatureInstall = $true
                continue
            }
        }
        else {
            Write-Log "$($svc.Display) - StartMode=$startMode (expected $wantMode)" 'INFO'
        }

        if ($svc.MustRun -and $cim.State -ne 'Running') {
            Write-Log "$($svc.Display) - State='$($cim.State)' -> starting..." 'WARN'
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                (Get-Service -Name $svc.Name).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                Write-Log "$($svc.Display) - now Running" 'OK'
            }
            catch {
                Write-LogError "$($svc.Display) - failed to start" $_
                $needsFeatureInstall = $true
            }
        }
        elseif ($svc.MustRun) {
            Write-Log "$($svc.Display) - Running" 'OK'
        }
    }

    $present = @()
    $missing = @()
    foreach ($name in $guestServices) {
        if (Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue) {
            $present += $name
        }
        else { $missing += $name }
    }
    Write-Log "Guest integration components on host: $($present.Count) present, $($missing.Count) absent (informational - not reconfigured)" 'INFO'

    Write-Log 'Phase 0 complete' 'OK'
    return $needsFeatureInstall
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — CPU / Firmware / Capacity Readiness
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase1-CPUCheck {
    Write-Log 'PHASE 1 - CPU, Firmware and Capacity Readiness' 'PHASE'

    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem

    Write-Log "CPU  : $($cpu.Name)" 'INFO'
    Write-Log "Cores: $($cpu.NumberOfCores)  Threads: $($cpu.NumberOfLogicalProcessors)" 'INFO'

    if ($cpu.NumberOfLogicalProcessors -lt $CFG.vCPU) {
        Write-Log "Host has $($cpu.NumberOfLogicalProcessors) logical processors but the VM is configured for $($CFG.vCPU) vCPU" 'WARN'
    }

    # SLAT. WMI hides raw CPU flags once Hyper-V owns the machine, so
    # SecondLevelAddressTranslationExtensions reads False on any running
    # Hyper-V host. Cheapest reliable signals first; systeminfo (slow, and
    # its output is localised) only as a last resort.
    $slatConfirmed = $false
    if ($cs.HypervisorPresent) {
        Write-Log 'SLAT confirmed - a hypervisor is already running (HypervisorPresent = True)' 'OK'
        $slatConfirmed = $true
    }
    elseif ($cpu.SecondLevelAddressTranslationExtensions) {
        Write-Log 'SLAT confirmed via WMI' 'OK'
        $slatConfirmed = $true
    }
    else {
        Write-Log 'SLAT not visible via WMI - falling back to systeminfo (this takes ~30s)' 'INFO'
        try {
            $sysinfo = & systeminfo.exe 2>&1
            $slatLine = @($sysinfo | Where-Object { $_ -match 'Second Level Address Translation' })
            if ($slatLine.Count -gt 0 -and ($slatLine -join ' ') -match '(?i)\byes\b') {
                Write-Log 'SLAT confirmed via systeminfo' 'OK'
                $slatConfirmed = $true
            }
            elseif ($slatLine.Count -eq 0) {
                Write-Log 'systeminfo did not report a SLAT line (non-English Windows?) - cannot confirm' 'WARN'
            }
        }
        catch {
            Write-LogError 'systeminfo check failed' $_
        }
    }

    if (-not $slatConfirmed) {
        Exit-WithError 'SLAT (Intel EPT / AMD RVI) not detected. Enable Intel VT-x / AMD-V and EPT/RVI in UEFI firmware, then re-run.'
    }

    if ($cpu.VMMonitorModeExtensions) {
        Write-Log 'VM Monitor Mode Extensions - supported' 'OK'
    }
    else {
        Write-Log 'VM Monitor Mode Extensions not reported (expected when a hypervisor is already active)' 'INFO'
    }

    # RAM
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Write-Log "Host RAM: $ramGB GB" 'INFO'
    if ($ramGB -lt ($CFG.MemMaxGB + 4)) {
        Write-Log "Host RAM is within 4 GB of the VM maximum ($($CFG.MemMaxGB) GB) - the host may page under load" 'WARN'
    }
    else {
        Write-Log "Host RAM comfortably supports Dynamic Memory $($CFG.MemMinGB)-$($CFG.MemMaxGB) GB" 'OK'
    }

    # Free space, measured on the volumes actually used and sized from config.
    $requirements = @(
        [pscustomobject]@{ Path = $CFG.VHDXRoot; NeedGB = $CFG.OSDiskSizeGB; What = 'OS VHDX' }
        [pscustomobject]@{ Path = (Split-Path $CFG.SQLDiskPath -Parent); NeedGB = 20; What = 'SQL data disk (initial allocation)' }
        [pscustomobject]@{ Path = $CFG.ISOSearchRoot; NeedGB = $CFG.ISOMinSizeGB + 2; What = 'ISO + installers' }
    )

    # Roll up by volume so two requirements on C: are not each checked in isolation.
    $byVolume = @{}
    foreach ($req in $requirements) {
        $root = [IO.Path]::GetPathRoot((Resolve-PathForce $req.Path))
        if (-not $byVolume.ContainsKey($root)) { $byVolume[$root] = 0 }
        $byVolume[$root] += $req.NeedGB
        Write-Log "  needs $($req.NeedGB) GB on $root for $($req.What)" 'INFO'
    }

    foreach ($root in $byVolume.Keys) {
        $freeGB = Get-FreeSpaceGB -Path $root
        $needGB = $byVolume[$root]
        if ($freeGB -lt 0) {
            Write-Log "$root - could not determine free space" 'WARN'
        }
        elseif ($freeGB -lt $needGB) {
            Write-Log "$root - $freeGB GB free, about $needGB GB needed. Dynamic disks will grow into this over time." 'WARN'
        }
        else {
            Write-Log "$root - $freeGB GB free (need ~$needGB GB)" 'OK'
        }
    }

    Write-Log 'Phase 1 complete' 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — Hyper-V Feature Enable (reboot + self-resuming scheduled task)
#
#  The previous version resumed via HKLM\...\RunOnce, which fires in the next
#  interactive user's context, is usually unelevated (so #Requires
#  -RunAsAdministrator fails immediately) and never fires at all under a SYSTEM
#  scheduled task. A one-shot startup task as SYSTEM works in every case.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase2-HyperVFeature {
    Write-Log 'PHASE 2 - Hyper-V Feature Installation' 'PHASE'

    # Hyper-V is not offered on Home editions. Detect that now rather than
    # failing obscurely in Phase 6.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Log "OS: $($os.Caption) (build $($os.BuildNumber))" 'INFO'
    if ($os.Caption -match '(?i)\bHome\b') {
        Exit-WithError "Hyper-V is not available on $($os.Caption). Windows Pro, Enterprise or Education is required."
    }

    # Microsoft-Hyper-V-All is the umbrella feature; enabling it with -All
    # pulls in the hypervisor, management tools and PowerShell module. Each
    # feature is classified explicitly so a name that does not exist on this
    # edition is reported rather than silently treated as "already enabled",
    # which is what the previous `$f -and ($f.State -ne 'Enabled')` filter did.
    $wanted = @(
        'Microsoft-Hyper-V-All'
        'Microsoft-Hyper-V'
        'Microsoft-Hyper-V-Hypervisor'
        'Microsoft-Hyper-V-Management-PowerShell'
        'Microsoft-Hyper-V-Tools-All'
    )

    $enabled = @()
    $disabled = @()
    $absent = @()

    foreach ($name in $wanted) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
        if (-not $feature) { $absent += $name }
        elseif ($feature.State -eq 'Enabled') { $enabled += $name }
        else { $disabled += "$name ($($feature.State))" }
    }

    if ($absent.Count -gt 0) {
        Write-Log "Feature names not present on this edition: $($absent -join ', ')" 'WARN'
    }
    if ($enabled.Count -gt 0) {
        Write-Log "Already enabled: $($enabled -join ', ')" 'OK'
    }

    if ($disabled.Count -eq 0) {
        if ($enabled.Count -eq 0) {
            Exit-WithError 'No Hyper-V features are available on this system. Check the Windows edition and firmware virtualization settings.'
        }
        Write-Log 'All required Hyper-V features are enabled' 'OK'
        return
    }

    Write-Log "Not yet enabled: $($disabled -join ', ')" 'WARN'

    if (-not $CFG.ScriptPath) {
        Exit-WithError 'Hyper-V needs enabling and the host must reboot, but the script path could not be determined (the script was piped or run via -Command). Save it to disk and run it with -File so the post-reboot resume can be scheduled.'
    }

    Register-ResumeTask -Phase 3

    Write-Log 'Enabling Microsoft-Hyper-V-All (several minutes)...' 'WARN'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart

    if ($result.RestartNeeded) {
        Write-Log 'Hyper-V enabled. Rebooting in 30 seconds; the build resumes automatically at Phase 3.' 'WARN'
        Write-Log "Cancel with: Unregister-ScheduledTask -TaskName '$($CFG.ResumeTaskName)' -Confirm:`$false" 'INFO'
        Start-Sleep -Seconds 30
        Restart-Computer -Force
        # Restart-Computer returns immediately; stop here so no later phase
        # starts work that the imminent reboot would tear down.
        exit 0
    }

    Write-Log 'Hyper-V enabled without requiring a restart' 'OK'
    Unregister-ResumeTask
}

function Register-ResumeTask {
    param([Parameter(Mandatory)][int]$Phase)

    if (-not (Test-Path -LiteralPath $CFG.ResumeRegKey)) {
        New-Item -Path $CFG.ResumeRegKey -Force | Out-Null
    }
    Set-ItemProperty -Path $CFG.ResumeRegKey -Name 'ResumePhase' -Value $Phase -Type DWord
    Set-ItemProperty -Path $CFG.ResumeRegKey -Name 'ScriptPath'  -Value $CFG.ScriptPath -Type String

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -VM "{3}" -Root "{2}" -FromPhase {1}' -f $CFG.ScriptPath, $Phase, $CFG.Root, $CFG.VMName
    )
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT2M'   # let services settle before the build resumes
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $CFG.ResumeTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    Write-Log "Resume task '$($CFG.ResumeTaskName)' registered (resumes at Phase $Phase after reboot)" 'OK'
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $CFG.ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $CFG.ResumeTaskName -Confirm:$false
        Write-Log "Resume task '$($CFG.ResumeTaskName)' removed" 'INFO'
    }
    if (Test-Path -LiteralPath $CFG.ResumeRegKey) {
        Remove-ItemProperty -Path $CFG.ResumeRegKey -Name 'ResumePhase' -ErrorAction SilentlyContinue
    }
}

function Get-ResumePhase {
    <# Reads the resume point WITHOUT clearing it. The previous version deleted
       the key before the resumed run did any work, so a crash during resume
       lost the resume point entirely. It is cleared only on success. #>
    if (-not (Test-Path -LiteralPath $CFG.ResumeRegKey)) { return 0 }
    $props = Get-ItemProperty -Path $CFG.ResumeRegKey -ErrorAction SilentlyContinue
    if (-not $props -or -not $props.PSObject.Properties['ResumePhase']) { return 0 }
    $phase = [int]$props.ResumePhase
    if ($phase -gt 0) { Write-Log "Resuming after reboot from Phase $phase" 'INFO' }
    return $phase
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 3 — Folder Structure
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase3-FolderSetup {
    Write-Log 'PHASE 3 - Folder Structure' 'PHASE'

    $folders = @(
        $CFG.Root
        $CFG.ISOSearchRoot
        (Split-Path $CFG.SQLInstallerPath -Parent)
        $CFG.VHDXRoot
        (Split-Path $CFG.SQLDiskPath -Parent)
        $CFG.CredStoreDir
        (Split-Path $CFG.GuestCredFile -Parent)
        (Split-Path $CFG.VSSettingsBackup -Parent)
        (Split-Path $CFG.LogFile -Parent)
        $CFG.CheckpointDir
    ) | Select-Object -Unique

    $created = 0
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Write-Log "Created : $folder" 'OK'
            $created++
        }
    }
    Write-Log "Phase 3 complete - $($folders.Count) folders verified, $created created" 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 4 — Asset Verification
#
#  The ISO is VERIFIED, never downloaded. Microsoft's evaluation fwlink returns
#  an HTML registration page, not an image: the previous version saved that
#  48 KB page as Win11Ent_Eval.iso, then deleted and re-downloaded it on every
#  subsequent run. Validity is proved by the ISO 9660 'CD001' signature rather
#  than by file size alone.
#
#  Installer downloads go to a .tmp file and are validated before replacing the
#  existing copy, so a failed download can never destroy a good one.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase4-AssetCheck {
    Write-Log 'PHASE 4 - Asset Verification' 'PHASE'

    Resolve-InstallationIso

    # Visual Studio and SSMS bootstrappers are not kept here: each is
    # downloaded in the guest, for the channel its tooling list names.
    $installers = @(
        [pscustomobject]@{
            Path      = $CFG.SQLInstallerPath
            Url       = $CFG.SQLInstallerUrl
            Label     = 'SQL Server 2022 Developer bootstrapper'
            MinBytes  = $CFG.SQLMinSizeMB * 1MB
        }
    )

    foreach ($item in $installers) {
        if ((Test-Path -LiteralPath $item.Path) -and
            (Test-PortableExecutable -Path $item.Path) -and
            ((Get-Item -LiteralPath $item.Path).Length -ge $item.MinBytes)) {

            $size = Format-Size ((Get-Item -LiteralPath $item.Path).Length)
            Write-Log "$($item.Label) - OK ($size)" 'OK'
            continue
        }

        if (Test-Path -LiteralPath $item.Path) {
            Write-Log "$($item.Label) - present but not a valid executable; re-downloading" 'WARN'
        }
        else {
            Write-Log "$($item.Label) - not found; downloading" 'INFO'
        }

        $temp = "$($item.Path).tmp"
        try {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $item.Url -OutFile $temp -UseBasicParsing -TimeoutSec 600

            if (-not (Test-PortableExecutable -Path $temp)) {
                throw "downloaded file is not an executable (got $(Format-Size (Get-Item -LiteralPath $temp).Length) - the URL probably returned an HTML page)"
            }
            if ((Get-Item -LiteralPath $temp).Length -lt $item.MinBytes) {
                throw "downloaded file is only $(Format-Size (Get-Item -LiteralPath $temp).Length), below the $($item.MinBytes / 1MB) MB minimum"
            }

            # Only now is the existing copy replaced.
            Move-Item -LiteralPath $temp -Destination $item.Path -Force
            Write-Log "$($item.Label) - downloaded ($(Format-Size (Get-Item -LiteralPath $item.Path).Length))" 'OK'
        }
        catch {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            Write-LogError "$($item.Label) - download failed" $_
            Exit-WithError "Cannot continue without $($item.Label). Download it manually from $($item.Url) and save it to $($item.Path)."
        }
    }

    Write-Log 'Phase 4 complete' 'OK'
}

function Resolve-InstallationIso {
    <# Validates the configured ISO. If it is not a real image, searches the
       ISO folder for one that is and adopts it (read-only discovery — nothing
       is renamed or deleted). #>

    if (Test-IsoFile -Path $CFG.ISOPath) {
        $size = (Get-Item -LiteralPath $CFG.ISOPath).Length
        if ($size -ge ($CFG.ISOMinSizeGB * 1GB)) {
            Write-Log "Windows ISO - OK ($(Format-Size $size)) at $($CFG.ISOPath)" 'OK'
            return
        }
        Write-Log "Windows ISO at $($CFG.ISOPath) is a valid image but only $(Format-Size $size)" 'WARN'
    }
    elseif (Test-Path -LiteralPath $CFG.ISOPath) {
        $size = (Get-Item -LiteralPath $CFG.ISOPath).Length
        Write-Log "$($CFG.ISOPath) is $(Format-Size $size) and is NOT an ISO 9660 image (no CD001 signature)." 'WARN'
        Write-Log '  This is almost always the HTML registration page returned by the evaluation download link.' 'INFO'
    }
    else {
        Write-Log "Windows ISO not found at $($CFG.ISOPath)" 'WARN'
    }

    Write-Log "Searching $($CFG.ISOSearchRoot) for a usable image..." 'INFO'
    $candidates = @(
        Get-ChildItem -LiteralPath $CFG.ISOSearchRoot -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge ($CFG.ISOMinSizeGB * 1GB) } |
            Where-Object { Test-IsoFile -Path $_.FullName } |
            Sort-Object LastWriteTime -Descending
    )

    if ($candidates.Count -eq 0) {
        Write-Log 'No valid Windows ISO found.' 'ERROR'
        Write-Log "  Download Windows 11 Enterprise (evaluation) from:" 'INFO'
        Write-Log "    $($CFG.ISODownloadPage)" 'INFO'
        Write-Log "  The download is behind a registration form and cannot be automated." 'INFO'
        Write-Log "  Save the image as: $($CFG.ISOPath)" 'INFO'
        Exit-WithError 'No valid Windows installation ISO is available.'
    }

    $chosen = $candidates[0]
    Write-Log "Using $($chosen.Name) ($(Format-Size $chosen.Length)) instead of the configured path" 'WARN'
    if ($candidates.Count -gt 1) {
        Write-Log "  Other valid images present: $(($candidates | Select-Object -Skip 1).Name -join ', ')" 'INFO'
    }
    Write-Log "  To silence this, set ISOPath to: $($chosen.FullName)" 'INFO'
    $CFG.ISOPath = $chosen.FullName
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 5 — SQL Data Disk
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase5-SQLDisk {
    Write-Log 'PHASE 5 - SQL Data Disk' 'PHASE'

    if (Test-Path -LiteralPath $CFG.SQLDiskPath) {
        # .Length is the allocated size of a dynamic VHDX, not its configured
        # capacity — the previous version reported the two as if they were the
        # same thing. Report both.
        $onDisk = (Get-Item -LiteralPath $CFG.SQLDiskPath).Length
        try {
            $vhd = Get-VHD -Path $CFG.SQLDiskPath
            Write-Log ("SQLDisk.vhdx exists - capacity {0}, currently allocated {1}, type {2}" -f `
                (Format-Size $vhd.Size), (Format-Size $onDisk), $vhd.VhdType) 'OK'
            if ($vhd.Size -lt ($CFG.SQLDiskSizeGB * 1GB)) {
                Write-Log "  Configured capacity is smaller than the requested $($CFG.SQLDiskSizeGB) GB. Expand with Resize-VHD if needed." 'WARN'
            }
        }
        catch {
            Write-Log "SQLDisk.vhdx exists ($(Format-Size $onDisk) on disk) - could not read VHD metadata: $($_.Exception.Message)" 'WARN'
        }
        Write-Log 'Existing database data preserved' 'INFO'
        return
    }

    Write-Log "Creating $($CFG.SQLDiskSizeGB) GB dynamic VHDX..." 'INFO'
    New-VHD -Path $CFG.SQLDiskPath -SizeBytes ($CFG.SQLDiskSizeGB * 1GB) -Dynamic | Out-Null
    Write-Log "SQLDisk.vhdx created at $($CFG.SQLDiskPath)" 'OK'
}

function Invoke-Phase5b-DevDrive {
    Write-Log 'PHASE 5b - Dev Drive Disk' 'PHASE'
    if (-not $CFG.UseDevDrive) {
        Write-Log 'Dev Drive disabled in config - skipping' 'INFO'
        return
    }
    New-DevDriveDisk
}
