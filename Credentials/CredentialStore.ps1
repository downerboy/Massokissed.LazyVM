# CredentialStore.ps1 - part of Massokissed.LazyVM.Credentials. Encrypted credential store for guest and certificate passwords.
# Dot-sourced by Massokissed.LazyVM.Credentials.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  CREDENTIAL STORE
#  A machine key file (ACL'd to SYSTEM + Administrators) rather than DPAPI, so
#  that credentials written by an interactive admin are readable by the SYSTEM
#  scheduled task. See the NOTES block for the trade-off this makes.
# ─────────────────────────────────────────────────────────────────────────────
function Get-CredKey {
    if (-not (Test-Path -LiteralPath $CFG.CredStoreDir)) {
        New-Item -ItemType Directory -Path $CFG.CredStoreDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $CFG.CredKeyFile) {
        # .NET byte IO rather than Get-Content -Encoding Byte, which is
        # Windows PowerShell 5.1 only (PowerShell 7 renamed it -AsByteStream).
        $key = [IO.File]::ReadAllBytes($CFG.CredKeyFile)
        if ($key.Length -eq 32) { return $key }
        Write-Log 'Credential key file is malformed - regenerating (stored passwords will be reset)' 'WARN'
        Remove-Item -LiteralPath $CFG.GuestCredFile -Force -ErrorAction SilentlyContinue
    }

    $key = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
    [IO.File]::WriteAllBytes($CFG.CredKeyFile, $key)

    # Lock the key down: SYSTEM and Administrators only, inheritance removed.
    $acl = Get-Acl -LiteralPath $CFG.CredKeyFile
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    foreach ($id in 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $id, 'FullControl', 'None', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $CFG.CredKeyFile -AclObject $acl

    $hidden = Get-Item -LiteralPath $CFG.CredKeyFile -Force
    $hidden.Attributes = $hidden.Attributes -bor [IO.FileAttributes]::Hidden
    Write-Log 'Generated new credential key (SYSTEM + Administrators only)' 'OK'
    return $key
}

function Save-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )
    $key = Get-CredKey
    $blob = [pscustomobject]@{
        UserName = $UserName
        Password = ConvertFrom-SecureString -SecureString $Password -Key $key
    }
    # Each VM keeps its credentials in its own folder, which does not exist
    # yet when -SetupCredentials is the first thing run for a new VM.
    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $blob | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8 -Force
}

function Get-StoredCredential {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $key = Get-CredKey
        $blob = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $secure = ConvertTo-SecureString -String $blob.Password -Key $key
        return New-Object System.Management.Automation.PSCredential($blob.UserName, $secure)
    }
    catch {
        Write-Log "Could not read stored credential at $Path - $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function New-RandomPassword {
    param([int]$Length = 24)
    # Explicit character classes so the result always satisfies Windows
    # complexity rules, which a purely random draw does not guarantee.
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $lower = 'abcdefghijkmnopqrstuvwxyz'.ToCharArray()
    $digit = '23456789'.ToCharArray()
    $punct = '!@#$%^&*-_=+'.ToCharArray()
    $all = $upper + $lower + $digit + $punct

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $draw = {
        param($set)
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $set[[BitConverter]::ToUInt32($b, 0) % $set.Length]
    }

    $chars = @((& $draw $upper), (& $draw $lower), (& $draw $digit), (& $draw $punct))
    for ($i = $chars.Count; $i -lt $Length; $i++) { $chars += (& $draw $all) }

    # Fisher-Yates so the guaranteed classes are not always in positions 0-3.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $j = [int]([BitConverter]::ToUInt32($b, 0) % ($i + 1))
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    return (-join $chars)
}

function Get-GuestCredential {
    <#
      PowerShell Direct (Invoke-Command -VMName) ALWAYS requires an explicit
      credential — there is no implicit pass-through. Without one it prompts,
      which is why every unattended run of the previous script died with
      "The credential is invalid."
    #>
    param([switch]$CreateIfMissing)

    $cred = Get-StoredCredential -Path $CFG.GuestCredFile
    if ($cred) { return $cred }

    if (-not $CreateIfMissing) { return $null }

    $plain = New-RandomPassword
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    Save-StoredCredential -Path $CFG.GuestCredFile -UserName $CFG.GuestAdminUser -Password $secure
    Write-Log "Generated guest administrator credential for '$($CFG.GuestAdminUser)'" 'OK'
    Write-Log "  Stored at $($CFG.GuestCredFile). View it with: .\Build-LazyVM.ps1 -SetupCredentials" 'INFO'
    return (New-Object System.Management.Automation.PSCredential($CFG.GuestAdminUser, $secure))
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
