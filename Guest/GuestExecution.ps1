# GuestExecution.ps1 - part of Massokissed.LazyVM.Guest. PowerShell Direct session, guest command execution and file transfer.
# Dot-sourced by Massokissed.LazyVM.Guest.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  GUEST EXECUTION
#
#  Every guest call goes through a persistent PowerShell Direct session opened
#  with an explicit credential, and long-running work runs as a job so it can
#  be given a real timeout instead of blocking forever.
# ─────────────────────────────────────────────────────────────────────────────
function Connect-Guest {
    param(
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 5
    )

    if ($script:GuestSession -and $script:GuestSession.State -eq 'Opened') {
        return $script:GuestSession
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $script:GuestSession = New-PSSession -VMName $CFG.VMName -Credential $Credential -ErrorAction Stop
            return $script:GuestSession
        }
        catch {
            $lastError = $_
            Start-Sleep -Seconds 10
        }
    }

    if ($lastError) { Write-LogError 'PowerShell Direct connection failed' $lastError }
    Exit-WithError "Could not open a PowerShell Direct session to '$($CFG.VMName)' as '$($Credential.UserName)'. Check the guest account and password, and that the guest is past OOBE."
}

function Disconnect-Guest {
    if ($script:GuestSession) {
        Remove-PSSession -Session $script:GuestSession -ErrorAction SilentlyContinue
        $script:GuestSession = $null
    }
}

