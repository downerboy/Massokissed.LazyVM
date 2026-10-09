# Marketplace.ps1 - part of Massokissed.LazyVM.Tooling. Visual Studio Marketplace links for per-user extensions.
# Dot-sourced by Massokissed.LazyVM.Tooling.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  MARKETPLACE LINKS FOR PER-USER EXTENSIONS
#
#  An extension installed from Manage Extensions is per-user, and the Visual
#  Studio Installer's export does not include it. Its manifest has its VSIX id
#  but no marketplace link, and the installer needs the link to reinstall it.
#  The link is found by searching the marketplace for the extension's name and
#  accepting only a result whose name AND publisher match the manifest's
#  exactly, so a similarly named extension is never installed in its place.
#
#  The answer, found or not, is kept in the tooling list and reused, so each
#  extension is looked up once. A failed lookup (no network) is retried on the
#  next run.
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-MarketplaceItem {
    <#
      The marketplace item name (Publisher.Name) for an installed extension,
      '' when there is no match, $null when the lookup failed.

      The marketplace does not return extensions' VSIX ids, so a result is
      accepted only when both its display name and its publisher match the
      installed extension's manifest exactly (ignoring case), and only one
      result does. A near miss is reported as no match, never installed in
      the extension's place.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Publisher
    )

    $body = @{
        filters = @(@{
                criteria   = @(
                    @{ filterType = 8; value = 'Microsoft.VisualStudio.Ide' }
                    @{ filterType = 10; value = $DisplayName }
                )
                pageNumber = 1
                pageSize   = 25
            })
        # Versions, files, version properties, asset links, latest version only.
        flags   = 914
    } | ConvertTo-Json -Depth 6

    try {
        $response = Invoke-RestMethod -Method Post -TimeoutSec 30 `
            -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' `
            -ContentType 'application/json' -Headers @{ Accept = 'application/json;api-version=3.0-preview.1' } -Body $body
    }
    catch {
        Write-Log "  marketplace lookup failed for '$DisplayName': $($_.Exception.Message)" 'WARN'
        return $null
    }

    # Not every result carries every field, so each is read with
    # Get-RecordField rather than assumed.
    $candidates = @()
    foreach ($result in @(Get-RecordField -Item $response -Name 'results')) {
        foreach ($extension in @(Get-RecordField -Item $result -Name 'extensions')) {
            if (-not $extension) { continue }
            if ("$(Get-RecordField -Item $extension -Name 'displayName')".Trim() -ne $DisplayName.Trim()) { continue }

            $publisherInfo = Get-RecordField -Item $extension -Name 'publisher'
            $publisherName = "$(Get-RecordField -Item $publisherInfo -Name 'publisherName')"
            $publisherDisplay = "$(Get-RecordField -Item $publisherInfo -Name 'displayName')"
            if ($Publisher.Trim() -ne $publisherDisplay.Trim() -and $Publisher.Trim() -ne $publisherName.Trim()) { continue }

            $candidates += "$publisherName.$(Get-RecordField -Item $extension -Name 'extensionName')"
        }
    }

    $unique = @($candidates | Sort-Object -Unique)
    if ($unique.Count -eq 1) { return $unique[0] }
    return ''
}

function Add-MarketplaceItems {
    <# Gives each per-user extension in $Record its MarketplaceItem, reusing $Previous's answers. Updates $Record in place. #>
    param(
        [Parameter(Mandatory)]$Record,
        $Previous
    )

    $known = @{}
    if ($Previous) {
        foreach ($product in @($Previous.Products)) {
            foreach ($extension in @($product.UserExtensions)) {
                $item = Get-RecordField -Item $extension -Name 'MarketplaceItem'
                if ($null -ne $item) { $known["$($extension.Id)"] = "$item" }
            }
        }
    }

    foreach ($product in @($Record.Products)) {
        foreach ($extension in @($product.UserExtensions)) {
            if ($known.ContainsKey("$($extension.Id)")) {
                $extension['MarketplaceItem'] = $known["$($extension.Id)"]
                continue
            }
            # A lookup that fails for any reason leaves this extension without a
            # link for now; it is retried on the next run, and never stops one.
            try {
                $item = Resolve-MarketplaceItem -DisplayName "$($extension.DisplayName)" -Publisher "$($extension.Publisher)"
                if ($null -ne $item) { $extension['MarketplaceItem'] = $item }
            }
            catch {
                Write-Log "  marketplace lookup failed for '$($extension.DisplayName)': $($_.Exception.Message)" 'WARN'
            }
        }
    }
}
