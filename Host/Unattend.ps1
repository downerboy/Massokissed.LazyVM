# Unattend.ps1 - part of Massokissed.LazyVM.Host. Unattended Windows Setup seed disk.
# Dot-sourced by Massokissed.LazyVM.Host.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  UNATTENDED SETUP SEED DISK
#
#  This closes the structural gap in the previous design: Phase 6 built the VM
#  but never started it, and Phase 7 immediately required a running guest that
#  was through OOBE with a user logged in. No amount of credential plumbing
#  fixes that — the OS install itself has to be automated.
#
#  Windows Setup searches the root of every attached drive for autounattend.xml,
#  so a small FAT32 VHDX carries the answer file. No Windows ADK / oscdimg
#  needed, and the ISO is never modified.
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
    # decoded here, at the last possible moment, and the seed disk carrying it
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

function New-UnattendSeedDisk {
    param([Parameter(Mandatory)][pscredential]$GuestCredential)

    Write-Log 'Building autounattend seed disk...' 'INFO'

    if (Test-Path -LiteralPath $CFG.SeedDiskPath) {
        Remove-Item -LiteralPath $CFG.SeedDiskPath -Force
    }

    $xml = New-UnattendXml -UserName $CFG.GuestAdminUser `
        -Password $GuestCredential.Password `
        -ComputerName $CFG.GuestComputerName `
        -TimeZone $CFG.GuestTimeZone

    $disk = $null
    $mounted = $false
    try {
        New-VHD -Path $CFG.SeedDiskPath -SizeBytes 256MB -Dynamic | Out-Null
        $disk = Mount-VHD -Path $CFG.SeedDiskPath -Passthru | Get-Disk
        $mounted = $true

        $partition = $disk |
            Initialize-Disk -PartitionStyle MBR -PassThru |
            New-Partition -UseMaximumSize -AssignDriveLetter

        # Format-Volume can race the volume arriving; retry briefly.
        $volume = $null
        for ($i = 0; $i -lt 10 -and -not $volume; $i++) {
            Start-Sleep -Seconds 1
            try {
                $volume = Format-Volume -Partition $partition -FileSystem FAT32 `
                    -NewFileSystemLabel 'UNATTEND' -Confirm:$false -Force -ErrorAction Stop
            }
            catch { $volume = $null }
        }
        if (-not $volume) { throw 'could not format the seed volume as FAT32' }

        $letter = (Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter).DriveLetter
        if (-not $letter) { throw 'seed volume did not receive a drive letter' }

        # Windows Setup expects UTF-8; a BOM is tolerated but omitted for safety.
        $target = "${letter}:\autounattend.xml"
        [IO.File]::WriteAllText($target, $xml, (New-Object Text.UTF8Encoding($false)))
        Write-Log "autounattend.xml written to seed volume ${letter}:" 'OK'
    }
    catch {
        Write-LogError 'Seed disk creation failed' $_
        if ($mounted) { Dismount-VHD -Path $CFG.SeedDiskPath -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $CFG.SeedDiskPath -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($mounted) {
            Dismount-VHD -Path $CFG.SeedDiskPath -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Seed disk ready: $($CFG.SeedDiskPath)" 'OK'
}

function Remove-UnattendSeedDisk {
    <# The answer file contains the guest password in plain text, so the seed
       disk is detached and deleted as soon as provisioning is confirmed. #>
    param([string]$VMName)

    try {
        $attached = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $CFG.SeedDiskPath })
        foreach ($drive in $attached) {
            Remove-VMHardDiskDrive -VMHardDiskDrive $drive
            Write-Log 'Seed disk detached from VM' 'OK'
        }
        if (Test-Path -LiteralPath $CFG.SeedDiskPath) {
            Remove-Item -LiteralPath $CFG.SeedDiskPath -Force
            Write-Log 'Seed disk deleted (it held the guest password in clear text)' 'OK'
        }
    }
    catch {
        Write-Log "Could not remove the seed disk: $($_.Exception.Message)" 'WARN'
        Write-Log "  Delete $($CFG.SeedDiskPath) by hand - it contains the guest password." 'WARN'
    }
}