function Invoke-GuestScript {
    <# Runs a scriptblock in the guest with a timeout. Throws on failure so
       callers cannot mistake an error for success — the previous version
       discarded exit codes and logged "install complete" unconditionally. #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutMinutes = 15,
        [string]$Activity = 'guest command'
    )

    $session = $script:GuestSession
    if (-not $session -or $session.State -ne 'Opened') {
        Exit-WithError "No open guest session for: $Activity"
    }

    $job = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob
    try {
        $finished = Wait-Job -Job $job -Timeout ($TimeoutMinutes * 60)
        if (-not $finished) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "$Activity did not finish within $TimeoutMinutes minutes"
        }

        $result = Receive-Job -Job $job -ErrorAction Stop
        if ($job.State -eq 'Failed') {
            $reason = if ($job.ChildJobs -and $job.ChildJobs[0].JobStateInfo.Reason) {
                $job.ChildJobs[0].JobStateInfo.Reason.Message
            }
            else { 'unknown error' }
            throw "$Activity failed in guest: $reason"
        }
        return $result
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GuestScriptAsInteractiveUser {
    <#
      Some guest work only makes sense in the logged-on user's session:
      Visual Studio settings are per-user, and a PowerShell Direct session is
      not the desktop session.

      This writes a script into the guest and runs it through a one-shot
      scheduled task with LogonType Interactive, which autologon guarantees is
      available.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][string]$TaskName,
        [int]$TimeoutMinutes = 20,
        [string]$Activity = 'interactive guest command'
    )

    $guestUser = $CFG.GuestAdminUser
    $setupDir = $CFG.GuestSetupDir

    # The task runs under the user's normal (Limited) token, the same context
    # the user's own Visual Studio runs in, so per-user settings land where
    # that Visual Studio will read them.
    Invoke-GuestScript -TimeoutMinutes $TimeoutMinutes -Activity $Activity -ArgumentList @(
        $ScriptText, $TaskName, $guestUser, $setupDir, ($TimeoutMinutes * 60), 'Limited'
    ) -ScriptBlock {
        param($scriptText, $taskName, $userName, $setupDir, $timeoutSeconds, $runLevel)

        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

        $scriptPath = Join-Path $setupDir "$taskName.ps1"
        $flagPath = Join-Path $setupDir "$taskName.done"
        Remove-Item $flagPath -Force -ErrorAction SilentlyContinue

        # The script signals completion with a flag file: scheduled task result
        # codes do not distinguish "script failed" from "task could not start".
        $wrapped = @"
`$ErrorActionPreference = 'Continue'
`$transcript = '$setupDir\$taskName.log'
Start-Transcript -Path `$transcript -Force | Out-Null
try {
$scriptText
    'OK' | Set-Content -Path '$flagPath'
}
catch {
    "FAILED: `$(`$_.Exception.Message)" | Set-Content -Path '$flagPath'
}
finally { Stop-Transcript | Out-Null }
"@
        Set-Content -Path $scriptPath -Value $wrapped -Encoding UTF8

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(15))
        $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel $runLevel
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $timeoutSeconds) -StartWhenAvailable

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddSeconds($timeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path $flagPath) { break }
            Start-Sleep -Seconds 5
        }

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        if (-not (Test-Path $flagPath)) {
            throw "interactive task '$taskName' did not complete within $timeoutSeconds seconds (is a user logged on?)"
        }
        $status = (Get-Content $flagPath -Raw).Trim()
        if ($status -ne 'OK') { throw $status }
        return $status
    }
}

function Wait-GuestReady {
    <# Waits for Windows Setup, OOBE and first logon to finish. #>
    param(
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = $false

    Write-Log "Waiting up to $TimeoutMinutes minutes for the guest to finish installing and reach the desktop..." 'INFO'

    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
        if (-not $vm) { Exit-WithError "VM '$($CFG.VMName)' disappeared while waiting." }
        if ($vm.State -ne 'Running') {
            Write-Log "VM state is '$($vm.State)' - starting it" 'INFO'
            Start-VM -Name $CFG.VMName -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 20
            continue
        }

        # Heartbeat first: cheap, and it tells us the OS is actually up.
        $heartbeat = Get-VMIntegrationService -VMName $CFG.VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if (-not $heartbeat -or $heartbeat.PrimaryStatusDescription -ne 'OK') {
            if (-not $announced) {
                Write-Log '  guest is still installing (no heartbeat yet)' 'INFO'
                $announced = $true
            }
            Start-Sleep -Seconds 30
            continue
        }

        try {
            $session = New-PSSession -VMName $CFG.VMName -Credential $Credential -ErrorAction Stop
            try {
                $provisioned = Invoke-Command -Session $session -ScriptBlock {
                    # FirstLogonCommands sets this; without the answer-file disc it
                    # will be absent, in which case a usable session is enough.
                    $key = 'HKLM:\SOFTWARE\LazyVM'
                    if (Test-Path $key) {
                        $v = Get-ItemProperty -Path $key -Name 'Provisioned' -ErrorAction SilentlyContinue
                        if ($v -and $v.Provisioned -eq 1) { return $true }
                    }
                    return $false
                }
            }
            finally {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }

            $elapsed = [int]((Get-Date) - $deadline.AddMinutes(-$TimeoutMinutes)).TotalMinutes
            if ($provisioned) {
                Write-Log "Guest is provisioned and reachable (after $elapsed min)" 'OK'
            }
            else {
                Write-Log "Guest is reachable over PowerShell Direct (after $elapsed min); no provisioning marker - continuing" 'OK'
            }
            return $true
        }
        catch {
            Start-Sleep -Seconds 20
        }
    }

    Exit-WithError "The guest did not become reachable within $TimeoutMinutes minutes. Open the VM console to see where Setup stopped."
}

function Copy-FromGuest {
    <# Pulls one file out of the guest. Copy-VMFile cannot do this direction. #>
    param(
        [Parameter(Mandatory)][string]$GuestPath,
        [Parameter(Mandatory)][string]$HostPath
    )
    $session = $script:GuestSession
    if (-not $session -or $session.State -ne 'Opened') { throw 'no open guest session' }
    $parent = Split-Path -Path $HostPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -Path $GuestPath -Destination $HostPath -FromSession $session -Force -ErrorAction Stop
}

function Copy-ToGuest {
    param(
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$GuestPath
    )
    $session = $script:GuestSession
    if (-not $session -or $session.State -ne 'Opened') { throw 'no open guest session' }
    Invoke-GuestScript -Activity 'prepare destination' -TimeoutMinutes 5 -ArgumentList @((Split-Path $GuestPath -Parent)) -ScriptBlock {
        param($dir)
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } | Out-Null
    Copy-Item -Path $HostPath -Destination $GuestPath -ToSession $session -Force -ErrorAction Stop
}

function Get-GuestSqlServer {
    <# The guest-side SQL connection target: localhost, or localhost\<instance>. #>
    return $script:GuestSqlServer
}

function Set-GuestSqlServer {
    <# Records the guest's SQL instance once it is known, as the connection target for later SQL work. #>
    param([Parameter(Mandatory)][string]$Instance)
    $script:GuestSqlServer = if ($Instance -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$Instance" }
}
