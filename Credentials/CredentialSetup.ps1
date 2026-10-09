# CredentialSetup.ps1 - part of Massokissed.LazyVM.Credentials. Credential setup mode (-SetupCredentials).
# Dot-sourced by Massokissed.LazyVM.Credentials.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  CREDENTIAL SETUP MODE  (-SetupCredentials)
# ─────────────────────────────────────────────────────────────────────────────
function Resolve-GuestUserName {
    <#
      Normalises an account name. PowerShell Direct and the guest-side
      scheduled-task principal both want a bare local account name, so a
      DOMAIN\user or .\user form is reduced to its last segment.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $trimmed = $Name.Trim()
    if ($trimmed -match '[\\/]') {
        $bare = ($trimmed -split '[\\/]')[-1]
        Write-Log "Using the local account name '$bare' from '$trimmed'" 'INFO'
        $trimmed = $bare
    }
    if ($trimmed -match '@') {
        Exit-WithError "'$Name' looks like a Microsoft account or UPN. PowerShell Direct needs a LOCAL account in the guest."
    }
    if (-not $trimmed) { Exit-WithError 'The guest user name is empty.' }
    return $trimmed
}

function Sync-GuestUserFromStore {
    <#
      The credential store is the single source of truth for which account the
      script talks to. Adopting the stored name here means the account name
      never has to be set in a settings file by hand.

      The requested name is passed in rather than read from the script scope,
      so the precedence rule is visible at the call site.
    #>
    param([string]$Requested)

    if ($Requested) {
        $CFG.GuestAdminUser = Resolve-GuestUserName -Name $Requested
        return
    }
    $stored = Get-StoredCredential -Path $CFG.GuestCredFile
    if ($stored -and $stored.UserName -and $stored.UserName -ne $CFG.GuestAdminUser) {
        $CFG.GuestAdminUser = $stored.UserName
    }
}

function Invoke-CredentialSetup {
    param([string]$RequestedUser)

    Write-Log 'Credential Setup' 'PHASE'

    $existing = Get-StoredCredential -Path $CFG.GuestCredFile
    if ($existing) {
        Write-Log "Stored guest account : $($existing.UserName)" 'INFO'
        Write-Host ''
        Write-Host "  Guest password: $(ConvertTo-PlainText $existing.Password)" -ForegroundColor Yellow
        Write-Host ''
        if ($RequestedUser -and (Resolve-GuestUserName -Name $RequestedUser) -ne $existing.UserName) {
            Write-Log "Changing the stored account to '$(Resolve-GuestUserName -Name $RequestedUser)'" 'INFO'
        }
        else {
            $answer = Read-Host 'Replace this credential? Doing so will NOT change the password inside an existing VM. (y/N)'
            if ($answer -notmatch '^(y|yes)$') {
                Write-Log 'Keeping the existing credential' 'OK'
                return
            }
        }
    }

    # Account name: the -GuestUser switch, else the stored one, else ask.
    if ($RequestedUser) {
        $userName = Resolve-GuestUserName -Name $RequestedUser
    }
    elseif ($existing -and $existing.UserName) {
        $userName = $existing.UserName
    }
    else {
        Write-Host ''
        Write-Host '  The local administrator account INSIDE the VM.' -ForegroundColor Cyan
        Write-Host '  For a VM this script has not built yet, press Enter to accept the default;' -ForegroundColor Cyan
        Write-Host '  unattended Setup will create it. For a VM you set up by hand, type the' -ForegroundColor Cyan
        Write-Host '  account name you log in with.' -ForegroundColor Cyan
        Write-Host ''
        $typed = Read-Host "Guest user name [$($CFG.GuestAdminUser)]"
        $userName = if ($typed.Trim()) { Resolve-GuestUserName -Name $typed } else { $CFG.GuestAdminUser }
    }
    $CFG.GuestAdminUser = $userName

    Write-Host ''
    Write-Host "  Password for '$userName' in the guest." -ForegroundColor Cyan
    Write-Host '  Leave blank ONLY for a VM this script will build - a generated password' -ForegroundColor Cyan
    Write-Host '  is written into the unattended Setup answer file. For an existing VM,' -ForegroundColor Cyan
    Write-Host '  type the real password or nothing will be able to sign in.' -ForegroundColor Cyan
    Write-Host ''
    $secure = Read-Host "Password for $userName" -AsSecureString

    if ($secure.Length -eq 0) {
        $plain = New-RandomPassword
        $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
        Write-Host ''
        Write-Host "  Generated password: $plain" -ForegroundColor Yellow
        Write-Host ''
    }

    Save-StoredCredential -Path $CFG.GuestCredFile -UserName $userName -Password $secure
    Write-Log "Guest credential stored for '$userName' at $($CFG.GuestCredFile)" 'OK'
    Write-Log 'Every later run reads the account name from here - no need to edit the script.' 'INFO'
}
