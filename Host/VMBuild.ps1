# VMBuild.ps1 - part of Massokissed.LazyVM.Host. Phase 6: VM build, TPM, virtual switch.
# Dot-sourced by Massokissed.LazyVM.Host.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 6 — VM Build
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Phase6-VMBuild {
    param([switch]$UseUnattend)

    Write-Log 'PHASE 6 - VM Build' 'PHASE'

    if (-not (Test-HyperVModule)) {
        Exit-WithError 'The Hyper-V PowerShell module is not available. Enable Microsoft-Hyper-V-Management-PowerShell (Phase 2) and re-run.'
    }

    $switchName = Resolve-VMSwitch

    $existing = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "VM '$($CFG.VMName)' already exists (State: $($existing.State)) - skipping creation" 'INFO'
        Write-Log "To rebuild: Remove-VM -Name $($CFG.VMName) -Force, then delete $($CFG.VHDXRoot)\$($CFG.VMName)-OS.vhdx" 'INFO'
        return
    }

    $osDiskPath = Join-Path $CFG.VHDXRoot "$($CFG.VMName)-OS.vhdx"

    # The previous version called New-VHD unconditionally, which throws if the
    # file already exists — the common case after deleting a VM in Hyper-V
    # Manager, which leaves its disks behind. Reuse rather than fail; the user
    # deletes the file if they want a genuinely fresh disk.
    $reusingDisk = $false
    if (Test-Path -LiteralPath $osDiskPath) {
        $reusingDisk = $true
        $onDisk = (Get-Item -LiteralPath $osDiskPath).Length
        Write-Log "OS VHDX already exists ($(Format-Size $onDisk) allocated) - reusing it" 'WARN'
        Write-Log "  Delete $osDiskPath first if you want a clean install." 'INFO'
    }
    else {
        Write-Log "Creating OS VHDX: $osDiskPath ($($CFG.OSDiskSizeGB) GB dynamic)" 'INFO'
        New-VHD -Path $osDiskPath -SizeBytes ($CFG.OSDiskSizeGB * 1GB) -Dynamic | Out-Null
    }

    Write-Log "Creating VM '$($CFG.VMName)' (Generation 2) on switch '$switchName'..." 'INFO'
    New-VM -Name $CFG.VMName `
        -Generation 2 `
        -VHDPath $osDiskPath `
        -Path $CFG.VHDXRoot `
        -SwitchName $switchName | Out-Null

    Set-VMProcessor -VMName $CFG.VMName -Count $CFG.vCPU
    Write-Log "vCPUs: $($CFG.vCPU)" 'OK'

    Set-VMMemory -VMName $CFG.VMName `
        -DynamicMemoryEnabled $true `
        -MinimumBytes ([long]$CFG.MemMinGB * 1GB) `
        -StartupBytes ([long]$CFG.MemStartGB * 1GB) `
        -MaximumBytes ([long]$CFG.MemMaxGB * 1GB) `
        -Priority 80
    Write-Log "Dynamic Memory: min $($CFG.MemMinGB) GB / startup $($CFG.MemStartGB) GB / max $($CFG.MemMaxGB) GB" 'OK'

    Set-VMFirmware -VMName $CFG.VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
    Write-Log 'Secure Boot: enabled (MicrosoftWindows template)' 'OK'

    Enable-VMTpm-Checked -VMName $CFG.VMName

    Add-VMDvdDrive -VMName $CFG.VMName -Path $CFG.ISOPath
    Write-Log "ISO attached: $($CFG.ISOPath)" 'OK'

    if ($UseUnattend) {
        # SCSI location 1. The OS disk stays at location 0 so the answer file's
        # DiskID 0 always targets the right disk. The SQL data disk is attached
        # later, in Phase 7, so Windows Setup never sees it.
        Add-VMHardDiskDrive -VMName $CFG.VMName -Path $CFG.SeedDiskPath -ControllerType SCSI
        Write-Log 'Unattend seed disk attached' 'OK'
    }

    $dvd = Get-VMDvdDrive -VMName $CFG.VMName
    $vhd = @(Get-VMHardDiskDrive -VMName $CFG.VMName | Where-Object { $_.Path -eq $osDiskPath })[0]
    $nic = Get-VMNetworkAdapter -VMName $CFG.VMName
    Set-VMFirmware -VMName $CFG.VMName -BootOrder $dvd, $vhd, $nic
    Write-Log 'Boot order: DVD -> VHD -> NIC' 'OK'

    # Integration services, verified rather than assumed.
    $wanted = 'Guest Service Interface', 'Heartbeat', 'Key-Value Pair Exchange', 'Shutdown', 'Time Synchronization', 'VSS'
    $failed = @()
    foreach ($name in $wanted) {
        try {
            Enable-VMIntegrationService -VMName $CFG.VMName -Name $name -ErrorAction Stop
            $svc = Get-VMIntegrationService -VMName $CFG.VMName -Name $name
            if (-not $svc.Enabled) { $failed += $name }
        }
        catch { $failed += "$name ($($_.Exception.Message))" }
    }
    if ($failed.Count -gt 0) {
        Write-Log "Integration services NOT enabled: $($failed -join ', ')" 'WARN'
        Write-Log '  Copy-VMFile needs Guest Service Interface; Phase 7 will fail without it.' 'WARN'
    }
    else {
        Write-Log "Integration services enabled: $($wanted -join ', ')" 'OK'
    }

    # AutomaticCheckpointsEnabled (not CheckpointType Disabled) so manual
    # checkpoints remain available; they are stored in CheckpointDir,
    # which the folder layout already provisions but nothing previously used.
    Set-VM -VMName $CFG.VMName -AutomaticCheckpointsEnabled $false
    if (Test-Path -LiteralPath $CFG.CheckpointDir) {
        Set-VM -VMName $CFG.VMName -SnapshotFileLocation $CFG.CheckpointDir
    }
    Write-Log "Automatic checkpoints disabled; manual checkpoints -> $($CFG.CheckpointDir)" 'OK'

    $note = "LazyVM | Built $(Get-Date -Format 'yyyy-MM-dd') | guest admin: $($CFG.GuestAdminUser)"
    if ($reusingDisk) { $note += ' | reused existing OS VHDX' }
    Set-VM -VMName $CFG.VMName -Notes $note

    Write-Log "VM '$($CFG.VMName)' built" 'OK'
}

function Enable-VMTpm-Checked {
    param([Parameter(Mandatory)][string]$VMName)

    try {
        $guardian = Get-HgsGuardian -Name 'UntrustedGuardian' -ErrorAction SilentlyContinue
        if (-not $guardian) {
            Write-Log 'Creating HGS guardian for vTPM...' 'INFO'
            $guardian = New-HgsGuardian -Name 'UntrustedGuardian' -GenerateCertificates
        }
        $protector = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot
        Set-VMKeyProtector -VMName $VMName -KeyProtector $protector.RawData
        Enable-VMTPM -VMName $VMName -ErrorAction Stop

        # Verified, not assumed. The previous version swallowed failures with
        # -ErrorAction SilentlyContinue and logged "TPM: Enabled" regardless.
        if ((Get-VMSecurity -VMName $VMName).TpmEnabled) {
            Write-Log 'vTPM: enabled' 'OK'
        }
        else {
            Write-Log 'vTPM: Enable-VMTPM reported success but the VM still shows TpmEnabled = False' 'WARN'
        }
    }
    catch {
        Write-LogError 'vTPM could not be enabled' $_
        Write-Log '  Windows 11 Setup requires a TPM. Install will fail without it.' 'WARN'
    }
}

function Resolve-VMSwitch {
    <#
      New-VMSwitch has no 'NAT' switch type — it accepts Internal, Private or
      External only, so the previous `-SwitchType NAT` would have thrown. And
      'Default Switch' is a system-owned switch that cannot be recreated under
      that name. If the configured switch is missing, an Internal switch plus a
      New-NetNat network is created instead.
    #>

    $existing = Get-VMSwitch -Name $CFG.SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Switch '$($CFG.SwitchName)' - OK ($($existing.SwitchType))" 'OK'
        return $CFG.SwitchName
    }

    Write-Log "Switch '$($CFG.SwitchName)' not found" 'WARN'

    $nat = Get-VMSwitch -Name $CFG.NatSwitchName -ErrorAction SilentlyContinue
    if (-not $nat) {
        Write-Log "Creating internal switch '$($CFG.NatSwitchName)' with a NAT network..." 'INFO'
        $nat = New-VMSwitch -Name $CFG.NatSwitchName -SwitchType Internal
    }

    $alias = "vEthernet ($($CFG.NatSwitchName))"
    $prefixLength = [int]($CFG.NatSubnet -split '/')[1]

    $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $CFG.NatHostIP }
    if (-not $ip) {
        New-NetIPAddress -IPAddress $CFG.NatHostIP -PrefixLength $prefixLength -InterfaceAlias $alias -ErrorAction Stop | Out-Null
        Write-Log "Host gateway $($CFG.NatHostIP)/$prefixLength assigned to '$alias'" 'OK'
    }

    $natNet = Get-NetNat -ErrorAction SilentlyContinue |
        Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $CFG.NatSubnet }
    if (-not $natNet) {
        New-NetNat -Name "$($CFG.NatSwitchName)-NAT" -InternalIPInterfaceAddressPrefix $CFG.NatSubnet -ErrorAction Stop | Out-Null
        Write-Log "NAT network created for $($CFG.NatSubnet)" 'OK'
    }

    Write-Log "Note: this NAT network has no DHCP server. Set a static address inside the guest," 'WARN'
    Write-Log "      or switch $($CFG.VMName) back to 'Default Switch' once it is available." 'WARN'

    $CFG.SwitchName = $CFG.NatSwitchName
    return $CFG.NatSwitchName
}
