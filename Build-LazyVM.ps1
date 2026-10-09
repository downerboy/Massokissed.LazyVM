#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    LazyVM — unattended Hyper-V developer VM builds (Windows 11, Visual Studio, SQL Server 2022 and each VM's own tooling), one or more per host.

.DESCRIPTION
    Phase 0 : Hyper-V service health check (fixes vmms/vmcompute only; reports guest-side vmic*)
    Phase 1 : CPU / SLAT / RAM / free-space readiness
    Phase 2 : Hyper-V feature enable, with reboot + self-resuming scheduled task
    Phase 3 : Folder structure under the root folder (see -Root)
    Phase 4 : Asset verification. Installers are downloaded; the Windows ISO is
              verified only (Microsoft's evaluation download is gated behind a
              registration form and cannot be fetched unattended).
    Phase 5 : SQLDisk.vhdx create-if-missing (never overwritten)
    Phase 6 : VM build — Gen 2, Secure Boot, vTPM, 4 vCPU, dynamic RAM, plus an
              autounattend seed disk so Windows Setup and OOBE run unattended
    Phase 7 : Guest wait, SQL data disk and Dev Drive, then the VM's tooling
              list: Visual Studio Installer products (Visual Studio, SSMS)
              with their workloads and extensions, SQL Server 2022
              Developer, and winget packages
    Phase 8 : SQL data relocation, VS settings restore, database restore
    Phase 9 : Capture guest state to the host
    Phase 10: Restore captured state into a freshly built guest

    REBUILD ON EXPIRY
    The Windows 11 Enterprise evaluation runs for 90 days. A daily maintenance
    task watches the licence and does nothing until expiry is close, then:

      1. captures guest state (SQL, Visual Studio, Windows environment, files)
      2. if rearms remain, runs slmgr's rearm and reboots — another 90 days,
         no rebuild, nothing to migrate
      3. only when rearms are exhausted, retires the old OS disk by RENAME,
         rebuilds the VM unattended, restores the capture, verifies the result,
         and deletes the retired disk only once verification passes

    The SQL data disk and the Dev Drive are never destroyed: the first carries
    the database backups across, the second holds the source code, which
    source control backs up.

.PARAMETER VM
    Which VM this run is for: the name of a profile in Config\VMs. May be left
    out while the host has only one VM.

.PARAMETER NewVM
    Create the profile for a new VM, Config\VMs\<Name>\VM.psd1, then exit.
    Names are 1-15 letters, digits or hyphens. Combine with -From to start
    from an existing VM's settings. Build it afterwards with -VM <Name>.

.PARAMETER From
    With -NewVM: the existing VM whose settings the new one starts from.

.PARAMETER Root
    The folder that holds everything on the host: VM disks, ISO, installers,
    logs, credentials and captured state. Overrides Root in
    Config\LazyVM.Config.psd1. When neither is set, the folder above the one
    holding this script is used, so with the script in D:\DevVM\Scripts the
    root is D:\DevVM. The scheduled tasks are registered with the root in use
    at the time, so they keep using it.

.PARAMETER FromPhase
    Start at a specific phase, skipping earlier ones. Default 0 (all).

.PARAMETER CheckLicense
    Report evaluation days and rearms remaining, then exit.

.PARAMETER ShowTooling
    List what is installed in the guest - every Visual Studio Installer
    product with its workloads and extensions, winget packages and other
    programs - save it under the State folder, then exit. Changes nothing.

.PARAMETER RecordTooling
    Record the guest's tooling now, as the daily maintenance run does: if it
    has changed, take a checkpoint, then record the new tooling list.

.PARAMETER ListRestorePoints
    List the recorded tooling versions that can be returned to with -Revert.

.PARAMETER Revert
    Return the VM to a recorded tooling version: -Revert 20261008-193000.
    Applies that checkpoint to ALL the VM's disks, including the Dev Drive and
    SQL data disk, and restores the matching tooling list. A checkpoint of the
    current state is taken first. Asks for confirmation unless -Force is given.

.PARAMETER Capture
    Snapshot guest state to the State folder on the host, then exit.

.PARAMETER Restore
    Apply the stored capture into the current guest, then exit.

