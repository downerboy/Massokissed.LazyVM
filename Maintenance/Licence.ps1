# Licence.ps1 - part of Massokissed.LazyVM.Maintenance. Evaluation licence status, rearm and the daily maintenance run.
# Dot-sourced by Massokissed.LazyVM.Maintenance.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  WINDOWS EVALUATION LICENCE — STATUS, REARM, AND THE MAINTENANCE CYCLE
#
#  The Windows 11 Enterprise evaluation runs for 90 days. Rather than rebuild
#  every time, the maintenance run first tries slmgr's rearm, which resets the
#  evaluation timer and is supported a limited number of times. Each rearm buys
#  another full period for the price of a reboot. Only when the rearm count is
#  exhausted does the capture / rebuild / restore cycle run.
#
#  The WMI SoftwareLicensing classes are used rather than parsing slmgr.vbs
#  output, which is localised and not machine-readable.
# ─────────────────────────────────────────────────────────────────────────────
function Get-GuestLicenseStatus {
    <# Returns evaluation time remaining, licence state and rearms left. #>

    return Invoke-GuestScript -Activity 'licence status' -TimeoutMinutes 10 -ScriptBlock {
        $ErrorActionPreference = 'Stop'

        # ApplicationID below is the well-known Windows product GUID.
        $product = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
            -ErrorAction SilentlyContinue | Select-Object -First 1

        $service = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction SilentlyContinue

        $statusText = 'unknown'
        $daysLeft = -1
        $description = ''
        if ($product) {
            $statusText = switch ([int]$product.LicenseStatus) {
                0 { 'Unlicensed' }
                1 { 'Licensed' }
                2 { 'Initial grace period' }
                3 { 'Additional grace period' }
                4 { 'Non-genuine grace period' }
                5 { 'Notification' }
                6 { 'Extended grace period' }
                default { "Status $($product.LicenseStatus)" }
            }
            # GracePeriodRemaining is in minutes and is what carries the
            # evaluation countdown on an evaluation image.
            if ($null -ne $product.GracePeriodRemaining) {
                $daysLeft = [math]::Floor([int]$product.GracePeriodRemaining / 1440)
            }
            $description = "$($product.Description)"
        }

        $rearmsLeft = -1
        if ($service -and $null -ne $service.RemainingWindowsReArmCount) {
            $rearmsLeft = [int]$service.RemainingWindowsReArmCount
        }

        return [pscustomobject]@{
            Status      = $statusText
            StatusCode  = if ($product) { [int]$product.LicenseStatus } else { -1 }
            DaysLeft    = $daysLeft
            RearmsLeft  = $rearmsLeft
            Description = $description
            IsEvaluation = ($description -match '(?i)evaluation' -or $statusText -like '*grace*')
            OsCaption   = (Get-CimInstance Win32_OperatingSystem).Caption
            OsBuild     = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        }
    }
}

function Invoke-GuestRearm {
    <# Resets the evaluation timer. Requires a reboot to take effect. #>

    $result = Invoke-GuestScript -Activity 'Windows rearm' -TimeoutMinutes 10 -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $service = Get-CimInstance -ClassName SoftwareLicensingService
        $before = [int]$service.RemainingWindowsReArmCount
        if ($before -le 0) { return [pscustomobject]@{ Success = $false; Reason = 'no rearms remaining'; Before = $before } }

        $invoke = Invoke-CimMethod -InputObject $service -MethodName 'ReArmWindows'
        if ($invoke.ReturnValue -ne 0) {
            return [pscustomobject]@{ Success = $false; Reason = "ReArmWindows returned $($invoke.ReturnValue)"; Before = $before }
        }
        return [pscustomobject]@{ Success = $true; Reason = ''; Before = $before }
    }

    if (-not $result.Success) {
        Write-Log "Rearm failed: $($result.Reason)" 'WARN'
        return $false
    }

    Write-Log "Rearm accepted (had $($result.Before) remaining) - restarting the guest to apply it" 'OK'
    Restart-GuestAndWait
    return $true
}

function Restart-GuestAndWait {
    $credential = Get-GuestCredential
    Disconnect-Guest
    Restart-VM -Name $CFG.VMName -Force -Wait:$false | Out-Null
    Start-Sleep -Seconds 20
    Wait-GuestReady -Credential $credential -TimeoutMinutes 20 | Out-Null
    Connect-Guest -Credential $credential | Out-Null
}

function Show-LicenseStatus {
    <# -CheckLicense: report and do nothing else. #>
    Write-Log 'Windows Evaluation Licence Status' 'PHASE'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Exit-WithError "VM '$($CFG.VMName)' does not exist." }

    $credential = Get-GuestCredential
    if (-not $credential) { Exit-WithError 'No stored guest credential. Run with -SetupCredentials first.' }

    if ($vm.State -ne 'Running') {
        Write-Log "VM is '$($vm.State)' - starting it to read the licence" 'INFO'
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 20 | Out-Null
    }
    Connect-Guest -Credential $credential | Out-Null

    $license = Get-GuestLicenseStatus
    Write-Log "Guest OS     : $($license.OsCaption) (build $($license.OsBuild))" 'INFO'
    Write-Log "Licence      : $($license.Description)" 'INFO'
    Write-Log "Status       : $($license.Status)" 'INFO'

    if ($license.DaysLeft -ge 0) {
        $level = if ($license.DaysLeft -le $CFG.RebuildThresholdDays) { 'WARN' } else { 'OK' }
        Write-Log "Days left    : $($license.DaysLeft)" $level
    }
    else {
        Write-Log 'Days left    : not reported (this may not be an evaluation image)' 'INFO'
    }

    if ($license.RearmsLeft -ge 0) {
        $level = if ($license.RearmsLeft -eq 0) { 'WARN' } else { 'OK' }
        Write-Log "Rearms left  : $($license.RearmsLeft)" $level
        if ($license.RearmsLeft -gt 0) {
            Write-Log "  About $($license.RearmsLeft * 90) more days available without a rebuild." 'INFO'
        }
        else {
            Write-Log '  Rearms exhausted - the next expiry needs a full rebuild.' 'WARN'
        }
    }

    $state = Get-CaptureManifest
    if ($state) {
        # Older captures saved an empty database list as null, or a single name
        # as a plain string, so normalise to an array before counting.
        $capturedDatabases = @()
        if ($state.PSObject.Properties['Databases'] -and $null -ne $state.Databases) {
            $capturedDatabases = @($state.Databases)
        }
        Write-Log "Last capture : $($state.CapturedAt) ($($capturedDatabases.Count) database(s), $($state.Summary))" 'INFO'
    }
    else {
        Write-Log 'Last capture : none yet - run with -Capture to create one' 'WARN'
    }

    return $license
}

