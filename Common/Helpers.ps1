# Helpers.ps1 - part of Massokissed.LazyVM.Common. Small shared helpers.
# Dot-sourced by Massokissed.LazyVM.Common.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  SMALL HELPERS
# ─────────────────────────────────────────────────────────────────────────────
function Test-IsoFile {
    <#
      A real ISO 9660 image carries the 'CD001' volume descriptor identifier at
      offset 0x8001. This is how the script tells a genuine image from the HTML
      redirect page that Microsoft's evaluation fwlink actually returns.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -lt 0x8006) { return $false }

    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $null = $stream.Seek(0x8001, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] 5
        if ($stream.Read($buffer, 0, 5) -ne 5) { return $false }
        return ([Text.Encoding]::ASCII.GetString($buffer) -eq 'CD001')
    }
    catch { return $false }
    finally { if ($stream) { $stream.Dispose() } }
}

function Test-PortableExecutable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 2) { return $false }
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] 2
        if ($stream.Read($buffer, 0, 2) -ne 2) { return $false }
        return ($buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A)   # 'MZ'
    }
    catch { return $false }
    finally { if ($stream) { $stream.Dispose() } }
}

function Get-FreeSpaceGB {
    <# Free space on the volume that actually hosts $Path, rather than
       assuming C: as the original did. #>
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetPathRoot((Resolve-PathForce $Path))
    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'"
    if (-not $drive) { return -1 }
    return [math]::Round($drive.FreeSpace / 1GB, 1)
}

function Resolve-PathForce {
    <# Resolve-Path fails on paths that do not exist yet; this does not. #>
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-HyperVModule {
    if (Get-Module -ListAvailable -Name Hyper-V) { return $true }
    return $false
}

function Exit-WithError {
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}
