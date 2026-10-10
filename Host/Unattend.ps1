# Unattend.ps1 - part of Massokissed.LazyVM.Host. Unattended Windows Setup answer-file disc.
# Dot-sourced by Massokissed.LazyVM.Host.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  UNATTENDED SETUP ANSWER-FILE DISC
#
#  This closes the structural gap in the previous design: Phase 6 built the VM
#  but never started it, and Phase 7 immediately required a running guest that
#  was through OOBE with a user logged in. No amount of credential plumbing
#  fixes that — the OS install itself has to be automated.
#
#  Windows Setup looks for autounattend.xml only at the root of REMOVABLE media
#  (USB drives, then CDs and DVDs), never on a fixed disk. A virtual hard disk
#  is a fixed disk, so the answer file goes on a small ISO image instead,
#  attached as a second DVD drive. The image is built with IMAPI2, which is
#  part of Windows: no Windows ADK or oscdimg needed, and the Windows ISO is
#  never modified.
# ─────────────────────────────────────────────────────────────────────────────
function New-UnattendXml {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$TimeZone
    )

    # Literal here-string, tokens substituted afterwards, so nothing in the XML
    # is at risk of PowerShell interpolation.
    $template = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>@@USER@@</FullName>
        <Organization>LazyVM</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>@@COMPUTER@@</ComputerName>
      <TimeZone>@@TIMEZONE@@</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Allow OOBE without a Microsoft account</Description>
          <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <TimeZone>@@TIMEZONE@@</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>@@USER@@</Name>
            <DisplayName>@@USER@@</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>@@PASSWORD@@</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>@@USER@@</Username>
        <LogonCount>99</LogonCount>
        <Password>
          <Value>@@PASSWORD@@</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Never expire the local account password</Description>
          <CommandLine>cmd /c wmic useraccount where "name='@@USER@@'" set PasswordExpires=FALSE</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Signal provisioning complete</Description>
          <CommandLine>reg add "HKLM\SOFTWARE\LazyVM" /v Provisioned /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
'@

    # The answer file format requires the password in clear text, so it is
    # decoded here, at the last possible moment, and the answer-file disc carrying it
    # is deleted as soon as the guest is provisioned.
    # XML-escape the substituted values; a generated password contains & and <.
    $escUser = [Security.SecurityElement]::Escape($UserName)
    $escPass = [Security.SecurityElement]::Escape((ConvertTo-PlainText $Password))
    $escComputer = [Security.SecurityElement]::Escape($ComputerName)
    $escTimeZone = [Security.SecurityElement]::Escape($TimeZone)

    $xml = $template.Replace('@@USER@@', $escUser).
    Replace('@@PASSWORD@@', $escPass).
    Replace('@@COMPUTER@@', $escComputer).
    Replace('@@TIMEZONE@@', $escTimeZone)

    # Fail loudly here rather than letting Windows Setup silently ignore a
    # malformed answer file and drop to the interactive installer.
    $null = [xml]$xml
    return $xml
}

function Save-ImapiStream {
    <#
      Writes the image IMAPI2 builds to a file. IMAPI2 hands it over as a COM
      stream, which PowerShell cannot read directly, so a few lines of C# copy
      it across.
    #>
    param(
        [Parameter(Mandatory)]$Stream,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not ('LazyVM.ImapiStreamWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace LazyVM
{
    public static class ImapiStreamWriter
    {
        public static void Save(object stream, string path)
        {
            IStream source = (IStream)stream;
            byte[] buffer = new byte[65536];
            IntPtr bytesRead = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                using (FileStream target = File.Create(path))
                {
                    while (true)
                    {
                        source.Read(buffer, buffer.Length, bytesRead);
                        int count = Marshal.ReadInt32(bytesRead);
                        if (count == 0) { break; }
                        target.Write(buffer, 0, count);
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(bytesRead);
            }
        }
    }
}
'@
    }
    [LazyVM.ImapiStreamWriter]::Save($Stream, $Path)
}

function New-UnattendSeedDisk {
    <# Builds the answer-file disc, $CFG.SeedDiskPath: an ISO holding autounattend.xml. #>
    param([Parameter(Mandatory)][pscredential]$GuestCredential)

    Write-Log 'Building the answer-file disc...' 'INFO'

    if (Test-Path -LiteralPath $CFG.SeedDiskPath) {
        Remove-Item -LiteralPath $CFG.SeedDiskPath -Force
    }

    $xml = New-UnattendXml -UserName $CFG.GuestAdminUser `
        -Password $GuestCredential.Password `
        -ComputerName $CFG.GuestComputerName `
        -TimeZone $CFG.GuestTimeZone

    # IMAPI2 builds an image from a folder, so the answer file is written to
    # a private folder first and deleted straight after: it holds the guest
    # password in clear text.
    $staging = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("LazyVM-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null

        # Windows Setup expects UTF-8; a BOM is tolerated but omitted for safety.
        [IO.File]::WriteAllText((Join-Path -Path $staging -ChildPath 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding($false)))

        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $image.FileSystemsToCreate = 3      # ISO 9660 + Joliet, which keeps the long file name
        $image.VolumeName = 'UNATTEND'
        $image.Root.AddTree($staging, $false)
        $result = $image.CreateResultImage()
        Save-ImapiStream -Stream $result.ImageStream -Path $CFG.SeedDiskPath
    }
    catch {
        Write-LogError 'Building the answer-file disc failed' $_
        Remove-Item -LiteralPath $CFG.SeedDiskPath -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Answer-file disc ready: $($CFG.SeedDiskPath)" 'OK'
}

function Remove-UnattendSeedDisk {
    <# The answer file contains the guest password in plain text, so the
       answer-file disc is ejected and deleted as soon as provisioning is
       confirmed. #>
    param([string]$VMName)

    try {
        $attached = @(Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $CFG.SeedDiskPath })
        foreach ($drive in $attached) {
            Remove-VMDvdDrive -VMDvdDrive $drive
            Write-Log 'Answer-file disc removed from the VM' 'OK'
        }
        if (Test-Path -LiteralPath $CFG.SeedDiskPath) {
            Remove-Item -LiteralPath $CFG.SeedDiskPath -Force
            Write-Log 'Answer-file disc deleted (it held the guest password in clear text)' 'OK'
        }
    }
    catch {
        Write-Log "Could not remove the answer-file disc: $($_.Exception.Message)" 'WARN'
        Write-Log "  Delete $($CFG.SeedDiskPath) by hand - it contains the guest password." 'WARN'
    }
}
