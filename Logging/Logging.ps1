# Logging.ps1 - part of Massokissed.LazyVM.Logging. Logging to console and log file.
# Dot-sourced by Massokissed.LazyVM.Logging.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────────────────────
function Get-LogEncoding {
    <#
      Created on first use rather than depending on assignment order, so the
      logger works even if these functions are loaded without the script body.

      Get-Variable rather than reading $script:LogEncoding directly: under
      StrictMode, reading a variable that was never assigned is a terminating
      error, which would defeat the point of initialising it lazily.
    #>
    $existing = Get-Variable -Name 'LogEncoding' -Scope Script -ErrorAction SilentlyContinue
    if (-not $existing -or -not $existing.Value) {
        $script:LogEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    return $script:LogEncoding
}

function Initialize-Log {
    if ($script:LogReady) { return }
    $dir = Split-Path -Path $CFG.LogFile -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $stem = [IO.Path]::Combine($dir, [IO.Path]::GetFileNameWithoutExtension($CFG.LogFile))
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    if (Test-Path -LiteralPath $CFG.LogFile) {
        # Rotate so the log cannot grow without bound across 90-day rebuilds.
        $sizeMB = (Get-Item -LiteralPath $CFG.LogFile).Length / 1MB
        if ($sizeMB -gt $CFG.LogMaxSizeMB) {
            Move-Item -LiteralPath $CFG.LogFile -Destination ('{0}.{1}.log' -f $stem, $stamp) -Force
        }
        else {
            # A log written by both Windows PowerShell 5.1 (ANSI) and
            # PowerShell 7 (UTF-8) holds two encodings at once and renders as
            # mojibake from end to end. Detect it by strict-decoding, and set
            # the mixed file aside once so the new one starts clean. Renamed,
            # never deleted.
            try {
                $bytes = [IO.File]::ReadAllBytes($CFG.LogFile)
                if ($bytes.Length -gt 0) {
                    $strict = New-Object System.Text.UTF8Encoding($false, $true)
                    try { [void]$strict.GetString($bytes) }
                    catch {
                        $archive = '{0}.mixed-encoding-{1}.log' -f $stem, $stamp
                        Move-Item -LiteralPath $CFG.LogFile -Destination $archive -Force
                        Write-Host "  [!] Previous log had mixed ANSI/UTF-8 encoding; moved to $archive" -ForegroundColor Yellow
                    }
                }
            }
            catch {
                # Locked, or unreadable for any other reason. Not worth failing
                # a build over, and the append below will report it properly.
                Write-Host "  [ ] (could not check the existing log encoding: $($_.Exception.Message))" -ForegroundColor DarkGray
            }
        }
    }
    $script:LogReady = $true
}

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',

        # Position 1 must be explicit: declaring a Position on ANY parameter
        # removes the automatic positions from all the others, so without this
        # every Write-Log 'text' 'OK' call fails with "a positional parameter
        # cannot be found that accepts argument 'OK'".
        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'PHASE')]
        [string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Level) {
        'PHASE' { $prefix = "`n====== "; $color = 'Cyan' }
        'OK' { $prefix = '  [+] '; $color = 'Green' }
        'WARN' { $prefix = '  [!] '; $color = 'Yellow' }
        'ERROR' { $prefix = '  [X] '; $color = 'Red' }
        default { $prefix = '  [ ] '; $color = 'Gray' }
    }

    $line = "$ts$prefix$Message"
    Write-Host $line -ForegroundColor $color

    # The logger must never throw: it runs inside catch blocks, and an
    # exception here would mask the error actually being reported.
    try {
        Initialize-Log

        # Explicit encoding, NOT Add-Content. Add-Content has no fixed default:
        # Windows PowerShell 5.1 writes the ANSI code page, PowerShell 7 writes
        # UTF-8. A log appended to by both ends up with two encodings in one
        # file, and any character the ANSI page cannot represent is replaced by
        # a literal '?'. Every string this script logs is ASCII, but
        # interpolated Windows error messages and file paths are not under our
        # control, so the encoding has to be pinned rather than inherited.
        [IO.File]::AppendAllText($CFG.LogFile, ($line + "`r`n"), (Get-LogEncoding))
    }
    catch {
        Write-Host "  [!] (log write failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Write-LogError {
    <# Logs an exception with its message, type and stack trace. #>
    param(
        [string]$Context,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    Write-Log "$Context - $($ErrorRecord.Exception.Message)" 'ERROR'
    Write-Log "    type : $($ErrorRecord.Exception.GetType().FullName)" 'INFO'
    if ($ErrorRecord.ScriptStackTrace) {
        foreach ($frame in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if ($frame.Trim()) { Write-Log "    at   : $($frame.Trim())" 'INFO' }
        }
    }
}

function Format-Size {
    <# Bytes to a human-readable string. The original always printed GB, so
       4 MB installers logged as "0 GB". #>
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}
