# ─────────────────────────────────────────────────────────────────────────────
#  LazyVM.Config.example.psd1 - template for your own settings
#
#  To use it:
#    1. Copy this file to LazyVM.Config.psd1 in this same folder.
#    2. Remove the # from the start of each setting you want to change,
#       and set your value.
#
#  Only the settings you uncomment change; everything else keeps its default
#  from LazyVM.Defaults.psd1, which also explains every setting in full.
#  Updates to the script never overwrite LazyVM.Config.psd1.
#
#  Settings here apply to every VM on this host. A setting for one VM only
#  goes in that VM's profile, Config\VMs\<Name>\VM.psd1, instead.
#
#  The values shown are the defaults. A misspelled setting name, or a value of
#  the wrong kind (text where a number belongs, say), stops the script at
#  startup with a message naming the problem, before anything is changed.
# ─────────────────────────────────────────────────────────────────────────────
@{
    # ── Root folder ─────────────────────────────────────────────────────────
    # Leave this out to use the folder above the script's folder (with the
    # script in D:\DevVM\Scripts, that is D:\DevVM).
    # Root              = 'D:\DevVM'

    # ── Folder locations (relative to the root, or a full path) ─────────────
    # VHDXRoot          = 'VMs'
    # ISOSearchRoot     = 'ISO'

    # ── Virtual machine ─────────────────────────────────────────────────────
    # vCPU              = 4
    # MemStartGB        = 8
    # MemMinGB          = 2
    # MemMaxGB          = 16
    # OSDiskSizeGB      = 120

    # ── Guest Windows ───────────────────────────────────────────────────────
    # GuestComputerName = '{VM}'      # {VM} is the VM's name
    # GuestTimeZone     = 'Pacific Standard Time'    # list them with: tzutil /l

    # ── Data disks ──────────────────────────────────────────────────────────
    # SQLDiskSizeGB     = 100
    # UseDevDrive       = $true
    # DevDriveSizeGB    = 250        # minimum supported by Dev Drive is 50
    # DevDriveLetter    = 'W'

    # ── What gets installed ─────────────────────────────────────────────────
    # Not set here: each VM is built from its tooling list,
    # Config\VMs\<Name>\Tooling.json, which the daily maintenance run keeps
    # up to date with what is installed in the guest.
    #
    # A new VM with no list of its own is built from Config\Tooling.Default.json:
    # Visual Studio 2026 Community with the web, .NET desktop, MAUI, Azure,
    # data, Python and Windows app workloads, SSMS 22, a few extensions and
    # themes, and winget tools such as Git, VS Code, LINQPad, Notepad++ and
    # WinMerge. To change it before the first build, copy it to
    # Config\VMs\<Name>\Tooling.json and edit the copy:
    # remove what you don't want, or add winget package ids. Edit the copy, not
    # Tooling.Default.json, which is replaced when the script is updated.

    # ── Rebuild on evaluation expiry ────────────────────────────────────────
    # RebuildThresholdDays       = 10
    # DeleteRetiredDiskOnSuccess = $true
    # MaxProjectCaptureGB        = 20
}