.PARAMETER Rebuild
    Capture, retire the old VM, rebuild, restore and verify.

.PARAMETER Maintain
    The scheduled task's entry point: check the licence, rearm if possible,
    rebuild only when rearms are exhausted.

.PARAMETER NoUnattend
    Do not build or attach the autounattend seed disk. Windows Setup and OOBE
    then have to be completed by hand, and Phase 7 will wait for that.

.PARAMETER RegisterSchedule
    Register this VM's daily maintenance task (runs as SYSTEM at its
    MaintenanceTime): tooling check, licence check, rearm or rebuild.

.PARAMETER SetupCredentials
    Prompt for and store the guest administrator account and password, then
    exit. Combine with -GuestUser to set the account name in one command.

.PARAMETER GuestUser
    The local administrator account inside the VM. Stored alongside the
    password, and read back automatically on every later run, so no settings
    file needs editing for it:

        .\Build-LazyVM.ps1 -SetupCredentials -GuestUser 'mike'

.NOTES
    Save to  : <root>\Scripts\Build-LazyVM.ps1, for example
               C:\VSDev\Scripts\Build-LazyVM.ps1. The root folder is then
               C:\VSDev unless -Root or the Root setting says otherwise.
               Keep the module folders and the Config folder beside it: the functions
               (the Massokissed.LazyVM.* modules) and settings
               are loaded from there, and the script will not start without them.
    Settings : Config\LazyVM.Defaults.psd1 lists every setting. To change one,
               copy Config\LazyVM.Config.example.psd1 to LazyVM.Config.psd1
               and edit that copy; updates never overwrite it.
    First run: launch an elevated PowerShell and run the script.

    CREDENTIAL STORAGE
    Guest and certificate passwords are stored in <root>\Backup encrypted with a
    256-bit key in .lazyvm.key, ACL'd to SYSTEM and Administrators. A machine
    key (rather than DPAPI) is used deliberately so the SYSTEM scheduled task
    can read credentials created by an interactive admin. Any local admin can
    therefore recover these passwords — acceptable for a disposable lab VM,
    not for anything holding real secrets.
#>

[CmdletBinding()]
# PSScriptAnalyzer rules deliberately accepted, with reasons:
#   Write-Host          — this is an operator-facing console tool; every line
#                         also goes to the log file. Write-Output would
#                         pollute the pipeline of every function that logs.
#   Write-Log           — shadows a cmdlet that exists only in some PowerShell
#                         Core builds. A script-local function always wins, and
#                         the #Requires target (5.1) has no such cmdlet.
#   ShouldProcess       — internal helpers, not an exported module surface.
#   Singular nouns      — internal helper names, not exported cmdlets.
#   Plaintext secure    — unavoidable: Windows answer files take the password
#     string conversion    in clear text, and a generated password has to be
#                          converted once on the way into the store.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
#   Plaintext password  — the certificate PFX password has to cross into the
#     parameter            guest as a string to build a SecureString there, and
#                          Windows answer files take the password in clear text.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
param(
    # Which VM, and creating new ones. See .PARAMETER VM, NewVM and From above.
    [string]$VM,
    [string]$NewVM,
    [string]$From,

    # The host folder everything lives under. See .PARAMETER Root above.
    [string]$Root,

    [ValidateRange(0, 8)]
    [int]$FromPhase = 0,

    [switch]$NoUnattend,
    [switch]$RegisterSchedule,
    [switch]$SetupCredentials,

    # The guest's local administrator account. Pass it with -SetupCredentials
    # to store it once; every later run picks it up from the credential store,
    # so there is no need to set it in a settings file.
    [string]$GuestUser,

    # ── rebuild-on-expiry modes (each runs on its own and then exits) ───────
    [switch]$CheckLicense,     # report evaluation days and rearms remaining
    [switch]$ShowTooling,      # list the guest's installed tooling (read-only)
    [switch]$RecordTooling,    # record tooling changes now, with a checkpoint
    [switch]$ListRestorePoints, # recorded tooling versions that can be reverted to
    [string]$Revert,           # return the VM to a recorded tooling version
    [switch]$Capture,          # snapshot guest state to the host
    [switch]$Restore,          # apply a capture into the current guest
    [switch]$Rebuild,          # capture -> retire -> build -> restore -> verify
    [switch]$Maintain,         # the scheduled task's entry point
    [switch]$SkipCapture,      # with -Rebuild: reuse the existing manifest
    [switch]$Force             # with -Rebuild or -Revert: proceed without confirmation
)

