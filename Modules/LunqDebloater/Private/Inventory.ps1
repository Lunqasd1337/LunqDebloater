function Write-LunqInventory {
    # Сохраняет в текстовый файл всё, что есть в образе, в виде, удобном для профиля.
    # Справа помечаются категории профиля, которые уже упоминают элемент.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$LunqProfile,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Header = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($h in $Header) { $lines.Add($h) }
    $lines.Add((Get-LunqText 'Inventory.Profile' (Get-LunqLocalized $LunqProfile.Name)))
    $lines.Add('')

    $categories = @($LunqProfile.Categories)
    $mark = {
        param([string]$Name, [string]$Kind)
        $ids = @($categories | Where-Object { Test-NamePattern -Name $Name -Patterns @($_.$Kind) } | ForEach-Object { $_.Id })
        if ($ids.Count -gt 0) { return '[' + ($ids -join ', ') + ']' }
        return ''
    }
    $addSection = {
        param([string]$Title, [string[]]$Names, [string]$Kind)
        $lines.Add("== $Title ==")
        foreach ($n in $Names) { $lines.Add(('  {0,-60} {1}' -f $n, (& $mark $n $Kind)).TrimEnd()) }
        if ($Names.Count -eq 0) { $lines.Add('  ' + (Get-LunqText 'Inventory.None')) }
        $lines.Add('')
    }

    $appx = @(Get-AppxProvisionedPackage -Path $MountPath | ForEach-Object { $_.DisplayName } | Sort-Object -Unique)
    & $addSection (Get-LunqText 'Inventory.Appx' $appx.Count) $appx 'Appx'

    $caps = @(Get-WindowsCapability -Path $MountPath | Where-Object State -eq 'Installed' | ForEach-Object { $_.Name } | Sort-Object)
    & $addSection (Get-LunqText 'Inventory.Capabilities' $caps.Count) $caps 'Capabilities'

    $features = @(Get-WindowsOptionalFeature -Path $MountPath | Sort-Object FeatureName)
    $enabled = @($features | Where-Object { [string]$_.State -eq 'Enabled' } | ForEach-Object { $_.FeatureName })
    $disabled = @($features | Where-Object { [string]$_.State -ne 'Enabled' } | ForEach-Object { $_.FeatureName })
    & $addSection (Get-LunqText 'Inventory.FeaturesEnabled' $enabled.Count) $enabled 'Features'
    & $addSection (Get-LunqText 'Inventory.FeaturesDisabled' $disabled.Count) $disabled 'Features'

    $missing = @()
    foreach ($category in $categories) {
        foreach ($pair in @(@('Appx', $appx), @('Capabilities', $caps), @('Features', $enabled))) {
            foreach ($pattern in @($category.($pair[0]))) {
                if (-not (@($pair[1]) | Where-Object { $_ -like $pattern })) { $missing += ('  {0,-60} [{1}]' -f "$($pair[0]): $pattern", $category.Id) }
            }
        }
    }
    $lines.Add("== $(Get-LunqText 'Inventory.Missing' $missing.Count) ==")
    foreach ($m in $missing) { $lines.Add($m) }
    if ($missing.Count -eq 0) { $lines.Add('  ' + (Get-LunqText 'Inventory.None')) }

    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
    return [pscustomobject]@{ Appx = $appx.Count; Capabilities = $caps.Count; Enabled = $enabled.Count; Disabled = $disabled.Count; Missing = $missing.Count }
}