function Get-MaintenanceDecision {
    <#
      The rule that decides whether a VM gets rebuilt, kept separate from all
      the VM plumbing so it can be reasoned about and tested on its own.

        none    — plenty of time left, or no evaluation countdown at all
        rearm   — expiry is close and a rearm is available (cheap: one reboot)
        rebuild — expiry is close and rearms are exhausted
    #>
    param(
        [Parameter(Mandatory)][int]$DaysLeft,
        [Parameter(Mandatory)][int]$RearmsLeft,
        [Parameter(Mandatory)][int]$ThresholdDays
    )

    # A negative DaysLeft means the licence reports no countdown, which is what
    # a fully licensed (non-evaluation) Windows looks like. Nothing to do.
    if ($DaysLeft -lt 0) { return 'none' }
    if ($DaysLeft -gt $ThresholdDays) { return 'none' }
    if ($RearmsLeft -gt 0) { return 'rearm' }
    return 'rebuild'
}

function Invoke-Maintenance {
    <#
      The scheduled task's entry point. Runs daily: records the guest's
      tooling (see Update-ToolingRecord), then does nothing more until the
      evaluation is close to expiry, at which point it rearms, or rebuilds if
      rearms are exhausted.
    #>
    Write-Log 'Maintenance Run' 'PHASE'

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "VM '$($CFG.VMName)' does not exist - running a normal build instead" 'WARN'
        return 'build'
    }

    $credential = Get-GuestCredential
    if (-not $credential) {
        Write-Log 'No stored guest credential - cannot check the licence.' 'ERROR'
        Write-Log '  Run: .\Build-LazyVM.ps1 -SetupCredentials' 'INFO'
        return 'error'
    }

    $wasOff = ($vm.State -ne 'Running')
    if ($wasOff) {
        Write-Log 'Starting the VM to check its licence' 'INFO'
        Start-VM -Name $CFG.VMName | Out-Null
        Wait-GuestReady -Credential $credential -TimeoutMinutes 30 | Out-Null
    }
    Connect-Guest -Credential $credential | Out-Null

    # Tooling first, every day: record what is installed, taking a checkpoint
    # before adopting any change. A failure here must not stop the licence
    # work below.
    try { Update-ToolingRecord | Out-Null }
    catch { Write-LogError 'Tooling check failed (non-fatal)' $_ }

    $license = Get-GuestLicenseStatus
    Write-Log "Licence: $($license.Status); $($license.DaysLeft) day(s) left; $($license.RearmsLeft) rearm(s) remaining" 'INFO'

    $decision = Get-MaintenanceDecision -DaysLeft $license.DaysLeft `
        -RearmsLeft $license.RearmsLeft -ThresholdDays $CFG.RebuildThresholdDays

    if ($decision -eq 'none') {
        if ($license.DaysLeft -lt 0) { Write-Log 'No evaluation countdown reported - nothing to do' 'OK' }
        else { Write-Log "More than $($CFG.RebuildThresholdDays) days remain - no action needed" 'OK' }
        if ($wasOff) { Stop-GuestGracefully }
        return 'none'
    }

    Write-Log "Evaluation expires in $($license.DaysLeft) day(s) - acting now" 'WARN'

    # Always capture before doing anything, so even a rearm that goes wrong
    # leaves a usable restore point.
    Invoke-Phase9-Capture | Out-Null

    if ($decision -eq 'rearm') {
        Write-Log "Attempting rearm ($($license.RearmsLeft) remaining) - this avoids a rebuild" 'INFO'
        if (Invoke-GuestRearm) {
            $after = Get-GuestLicenseStatus
            Write-Log "Rearmed: $($after.DaysLeft) day(s) now remaining, $($after.RearmsLeft) rearm(s) left" 'OK'
            if ($wasOff) { Stop-GuestGracefully }
            return 'rearmed'
        }
        Write-Log 'Rearm did not succeed - falling through to a full rebuild' 'WARN'
    }
    else {
        Write-Log 'No rearms remaining - a full rebuild is required' 'WARN'
    }

    return 'rebuild'
}

function Stop-GuestGracefully {
    param([int]$TimeoutMinutes = 10)

    Disconnect-Guest
    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -eq 'Off') { return }

    Write-Log 'Shutting the guest down...' 'INFO'
    Stop-VM -Name $CFG.VMName -Force:$false -ErrorAction SilentlyContinue | Out-Null

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -eq 'Off') {
            Write-Log 'Guest is off' 'OK'
            return
        }
        Start-Sleep -Seconds 10
    }

    Write-Log "Guest did not shut down within $TimeoutMinutes minutes - forcing it off" 'WARN'
    Stop-VM -Name $CFG.VMName -TurnOff -Force | Out-Null
}
