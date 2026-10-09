# DevDrive.ps1 - part of Massokissed.LazyVM.DevDrive. Dev Drive disk creation and guest setup.
# Dot-sourced by Massokissed.LazyVM.DevDrive.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  DEV DRIVE
#
#  A Dev Drive is not a distinct kind of disk: it is a ReFS volume carrying a
#  per-machine "trusted" designation, which tells Filter Manager to detach
#  everything except antivirus. That is where the build speed comes from.
#
#  Two consequences shape the code below:
#
#    * The designation is per MACHINE, not per volume, so it does not survive
#      into a rebuilt guest. Re-trusting is a metadata operation and does NOT
#      reformat, so the data is safe — but it has to happen every rebuild.
#    * Microsoft documents Dev Drive as unsupported on removable or
#      hot-pluggable disks. A Hyper-V SCSI disk normally presents as fixed, but
#      rather than assume, the guest code attempts the designation and falls
#      back to a plain NTFS volume if it is refused. A slower drive is a far
#      better outcome than a failed build.
# ─────────────────────────────────────────────────────────────────────────────
function New-DevDriveDisk {
    <# Creates the backing VHDX on the host. Never overwrites an existing one:
       this disk carries the working source across rebuilds. #>
    if (-not $CFG.UseDevDrive) { return }

    if (Test-Path -LiteralPath $CFG.DevDrivePath) {
        $onDisk = (Get-Item -LiteralPath $CFG.DevDrivePath).Length
        try {
            $vhd = Get-VHD -Path $CFG.DevDrivePath
            Write-Log ("Dev Drive disk exists - capacity {0}, currently allocated {1}" -f `
                (Format-Size $vhd.Size), (Format-Size $onDisk)) 'OK'
        }
        catch {
            Write-Log "Dev Drive disk exists ($(Format-Size $onDisk) on disk)" 'OK'
        }
        Write-Log 'Existing Dev Drive contents preserved' 'INFO'
        return
    }

    if ($CFG.DevDriveSizeGB -lt 50) {
        Exit-WithError "DevDriveSizeGB is $($CFG.DevDriveSizeGB); Dev Drive requires at least 50 GB."
    }

    $parent = Split-Path -Path $CFG.DevDrivePath -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Log "Creating $($CFG.DevDriveSizeGB) GB dynamic Dev Drive disk..." 'INFO'
    New-VHD -Path $CFG.DevDrivePath -SizeBytes ([long]$CFG.DevDriveSizeGB * 1GB) -Dynamic | Out-Null
    Write-Log "Dev Drive disk created at $($CFG.DevDrivePath)" 'OK'
}

function Add-DevDriveDisk {
    if (-not $CFG.UseDevDrive) { return }
    if (-not (Test-Path -LiteralPath $CFG.DevDrivePath)) {
        Write-Log "Dev Drive disk not found at $($CFG.DevDrivePath) - skipping attach" 'WARN'
        return
    }

    $attached = @(Get-VMHardDiskDrive -VMName $CFG.VMName -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $CFG.DevDrivePath })
    if ($attached.Count -gt 0) {
        Write-Log 'Dev Drive disk already attached' 'OK'
        return
    }

    Add-VMHardDiskDrive -VMName $CFG.VMName -Path $CFG.DevDrivePath -ControllerType SCSI
    Write-Log 'Dev Drive disk attached (SCSI)' 'OK'
    Start-Sleep -Seconds 5
}

function Initialize-GuestDevDrive {
    <#
      Prepares the volume in the guest and designates it as a trusted Dev
      Drive. Idempotent: on a re-run it finds the existing volume by label and
      only re-applies the trust designation, which is what a rebuilt guest
      needs.
    #>
    if (-not $CFG.UseDevDrive) { return }

    Write-Log 'Preparing the Dev Drive inside the guest...' 'INFO'

    $result = Invoke-GuestScript -Activity 'Dev Drive preparation' -TimeoutMinutes 30 -ArgumentList @(
        $CFG.DevDriveLetter, $CFG.DevDriveSizeGB, $CFG.DevDriveLabel, ($CFG.DevDriveFilters -join ', ')
    ) -ScriptBlock {
        param($desiredLetter, $expectedSizeGB, $label, $filters)
        $ErrorActionPreference = 'Stop'
        $notes = @()

        function Get-VolumeByLetter([string]$letter) {
            return Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='${letter}:'" -ErrorAction SilentlyContinue
        }
        function Get-FreeLetter {
            foreach ($c in 'Z', 'Y', 'X', 'V', 'U', 'T', 'S', 'R', 'Q') {
                if (-not (Get-VolumeByLetter $c)) { return $c }
            }
            return $null
        }

        # Dev Drive support is a system-level switch and a new guest has it off.
        $enableOut = & fsutil devdrv enable 2>&1
        if ($LASTEXITCODE -ne 0) {
            $notes += "fsutil devdrv enable returned $LASTEXITCODE ($($enableOut -join ' '))"
        }

        # Already prepared? Find it by label first; that survives a rebuild,
        # where the volume is intact but no longer designated.
        $existing = @(Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.FileSystemLabel -eq $label -and $_.DriveLetter })
        $letter = $null
        $formatted = $false
        $fileSystem = ''

        if ($existing.Count -gt 0) {
            $letter = "$($existing[0].DriveLetter)"
            $fileSystem = "$($existing[0].FileSystem)"
            $notes += "found an existing '$label' volume at ${letter}:"

            if ($letter -ne $desiredLetter -and -not (Get-VolumeByLetter $desiredLetter)) {
                $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
                if ($part) {
                    Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter $desiredLetter
                    $letter = $desiredLetter
                    $notes += "moved it to ${desiredLetter}:"
                }
            }
        }
        else {
            # Pick the unused disk closest to the configured size. The SQL data
            # disk is a different size, so this cannot pick the wrong one.
            $expectedBytes = [int64]$expectedSizeGB * 1GB
            $candidates = @(Get-Disk | Where-Object {
                    -not $_.IsBoot -and -not $_.IsSystem -and
                    ($_.PartitionStyle -eq 'RAW' -or
                        @(Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                            Where-Object { $_.DriveLetter }).Count -eq 0)
                })
            if ($candidates.Count -eq 0) { throw 'no unused disk found in the guest for the Dev Drive' }

            $disk = $candidates | Sort-Object { [math]::Abs($_.Size - $expectedBytes) } | Select-Object -First 1
            if ([math]::Abs($disk.Size - $expectedBytes) -gt (20GB)) {
                $notes += "closest unused disk is $([math]::Round($disk.Size/1GB)) GB, expected about $expectedSizeGB GB - check the disk layout"
            }

            if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
            if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
            $disk = Get-Disk -Number $disk.Number

            if ($disk.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
            }

            $target = if (Get-VolumeByLetter $desiredLetter) { Get-FreeLetter } else { $desiredLetter }
            if (-not $target) { throw 'no free drive letter available for the Dev Drive' }

            $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $target
            $letter = $target

            # Dev Drive first. -DevDrive implies ReFS; it is refused on a disk
            # the system considers removable, so fall back rather than fail.
            try {
                Format-Volume -DriveLetter $letter -DevDrive -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
                $fileSystem = 'ReFS'
            }
            catch {
                $notes += "DEV DRIVE FORMAT REFUSED: $($_.Exception.Message)"
                $notes += 'falling back to NTFS - the volume still works and still persists, just without Dev Drive acceleration'
                Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
                $fileSystem = 'NTFS'
            }
            $formatted = $true
        }

        if (-not $letter) { throw 'the Dev Drive volume could not be assigned a drive letter' }

        # Trust: required after every rebuild, and a metadata change only.
        $trusted = $false
        if ($fileSystem -eq 'ReFS') {
            # A non-zero exit here is usually just "the volume is in use, the
            # change applies on next mount", which is benign when the volume
            # was designated at format time. The query below is what decides,
            # so only record this if the query disagrees.
            $trustOut = & fsutil devdrv trust "${letter}:" 2>&1
            $trustExit = $LASTEXITCODE

            if ($filters) {
                $filterOut = & fsutil devdrv setfiltersallowed /volume "${letter}:" $filters 2>&1
                if ($LASTEXITCODE -ne 0) { $notes += "setfiltersallowed returned $LASTEXITCODE ($($filterOut -join ' '))" }
                else { $notes += "allowed filters set: $filters" }
            }

            $query = & fsutil devdrv query "${letter}:" 2>&1
            $trusted = (($query -join ' ') -match '(?i)trusted developer volume')
            if (-not $trusted) {
                if ($trustExit -ne 0) { $notes += "fsutil devdrv trust returned $trustExit ($($trustOut -join ' '))" }
                $notes += "query says: $(($query -join ' ').Trim())"
            }
        }

        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Letter     = $letter
            FileSystem = $fileSystem
            Trusted    = $trusted
            Formatted  = $formatted
            SizeGB     = if ($volume) { [math]::Round($volume.Size / 1GB, 1) } else { 0 }
            FreeGB     = if ($volume) { [math]::Round($volume.SizeRemaining / 1GB, 1) } else { 0 }
            Notes      = $notes
        }
    }

    foreach ($note in @($result.Notes)) {
        if ($note -like 'DEV DRIVE FORMAT REFUSED*') { Write-Log "  $note" 'ERROR' }
        elseif ($note -like 'falling back*' -or $note -like '*returned*') { Write-Log "  $note" 'WARN' }
        else { Write-Log "  $note" 'INFO' }
    }

    $CFG.DevDriveLetter = $result.Letter

    if ($result.Trusted) {
        Write-Log "Dev Drive ready at $($result.Letter): - trusted ReFS, $($result.FreeGB) GB free of $($result.SizeGB) GB" 'OK'
        Write-Log '  Defender performance mode and ReFS block cloning are active on this volume.' 'INFO'
    }
    elseif ($result.FileSystem -eq 'ReFS') {
        Write-Log "Volume at $($result.Letter): is ReFS but NOT trusted - it works, without the Dev Drive speedups" 'WARN'
        Write-Log "  Try by hand:  fsutil devdrv enable   then   fsutil devdrv trust $($result.Letter):" 'INFO'
    }
    else {
        Write-Log "Volume at $($result.Letter): is NTFS - Dev Drive was not available on this disk" 'WARN'
        Write-Log '  It still persists across rebuilds; only the ReFS acceleration is missing.' 'INFO'
    }
    return $result
}

function Enable-GuestEnhancedSession {
    <#
      Enhanced Session Mode carries clipboard and drive redirection over the
      VMBus using RDP, NOT over the VM's network: no address, no account and no
      firewall rule, so nothing that can drift.

      Needs the host switched on, the VM's transport set, and Remote Desktop
      Services enabled in the guest.
    #>
    if (-not $CFG.EnableEnhancedSession) { return }

    try {
        if (-not (Get-VMHost).EnableEnhancedSessionMode) {
            Set-VMHost -EnableEnhancedSessionMode $true
            Write-Log 'Enhanced session mode enabled on the Hyper-V host' 'OK'
        }
        Set-VM -VMName $CFG.VMName -EnhancedSessionTransportType HvSocket -ErrorAction Stop
        Write-Log 'VM enhanced session transport set to HvSocket (VMBus)' 'OK'
    }
    catch {
        Write-Log "Could not configure enhanced session mode on the host: $($_.Exception.Message)" 'WARN'
        return
    }

    try {
        $report = Invoke-GuestScript -Activity 'enable Remote Desktop in guest' -TimeoutMinutes 10 -ScriptBlock {
            $ErrorActionPreference = 'Continue'
            $log = @()

            $ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
            $current = (Get-ItemProperty -Path $ts -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
            if ($current -ne 0) {
                Set-ItemProperty -Path $ts -Name 'fDenyTSConnections' -Value 0 -Type DWord
                $log += 'Remote Desktop Services enabled'
            }
            else { $log += 'Remote Desktop Services already enabled' }

            try {
                Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
                $log += 'Remote Desktop firewall rules enabled'
            }
            catch { $log += "firewall rules: $($_.Exception.Message)" }

            # Drive redirection is what makes host folders appear in the guest.
            # A policy of 1 here silently disables copy/paste of files.
            $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
            if (Test-Path $policy) {
                foreach ($name in 'fDisableCdm', 'fDisableClip') {
                    $value = (Get-ItemProperty -Path $policy -Name $name -ErrorAction SilentlyContinue).$name
                    if ($value -eq 1) {
                        Remove-ItemProperty -Path $policy -Name $name -ErrorAction SilentlyContinue
                        $log += "cleared policy $name, which was blocking redirection"
                    }
                }
            }
            return $log
        }
        foreach ($line in @($report)) { Write-Log "  $line" 'OK' }
        Write-Log '  In VMConnect: Show Options > Local Resources > More > Drives to share host drives.' 'INFO'
    }
    catch {
        Write-LogError 'Could not enable Remote Desktop in the guest (non-fatal)' $_
    }
}
