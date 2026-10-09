# AwaitingReinstall.ps1 - part of Massokissed.LazyVM.Tooling. Items that must be reinstalled by hand after a rebuild.
# Dot-sourced by Massokissed.LazyVM.Tooling.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  AWAITING REINSTALL
#
#  A rebuild cannot reinstall programs that have no winget package, or
#  per-user extensions with no marketplace link. It lists them in the tooling
#  list under AwaitingReinstall. The daily run keeps them recorded while they
#  are missing, so they are not taken as uninstalled, and reminds you of them;
#  each one leaves the list once it is installed again. To drop one you no
#  longer want, delete it from AwaitingReinstall in Tooling.json.
# ─────────────────────────────────────────────────────────────────────────────

function Get-AwaitingNames {
    param($Record)

    $awaiting = Get-RecordField -Item $Record -Name 'AwaitingReinstall'
    if (-not $awaiting) { return @() }
    $names = @()
    foreach ($program in @(Get-RecordField -Item $awaiting -Name 'Programs')) { if ($program) { $names += "program $(Get-RecordField -Item $program -Name 'Name')" } }
    foreach ($extension in @(Get-RecordField -Item $awaiting -Name 'Extensions')) {
        if ($extension) { $names += "extension $(Get-RecordField -Item $extension -Name 'DisplayName') [$(Get-RecordField -Item $extension -Name 'Id')]" }
    }
    return $names
}

function Merge-AwaitingReinstall {
    <#
      Carries $Previous's AwaitingReinstall items into $Record: each one still
      missing is put back (so it is not seen as removed) and stays awaiting;
      each one installed again is dropped from the list. Updates $Record.
    #>
    param(
        [Parameter(Mandatory)]$Record,
        $Previous
    )

    $programs = @()
    $extensions = @()
    $previousAwaiting = Get-RecordField -Item $Previous -Name 'AwaitingReinstall'
    if ($previousAwaiting) {
        $presentPrograms = @(@($Record.Programs) | ForEach-Object { $_.Name })
        foreach ($program in @(Get-RecordField -Item $previousAwaiting -Name 'Programs')) {
            if (-not $program) { continue }
            if ($presentPrograms -contains $program.Name) { continue }
            $programs += [ordered]@{ Name = $program.Name; Publisher = $program.Publisher }
        }
        foreach ($extension in @(Get-RecordField -Item $previousAwaiting -Name 'Extensions')) {
            if (-not $extension) { continue }
            $product = @($Record.Products) | Where-Object { "$($_.ProductId)|$($_.ChannelId)" -eq $extension.ProductKey } | Select-Object -First 1
            if ($product -and (@($product.UserExtensions) | Where-Object { $_.Id -eq $extension.Id })) { continue }
            $extensions += [ordered]@{
                ProductKey = $extension.ProductKey; Id = $extension.Id
                DisplayName = $extension.DisplayName; Publisher = $extension.Publisher
            }
        }
    }

    if ($programs.Count -gt 0) {
        $Record['Programs'] = @(@($Record.Programs) + $programs | Sort-Object { $_.Name })
    }
    if ($extensions.Count -gt 0) {
        foreach ($extension in $extensions) {
            $product = @($Record.Products) | Where-Object { "$($_.ProductId)|$($_.ChannelId)" -eq $extension.ProductKey } | Select-Object -First 1
            if ($product) {
                $product['UserExtensions'] = @(@($product.UserExtensions) + [ordered]@{
                        Id = $extension.Id; DisplayName = $extension.DisplayName; Publisher = $extension.Publisher; MoreInfo = ''; MarketplaceItem = ''
                    } | Sort-Object { $_.Id })
            }
        }
    }

    $Record['AwaitingReinstall'] = [ordered]@{ Programs = @($programs); Extensions = @($extensions) }
    if ($programs.Count + $extensions.Count -gt 0) {
        Write-Log "$($programs.Count + $extensions.Count) item(s) from before the last rebuild still need installing by hand:" 'WARN'
        foreach ($program in $programs) { Write-Log "  program: $($program.Name)" 'WARN' }
        foreach ($extension in $extensions) { Write-Log "  extension: $($extension.DisplayName)" 'WARN' }
    }
}
