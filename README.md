# Massokissed.LazyVM

Builds and looks after Hyper-V development virtual machines on a Windows host, unattended: Windows 11 Enterprise Evaluation, Visual Studio, SQL Server 2022 Developer Edition and whatever other tools you install, with the 90-day evaluation handled for you.

## What it does

- **Builds a VM with no input from you** — creates it, installs Windows from an answer file, then installs everything in the VM's tooling list: Visual Studio and SSMS with their workloads and Marketplace extensions, SQL Server, and winget packages.
- **Keeps the VM's tooling list current** — every day it records what you have added or removed in the guest, taking a Hyper-V checkpoint first, so any recorded version can be returned to with `-Revert`.
- **Makes the 90-day evaluation a non-event** — it watches the licence, rearms Windows while it can, and when it can't, captures your state, rebuilds the VM and puts everything back: databases, logins, Visual Studio settings, certificates, environment and application settings.
- **Keeps your source safe across rebuilds** — source lives on a Dev Drive whose disk is never touched by a rebuild.
- **Runs several VMs on one host**, each with its own tools, disks, schedule and restore points.

## Requirements

- Windows Pro, Enterprise or Education on the host (Hyper-V is not available on Home), and an elevated PowerShell: Windows PowerShell 5.1 or PowerShell 7.
- A Windows 11 Enterprise Evaluation ISO, downloaded by hand from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise).
- Memory and disk for each VM. By default a VM starts with 8 GB of memory and can grow to 16 GB, and its disks are 120 GB for Windows, 100 GB for SQL data and 250 GB for the Dev Drive, all dynamically expanding.

## Getting started

Clone the repository into a folder named `Scripts` under the folder you want everything to live in. The folder above `Scripts` becomes the root that holds the VM disks, captured state and logs:

```powershell
git clone <repository URL> D:\DevVM\Scripts
cd D:\DevVM\Scripts
.\Build-LazyVM.ps1 -NewVM DevBox
.\Build-LazyVM.ps1 -SetupCredentials -GuestUser 'yourname'
.\Build-LazyVM.ps1
.\Build-LazyVM.ps1 -RegisterSchedule
```

If you downloaded the files as a zip instead, unblock them once first: `Get-ChildItem D:\DevVM -Recurse | Unblock-File`.

The [operator guide](Build-LazyVM-Guide.docx) covers every command, setting and phase, and what to do when something goes wrong.

## Layout

`Build-LazyVM.ps1` is the root of the `Massokissed.LazyVM` namespace. Each folder beside it is one PowerShell module, `Massokissed.LazyVM.<Folder>`:

| Module | Responsibility |
|---|---|
| Configuration | Settings files, VM profiles, and the settings shared by every module |
| Logging | Console and log file |
| Common | Small shared helpers |
| Credentials | The encrypted credential store and `-SetupCredentials` |
| Guest | The PowerShell Direct session: commands in the guest, files to and from it |
| DevDrive | The Dev Drive disk and volume |
| Tooling | Tooling inventory, the tooling list, checkpoints and revert |
| Host | Host preparation, the unattended Setup seed disk and the VM itself |
| Installation | Installing the tooling list, then post-configuration |
| Capture | Capturing guest state to the host |
| Restore | Restoring captured state into a guest |
| Maintenance | The licence, the daily maintenance run, rebuilds and the scheduled task |

`Config` holds the settings: `LazyVM.Defaults.psd1` (every setting, with its default), `LazyVM.Config.example.psd1` (a template for your own) and `Tooling.Default.json` (what a new VM is built with).

## Licence

LazyVM is free for personal and other noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). Using it for a commercial purpose needs a separate commercial licence; contact the author through GitHub.
