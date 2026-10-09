# Schedule.ps1 - part of Massokissed.LazyVM.Maintenance. Daily maintenance scheduled task (-RegisterSchedule).
# Dot-sourced by Massokissed.LazyVM.Maintenance.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  90-DAY REBUILD SCHEDULED TASK  (-RegisterSchedule)
# ─────────────────────────────────────────────────────────────────────────────
function Register-RebuildSchedule {
    Write-Log "Daily Maintenance Schedule - $($CFG.VMName)" 'PHASE'

    if (-not $CFG.ScriptPath) {
        Write-Log 'Cannot register the schedule: the script path is unknown (run the script with -File).' 'WARN'
        return
    }

    # Refuse to schedule an unattended run that cannot possibly authenticate.
    if (-not (Get-StoredCredential -Path $CFG.GuestCredFile)) {
        Write-Log 'Cannot register the schedule: no guest credential is stored.' 'WARN'
        Write-Log '  Run .\Build-LazyVM.ps1 -SetupCredentials first.' 'INFO'
        return
    }

    # The time of day comes from the VM's MaintenanceTime, so each VM on the
    # host is maintained at its own time.
    [datetime]$time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($CFG.MaintenanceTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$time)) {
        Write-Log "Cannot register the schedule: MaintenanceTime '$($CFG.MaintenanceTime)' is not a 24-hour time such as 02:00." 'WARN'
        return
    }

    # Runs DAILY rather than every 90 days, and -Maintain does nothing until
    # the evaluation is within RebuildThresholdDays of expiring. A task that
    # fired exactly every 90 days would drift past the expiry date, and would
    # miss it entirely if the host happened to be off that day.
    $nextRun = (Get-Date).Date.AddDays(1).Add($time.TimeOfDay)

    # The VM and the root folder are written into the task, so an unattended
    # run always maintains this VM in this location. Registering again
    # replaces the task, which is how an existing one is updated.
    $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval 1 -At $nextRun
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -VM "{1}" -Root "{2}" -Maintain -Force' -f $CFG.ScriptPath, $CFG.VMName, $CFG.Root
    )
    $settings = New-ScheduledTaskSettingsSet `
        -WakeToRun `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
        -RestartCount 2 `
        -RestartInterval (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $CFG.ScheduleTaskName -Trigger $trigger -Action $action `
        -Settings $settings -Principal $principal -Force | Out-Null

    Write-Log "Scheduled task '$($CFG.ScheduleTaskName)' registered for VM '$($CFG.VMName)' - daily at $($CFG.MaintenanceTime), first run $($nextRun.ToString('yyyy-MM-dd HH:mm'))" 'OK'
    Write-Log '  Runs daily as SYSTEM and does nothing until the evaluation is within' 'INFO'
    Write-Log "  $($CFG.RebuildThresholdDays) days of expiry. It then captures state and rearms Windows;" 'INFO'
    Write-Log '  only when rearms are exhausted does it capture, rebuild and restore.' 'INFO'
}
