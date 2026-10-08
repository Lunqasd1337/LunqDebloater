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
    $lines.Add("Профиль для сравнения: $($LunqProfile.Name). [id] справа: элемент уже есть в категории профиля с этим Id.")
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
        if ($Names.Count -eq 0) { $lines.Add('  (нет)') }
        $lines.Add('')
    }

    $appx = @(Get-AppxProvisionedPackage -Path $MountPath | ForEach-Object { $_.DisplayName } | Sort-Object -Unique)
    & $addSection "Приложения Appx: $($appx.Count). Для раздела Appx" $appx 'Appx'

    $caps = @(Get-WindowsCapability -Path $MountPath | Where-Object State -eq 'Installed' | ForEach-Object { $_.Name } | Sort-Object)
    & $addSection "Компоненты (Capabilities), установлены: $($caps.Count). Для раздела Capabilities, версию после ~~~~ можно заменить на *" $caps 'Capabilities'

    $features = @(Get-WindowsOptionalFeature -Path $MountPath | Sort-Object FeatureName)
    $enabled = @($features | Where-Object { [string]$_.State -eq 'Enabled' } | ForEach-Object { $_.FeatureName })
    $disabled = @($features | Where-Object { [string]$_.State -ne 'Enabled' } | ForEach-Object { $_.FeatureName })
    & $addSection "Функции Windows (Optional Features), включены: $($enabled.Count). Для раздела Features" $enabled 'Features'
    & $addSection "Функции Windows, выключены: $($disabled.Count). Их отключать не нужно" $disabled 'Features'

    $missing = @()
    foreach ($category in $categories) {
        foreach ($pair in @(@('Appx', $appx), @('Capabilities', $caps), @('Features', $enabled))) {
            foreach ($pattern in @($category.($pair[0]))) {
                if (-not (@($pair[1]) | Where-Object { $_ -like $pattern })) { $missing += ('  {0,-60} [{1}]' -f "$($pair[0]): $pattern", $category.Id) }
            }
        }
    }
    $lines.Add("== Есть в профиле, но нет в образе (или уже выключено): $($missing.Count) ==")
    foreach ($m in $missing) { $lines.Add($m) }
    if ($missing.Count -eq 0) { $lines.Add('  (нет)') }

    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
    return [pscustomobject]@{ Appx = $appx.Count; Capabilities = $caps.Count; Enabled = $enabled.Count; Disabled = $disabled.Count; Missing = $missing.Count }
}