# StrictMode is pinned rather than 'Latest' so a future PowerShell release
# cannot silently change the semantics this script was tested against.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD MODULES AND SETTINGS
#
#  This script is the root of the Massokissed.LazyVM namespace. Everything it
#  calls lives in a module per folder beside it, Massokissed.LazyVM.<Folder>,
#  and the settings in the Config folder (see Config\LazyVM.Defaults.psd1,
#  and copy Config\LazyVM.Config.example.psd1 to LazyVM.Config.psd1 to change
#  any).
#
#  The modules are imported into the global scope, in dependency order, so
#  each can call the functions the others export; any command can also be
#  called by its full name, for example
#  Massokissed.LazyVM.Tooling\Update-ToolingRecord. They are removed again
#  when the script ends. The list is explicit, so a stray folder is never
#  loaded. Importing runs nothing; the first call is in MAIN.
# ─────────────────────────────────────────────────────────────────────────────
if (-not $PSScriptRoot) {
    throw 'Build-LazyVM.ps1 must be run from its saved file: it loads its modules and settings from the folders beside it.'
}

try {
    $moduleFolders = @(
        'Configuration',
        'Logging',
        'Common',
        'Credentials',
        'Guest',
        'DevDrive',
        'Tooling',
        'Host',
        'Installation',
        'Capture',
        'Restore',
        'Maintenance'
    )

    foreach ($moduleFolder in $moduleFolders) {
        $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath "$moduleFolder\Massokissed.LazyVM.$moduleFolder.psd1"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Missing module: $manifestPath. Copy every folder of the kit alongside Build-LazyVM.ps1."
        }
        Import-Module -Name $manifestPath -Global -Force -DisableNameChecking
    }

    $configDir = Join-Path -Path $PSScriptRoot -ChildPath 'Config'

    if ($From -and -not $NewVM) {
        throw '-From only applies with -NewVM, to say which VM the new one starts from.'
    }
    if ($NewVM -and $VM) {
        throw 'Use -NewVM on its own (with -From if wanted); -VM is for working with an existing VM.'
    }
    $newProfilePath = $null
    if ($NewVM) {
        $newProfilePath = New-VMProfile -ConfigDir $configDir -Name $NewVM -From $From
    }

    $selectedVM = if ($NewVM) { $NewVM } else { $VM }
    $configuration = Import-LazyVMConfiguration -ConfigDir $configDir `
        -ScriptDir $PSScriptRoot -RootOverride $Root -VMName $selectedVM
    $CFG = $configuration.Settings

    # Resolved once at startup: the scheduled tasks and Phase 2's resume run
    # this file, so they need a real path on disk.
    $CFG.ScriptPath =
    if ($PSCommandPath) { $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
    else { $null }

    # ─────────────────────────────────────────────────────────────────────────────
    #  MAIN
    # ─────────────────────────────────────────────────────────────────────────────
    Initialize-Log

    Write-Log '========================================================' 'INFO'
    Write-Log '  LazyVM Build Automation'                                'INFO'
    Write-Log "  Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"     'INFO'
    Write-Log "  Host    : $env:COMPUTERNAME"                            'INFO'
    Write-Log "  User    : $env:USERDOMAIN\$env:USERNAME"                'INFO'
    Write-Log "  PSVer   : $($PSVersionTable.PSVersion)"                  'INFO'
    Write-Log "  Script  : $(if ($CFG.ScriptPath) { $CFG.ScriptPath } else { '<not saved to disk>' })" 'INFO'
    Write-Log "  VM      : $($configuration.VMName) (profile $($configuration.ProfilePath))" 'INFO'
    Write-Log "  Root    : $($configuration.Root) (from $($configuration.RootSource))" 'INFO'
    if ($configuration.UserFile) {
        Write-Log "  Config  : $($configuration.UserFile)" 'INFO'
        Write-Log "  Changed : $(if ($configuration.ChangedKeys.Count -gt 0) { $configuration.ChangedKeys -join ', ' } else { 'nothing' })" 'INFO'
    }
    else {
        Write-Log '  Config  : defaults (no Config\LazyVM.Config.psd1)' 'INFO'
    }
    Write-Log '========================================================' 'INFO'

    $script:UseUnattend = $false
    $exitCode = 0

    try {
        # Adopt the account name from -GuestUser or the credential store before
        # anything reads $CFG.GuestAdminUser.
        Sync-GuestUserFromStore -Requested $GuestUser
        Write-Log "Guest account: $($CFG.GuestAdminUser)" 'INFO'

        if ($NewVM) {
            Write-Log "Created the profile for VM '$NewVM': $newProfilePath" 'OK'
            if ($From) { Write-Log "  Settings copied from '$From'; file locations and task names are the new VM's own." 'INFO' }
            Write-Log "  Daily maintenance time: $($CFG.MaintenanceTime)" 'INFO'
            Write-Log 'Next steps:' 'INFO'
            Write-Log "  .\Build-LazyVM.ps1 -VM $NewVM -SetupCredentials -GuestUser <name>" 'INFO'
            Write-Log "  .\Build-LazyVM.ps1 -VM $NewVM" 'INFO'
            Write-Log "  .\Build-LazyVM.ps1 -VM $NewVM -RegisterSchedule" 'INFO'
            exit 0
        }

        if ($SetupCredentials) {
            Invoke-CredentialSetup -RequestedUser $GuestUser
            Write-Log 'Credential setup finished.' 'OK'
            exit 0
        }

        # ── rebuild-on-expiry modes ─────────────────────────────────────────────
        # Each of these runs on its own rather than falling through the phases.

        if ($CheckLicense) {
            Show-LicenseStatus | Out-Null
            Disconnect-Guest
            exit 0
        }

        if ($ShowTooling) {
            Show-GuestTooling
            Disconnect-Guest
            exit 0
        }

        if ($RecordTooling) {
            $startedHere = Open-GuestSession -Purpose 'record its tooling'
            Update-ToolingRecord | Out-Null
            if ($startedHere) { Stop-GuestGracefully }
            Disconnect-Guest
            exit 0
        }

        if ($ListRestorePoints) {
            Show-ToolingRestorePoints
            exit 0
        }

        if ($Revert) {
            $interactive = [Environment]::UserInteractive -and -not $Force
            Invoke-ToolingRevert -Stamp $Revert -Confirmed:(-not $interactive)
            exit 0
        }

        if ($Capture) {
            Invoke-Phase9-Capture | Out-Null
            Disconnect-Guest
            exit 0
        }

        # Standalone: registering the watch must not drag a whole build pass along
        # with it. Combine it with a build by running the build first, then this.
        if ($RegisterSchedule -and -not ($Rebuild -or $Maintain)) {
            Register-RebuildSchedule
            exit 0
        }

        if ($Restore) {
            $restoreOk = Invoke-Phase10-Restore
            Disconnect-Guest
            exit $(if ($restoreOk -eq $false) { 1 } else { 0 })
        }

        if ($Maintain) {
            $action = Invoke-Maintenance
            switch ($action) {
                'none' { Write-Log 'Maintenance complete - nothing needed' 'OK'; Disconnect-Guest; exit 0 }
                'rearmed' { Write-Log 'Maintenance complete - evaluation rearmed, no rebuild needed' 'OK'; Disconnect-Guest; exit 0 }
                'error' { Disconnect-Guest; exit 1 }
                'rebuild' {
                    Write-Log 'Maintenance is escalating to a full rebuild' 'WARN'
                    # The capture already ran inside Invoke-Maintenance.
                    $ok = Invoke-Rebuild -SkipCapture -NoUnattend:$NoUnattend
                    Disconnect-Guest
                    exit $(if ($ok) { 0 } else { 1 })
                }
                'build' {
                    Write-Log 'Maintenance found no VM - building one' 'INFO'
                    $ok = Invoke-Rebuild -NoUnattend:$NoUnattend
                    Disconnect-Guest
                    exit $(if ($ok) { 0 } else { 1 })
                }
            }
        }

        if ($Rebuild) {
            # A rebuild destroys the guest OS. Confirm unless the caller has
            # already said otherwise, or nobody is there to answer.
            $interactive = [Environment]::UserInteractive -and -not $Force
            if ($interactive -and (Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue)) {
                Write-Host ''
                Write-Host "  This rebuilds '$($CFG.VMName)' from scratch." -ForegroundColor Yellow
                Write-Host '  Guest state is captured first and restored afterwards, and the old' -ForegroundColor Yellow
                Write-Host '  OS disk is kept until the new one is verified.' -ForegroundColor Yellow
                Write-Host ''
                $answer = Read-Host 'Continue? (y/N)'
                if ($answer -notmatch '^(y|yes)$') {
                    Write-Log 'Rebuild cancelled' 'INFO'
                    exit 0
                }
            }
            $ok = Invoke-Rebuild -SkipCapture:$SkipCapture -NoUnattend:$NoUnattend
            Disconnect-Guest
            exit $(if ($ok) { 0 } else { 1 })
        }

        $resumePhase = Get-ResumePhase
        $startPhase = [math]::Max($FromPhase, $resumePhase)
        if ($startPhase -gt 0) { Write-Log "Starting at Phase $startPhase" 'INFO' }

        $needsFeatureInstall = $false

        if ($startPhase -le 0) {
            $needsFeatureInstall = Invoke-Phase0-ServiceCheck
            Invoke-Phase1-CPUCheck
        }

        if ($startPhase -le 2) {
            Invoke-Phase2-HyperVFeature
        }
        elseif ($needsFeatureInstall) {
            Write-Log 'Hyper-V services are unhealthy but Phase 2 was skipped by -FromPhase' 'WARN'
        }

        if ($startPhase -le 3) { Invoke-Phase3-FolderSetup }
        if ($startPhase -le 4) { Invoke-Phase4-AssetCheck }
        else { Resolve-InstallationIso }   # later phases still need a valid ISO path
        if ($startPhase -le 5) { Invoke-Phase5-SQLDisk; Invoke-Phase5b-DevDrive }

        if ($startPhase -le 6) {
            # The seed disk must exist before Phase 6, which attaches it, and is
            # only worth building for a VM that has not been created yet.
            if (-not $NoUnattend) {
                if (Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue) {
                    Write-Log 'VM already exists - not rebuilding the unattend seed disk' 'INFO'
                }
                else {
                    $guestCredential = Get-GuestCredential -CreateIfMissing
                    New-UnattendSeedDisk -GuestCredential $guestCredential
                    $script:UseUnattend = $true
                }
            }
            else {
                Write-Log '-NoUnattend: Windows Setup and OOBE will have to be completed by hand' 'WARN'
            }

            Invoke-Phase6-VMBuild -UseUnattend:$script:UseUnattend
        }

        if ($startPhase -le 7) {
            $seedAttached = @(
                Get-VMHardDiskDrive -VMName $CFG.VMName -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -eq $CFG.SeedDiskPath }
            ).Count -gt 0

            Invoke-Phase7-SilentInstalls -UsedUnattend:($script:UseUnattend -or $seedAttached)
        }

        if ($startPhase -le 8) { Invoke-Phase8-PostConfig }

        # Only now is the resume point cleared, so a crash mid-resume leaves it in
        # place for the next attempt.
        Unregister-ResumeTask

        Write-Log '' 'INFO'
        Write-Log '========================================================' 'INFO'
        Write-Log "  All phases complete. $($CFG.VMName) is ready."          'OK'
        Write-Log "  Log : $($CFG.LogFile)"                                 'INFO'
        Write-Log '========================================================' 'INFO'
    }
    catch {
        Write-LogError 'FATAL' $_
        Write-Log "Log saved to: $($CFG.LogFile)" 'INFO'
        $exitCode = 1
    }
    finally {
        Disconnect-Guest
    }

    exit $exitCode
}
finally {
    # Remove-Module, not left loaded: run from a console, the functions would
    # otherwise stay in that session after the script ends.
    Get-Module -Name 'Massokissed.LazyVM.*' | Remove-Module -Force -ErrorAction SilentlyContinue
}
