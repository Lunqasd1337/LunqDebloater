# Рецепт сборки: файл <имя ISO>.lunq.json рядом с итоговым ISO. В нём всё, из чего собран ISO:
# исходный ISO с контрольной суммой, редакция, профиль целиком, выбранные категории и пункты
# сводки, обновления и драйверы. -Recipe повторяет сборку по нему, а отчёт <имя ISO>.lunq.html
# показывает, что было в редакции и что с ней сделано.

$script:RecipeKind = 'LunqDebloaterRecipe'

function Get-LunqRecipePath {
    # Рецепт и отчёт лежат рядом с итоговым ISO и называются так же.
    param([Parameter(Mandatory)][string]$OutputIso, [string]$Extension = '.lunq.json')
    return [IO.Path]::ChangeExtension($OutputIso, $Extension)
}

function Get-LunqFileSha256 {
    # SHA-256 файла. Cache (путь, размер и время файла) избавляет от повторного чтения: ISO на
    # 6 ГБ читается десятки секунд.
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Cache = @{})
    $item = Get-Item -LiteralPath $Path
    $key = '{0}|{1}|{2}' -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks
    if (-not $Cache.ContainsKey($key)) { $Cache[$key] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    return $Cache[$key]
}

function Get-LunqRecipeFiles {
    # Список файлов для рецепта: имя, размер, контрольная сумма и вид (обычное обновление, Safe OS, Setup).
    param($Files, [string]$Kind, [hashtable]$Cache = @{})
    foreach ($file in @($Files)) {
        if (-not $file) { continue }
        [ordered]@{ Name = $file.Name; Kind = $Kind; Size = [long]$file.Length; Sha256 = Get-LunqFileSha256 -Path $file.FullName -Cache $Cache }
    }
}

function New-LunqRecipe {
    # Собирает рецепт из того, что знает LunqDebloater.ps1 после сборки. Values: хэш-таблица с
    # ключами, перечисленными ниже; профиль берётся из файла целиком, чтобы сборку можно было
    # повторить и после его правки.
    param([Parameter(Mandatory)][hashtable]$Values, [hashtable]$HashCache = @{})
    # Не переданные ключи считаются пустыми: в строгом режиме обращение к ним было бы ошибкой.
    $v = $Values.Clone()
    foreach ($key in 'ProfilePath', 'ProfileOriginalPath', 'Profile', 'IsoPath', 'Index', 'EditionName', 'BuildText', 'OutputIso', 'Label', 'ConfigPath',
        'SkipAppx', 'SkipComponents', 'SkipRegistry', 'CleanupComponents', 'DownloadUpdates', 'UpdatesPath', 'UpdatesToSetup', 'Updates', 'SafeOS', 'SetupDU',
        'DriversPath', 'HostDrivers', 'DriversToSetup', 'Drivers', 'Apps', 'HostApps', 'Scripts', 'HostWifi', 'SetupAnswers', 'BypassRequirements', 'LocalAccount',
        'BootCA2023') {
        if (-not $v.ContainsKey($key)) { $v[$key] = $null }
    }
    $profileContent = $null
    $profileHash = $null
    if ($v.ProfilePath -and (Test-Path -LiteralPath $v.ProfilePath -PathType Leaf)) {
        $profileContent = Get-Content -LiteralPath $v.ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $profileHash = Get-LunqFileSha256 -Path $v.ProfilePath -Cache $HashCache
    }
    # Профиль, взятый из прошлого рецепта, лежит во временной папке: в рецепт идёт путь исходного файла.
    $recordedProfile = $v.ProfilePath
    if ($v.ProfileOriginalPath) { $recordedProfile = $v.ProfileOriginalPath }
    $updates = @(Get-LunqRecipeFiles $v.Updates 'Update' $HashCache) + @(Get-LunqRecipeFiles $v.SafeOS 'SafeOS' $HashCache) + @(Get-LunqRecipeFiles $v.SetupDU 'Setup' $HashCache)
    return [ordered]@{
        Kind          = $script:RecipeKind
        FormatVersion = 1
        LunqVersion   = Get-LunqVersion
        Created       = Get-Date -Format 'yyyy-MM-dd HH:mm'
        Iso           = [ordered]@{ Path = $v.IsoPath; Size = [long](Get-Item -LiteralPath $v.IsoPath).Length; Sha256 = Get-LunqFileSha256 -Path $v.IsoPath -Cache $HashCache }
        Edition       = [ordered]@{ Index = [int]$v.Index; Name = $v.EditionName; Build = $v.BuildText }
        OutputIso     = $v.OutputIso
        Label         = $v.Label
        ConfigPath    = $v.ConfigPath
        Profile       = [ordered]@{ Path = $recordedProfile; Sha256 = $profileHash; Content = $profileContent }
        Categories    = @($v.Profile.Categories | Where-Object { $_.Enabled } | ForEach-Object { $_.Id })
        Steps         = [ordered]@{ SkipAppx = [bool]$v.SkipAppx; SkipComponents = [bool]$v.SkipComponents; SkipRegistry = [bool]$v.SkipRegistry; CleanupComponents = [bool]$v.CleanupComponents }
        Updates       = [ordered]@{ Download = [bool]$v.DownloadUpdates; Path = $v.UpdatesPath; ToSetup = [bool]$v.UpdatesToSetup; Files = @($updates) }
        Drivers       = [ordered]@{ Path = $v.DriversPath; FromHost = [bool]$v.HostDrivers; ToSetup = [bool]$v.DriversToSetup; Count = @($v.Drivers).Count }
        FirstLogon    = [ordered]@{ Apps = @($v.Apps); AppsFromHost = [bool]$v.HostApps; Scripts = @($v.Scripts | ForEach-Object { $_.Name }); Wifi = [bool]$v.HostWifi }
        Unattend      = [ordered]@{ Enabled = [bool]$v.SetupAnswers; BypassRequirements = [bool]$v.BypassRequirements; LocalAccount = [bool]$v.LocalAccount }
        # Каким загрузчиком и как записан носитель. В рецептах до 1.13.0 этого поля нет.
        Media         = [ordered]@{ BootCA2023 = [bool]$v.BootCA2023 }
    }
}

function Save-LunqRecipe {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][string]$Path)
    [IO.File]::WriteAllText($Path, ($Recipe | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
}

function Read-LunqRecipe {
    # Читает и проверяет рецепт. Ошибка сразу говорит, что не так, а не всплывает посреди сборки.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (Get-LunqText 'Recipe.NotFound' $Path) }
    try { $recipe = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw (Get-LunqText 'Recipe.BadJson' $Path $_.Exception.Message) }
    if ([string](Get-ConfigValue $recipe 'Kind') -ne $script:RecipeKind) { throw (Get-LunqText 'Recipe.NotRecipe' $Path) }
    if ([int](Get-ConfigValue $recipe 'FormatVersion') -gt 1) { throw (Get-LunqText 'Recipe.NewerFormat' $Path (Get-ConfigValue $recipe 'LunqVersion')) }
    foreach ($field in 'Iso', 'Edition', 'Profile', 'Steps', 'Updates', 'Drivers', 'FirstLogon', 'Unattend') {
        if ($null -eq (Get-ConfigValue $recipe $field)) { throw (Get-LunqText 'Recipe.MissingField' $Path $field) }
    }
    return $recipe
}

function Get-LunqRecipeProfile {
    # Профиль для повторной сборки: исходный файл, если он не менялся, иначе копия из рецепта во
    # временной папке. Возвращает путь и признак, что взята копия.
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][string]$TempDir)
    $path = [string](Get-ConfigValue $Recipe 'Profile', 'Path')
    $hash = [string](Get-ConfigValue $Recipe 'Profile', 'Sha256')
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf) -and $hash -and (Get-LunqFileSha256 -Path $path) -eq $hash) {
        return [pscustomobject]@{ Path = $path; FromRecipe = $false }
    }
    $content = Get-ConfigValue $Recipe 'Profile', 'Content'
    if ($null -eq $content) { throw (Get-LunqText 'Recipe.NoProfile') }
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $name = if ($path) { Split-Path $path -Leaf } else { 'Profile.json' }
    $copy = Join-Path $TempDir $name
    [IO.File]::WriteAllText($copy, ($content | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $copy; FromRecipe = $true }
}

function Get-LunqRecipeParameters {
    # Значения параметров LunqDebloater.ps1 из рецепта. Скрипт берёт только те, что не заданы
    # в командной строке: так рецепт можно повторить с другим ISO или без обновлений.
    # Пути, которых на этом компьютере нет, не возвращаются: вместо них берутся папки по умолчанию.
    param([Parameter(Mandatory)]$Recipe)
    $r = $Recipe
    $values = [ordered]@{}
    $values.IsoPath = [string]$r.Iso.Path
    $values.Index = [int]$r.Edition.Index
    if ($r.PSObject.Properties['OutputIso'] -and $r.OutputIso) { $values.OutputIso = [string]$r.OutputIso }
    if ($r.PSObject.Properties['Label'] -and $r.Label) { $values.Label = [string]$r.Label }
    $configPath = [string](Get-ConfigValue $r 'ConfigPath')
    if ($configPath -and (Test-Path -LiteralPath $configPath -PathType Container)) { $values.ConfigPath = $configPath }
    # Пустой список тоже передаётся: в той сборке все категории были выключены.
    if ($r.PSObject.Properties['Categories']) { $values.Category = (Get-ConfigList $r 'Categories') }
    foreach ($name in 'SkipAppx', 'SkipComponents', 'SkipRegistry', 'CleanupComponents') { $values[$name] = [bool](Get-ConfigValue $r 'Steps', $name) }

    $values.DownloadUpdates = [bool](Get-ConfigValue $r 'Updates', 'Download')
    $values.UpdatesToSetup = [bool](Get-ConfigValue $r 'Updates', 'ToSetup')
    $updatesPath = [string](Get-ConfigValue $r 'Updates', 'Path')
    $updateFiles = (Get-ConfigList $r.Updates 'Files')
    if (-not $values.DownloadUpdates) {
        if ($updateFiles.Count -eq 0) { $values.SkipUpdates = $true }
        elseif ($updatesPath -and (Test-Path -LiteralPath $updatesPath -PathType Container)) { $values.UpdatesPath = $updatesPath }
    }

    $values.HostDrivers = [bool](Get-ConfigValue $r 'Drivers', 'FromHost')
    $values.DriversToSetup = [bool](Get-ConfigValue $r 'Drivers', 'ToSetup')
    $driversPath = [string](Get-ConfigValue $r 'Drivers', 'Path')
    if ([int](Get-ConfigValue $r 'Drivers', 'Count') -eq 0) { $values.SkipDrivers = $true }
    elseif (-not $values.HostDrivers -and $driversPath -and (Test-Path -LiteralPath $driversPath -PathType Container)) { $values.DriversPath = $driversPath }

    # Программы этого компьютера уже записаны в рецепт списком: скрипт берёт его, а не выгружает заново.
    if ((Get-ConfigList $r.FirstLogon 'Apps').Count -eq 0) { $values.SkipApps = $true }
    if ((Get-ConfigList $r.FirstLogon 'Scripts').Count -eq 0) { $values.SkipScripts = $true }
    $values.HostWifi = [bool](Get-ConfigValue $r 'FirstLogon', 'Wifi')

    $values.Unattend = [bool](Get-ConfigValue $r 'Unattend', 'Enabled')
    $values.BypassRequirements = [bool](Get-ConfigValue $r 'Unattend', 'BypassRequirements')
    $values.LocalAccount = [bool](Get-ConfigValue $r 'Unattend', 'LocalAccount')
    $values.BootCA2023 = [bool](Get-ConfigValue $r 'Media', 'BootCA2023')
    return $values
}

function Compare-LunqRecipeFiles {
    # Чем файлы этой сборки отличаются от рецепта. Возвращает строки для предупреждений.
    param($Expected = @(), $Actual = @())
    $exp = @{}
    foreach ($f in @($Expected)) { if ($f) { $exp[[string]$f.Name] = [string]$f.Sha256 } }
    $act = @{}
    foreach ($f in @($Actual)) { if ($f) { $act[[string]$f.Name] = [string]$f.Sha256 } }
    $lines = @()
    foreach ($name in @($exp.Keys | Sort-Object)) {
        if (-not $act.ContainsKey($name)) { $lines += Get-LunqText 'Recipe.FileMissing' $name }
        elseif ($act[$name] -ne $exp[$name]) { $lines += Get-LunqText 'Recipe.FileChanged' $name }
    }
    foreach ($name in @($act.Keys | Sort-Object)) {
        if (-not $exp.ContainsKey($name)) { $lines += Get-LunqText 'Recipe.FileNew' $name }
    }
    return , $lines
}

function ConvertTo-LunqHtml {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [Net.WebUtility]::HtmlEncode($Text)
}

function Write-LunqHtmlReport {
    # Отчёт о сборке в HTML: что было в редакции и что с ней сделано, по категориям профиля.
    # Один файл без внешних ссылок: его можно открыть в любом браузере и переслать.
    param(
        [Parameter(Mandatory)][string]$Path,
        [object[]]$Results = @(),
        [Parameter(Mandatory)]$LunqProfile,
        [Parameter(Mandatory)][hashtable]$Info,
        $StepTimes = @()
    )
    $h = { param($t) ConvertTo-LunqHtml ([string]$t) }
    $results = @($Results | Where-Object { $null -ne $_ })
    $sb = New-Object System.Text.StringBuilder
    $add = { param($line) $null = $sb.AppendLine($line) }

    & $add '<!doctype html>'
    & $add ('<html lang="{0}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">' -f (Get-LunqLanguage))
    & $add ('<title>{0}</title>' -f (& $h (Get-LunqText 'Recipe.HtmlTitle' (Split-Path $Info.OutputIso -Leaf))))
    & $add '<style>'
    & $add ':root{--bg:#fbfbfa;--fg:#1d1d1b;--muted:#6b6b66;--line:#e4e3de;--card:#fff;--ok:#2f7d4f;--warn:#a5620f;--bad:#b3261e;--accent:#2b5fb4}'
    & $add '@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ecebe6;--muted:#a3a29b;--line:#34332f;--card:#1f1f1d;--ok:#6cc08b;--warn:#e0a64b;--bad:#f08b83;--accent:#8fb3f0}}'
    & $add 'body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",system-ui,sans-serif}main{max-width:960px;margin:0 auto;padding:24px 16px 48px}'
    & $add 'h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 8px}p.sub{color:var(--muted);margin:0 0 16px}'
    & $add 'table{border-collapse:collapse;width:100%;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}'
    & $add 'th,td{text-align:left;padding:6px 10px;border-top:1px solid var(--line);vertical-align:top}th{font-weight:600;color:var(--muted);width:30%}thead th{border-top:0}'
    & $add 'td.num{text-align:right;font-variant-numeric:tabular-nums}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.muted{color:var(--muted)}'
    & $add 'details{background:var(--card);border:1px solid var(--line);border-radius:8px;margin:8px 0;padding:8px 12px}summary{cursor:pointer;font-weight:600}'
    & $add 'ul{margin:6px 0 4px;padding-left:20px}code{font:13px Consolas,ui-monospace,monospace;word-break:break-all}.wrap{overflow-x:auto}'
    & $add '</style></head><body><main>'
    & $add ('<h1>{0}</h1>' -f (& $h (Get-LunqText 'Recipe.HtmlHeading')))
    & $add ('<p class="sub">{0}</p>' -f (& $h (Get-LunqText 'Recipe.HtmlSubtitle' $Info.EditionName $Info.BuildText (Get-Date -Format 'yyyy-MM-dd HH:mm') (Get-LunqVersion))))

    # Сводка: исходный и итоговый ISO, профиль, время.
    & $add '<div class="wrap"><table>'
    $rows = [ordered]@{}
    $rows[(Get-LunqText 'Recipe.HtmlSourceIso')] = '<code>{0}</code><br><span class="muted">{1}</span>' -f (& $h $Info.IsoPath), (& $h (Format-Size $Info.IsoSize))
    $rows[(Get-LunqText 'Recipe.HtmlOutputIso')] = '<code>{0}</code><br><span class="muted">{1}</span>' -f (& $h $Info.OutputIso), (& $h (Format-Size $Info.OutputSize))
    $rows[(Get-LunqText 'Recipe.HtmlProfile')] = & $h ('{0} ({1})' -f $LunqProfile.Name, (Split-Path $Info.ProfilePath -Leaf))
    $rows[(Get-LunqText 'Recipe.HtmlElapsed')] = & $h ('{0:hh\:mm\:ss}' -f $Info.Elapsed)
    $rows[(Get-LunqText 'Recipe.HtmlRecipe')] = '<code>{0}</code>' -f (& $h $Info.RecipePath)
    foreach ($key in $rows.Keys) { & $add ('<tr><th>{0}</th><td>{1}</td></tr>' -f (& $h $key), $rows[$key]) }
    & $add '</table></div>'

    # Было и стало: сколько элементов было в редакции и сколько удалено.
    $kinds = @(
        @('Appx', (Get-LunqText 'Recipe.HtmlKindAppx')),
        @('Capabilities', (Get-LunqText 'Recipe.HtmlKindCapabilities')),
        @('Features', (Get-LunqText 'Recipe.HtmlKindFeatures'))
    )
    $removal = @($results | Where-Object { $_.Kind -in 'Appx', 'Capabilities', 'Features' })
    if ($removal.Count -gt 0) {
        & $add ('<h2>{0}</h2>' -f (& $h (Get-LunqText 'Recipe.HtmlBeforeAfter')))
        & $add ('<div class="wrap"><table><thead><tr><th></th><th>{0}</th><th>{1}</th><th>{2}</th></tr></thead>' -f (& $h (Get-LunqText 'Recipe.HtmlWas')), (& $h (Get-LunqText 'Recipe.HtmlRemoved')), (& $h (Get-LunqText 'Recipe.HtmlLeft')))
        foreach ($kind in $kinds) {
            $r = @($removal | Where-Object { $_.Kind -eq $kind[0] }) | Select-Object -First 1
            if (-not $r) { continue }
            & $add ('<tr><th>{0}</th><td class="num">{1}</td><td class="num">{2}</td><td class="num">{3}</td></tr>' -f (& $h $kind[1]), $r.Total, $r.Done.Count, [Math]::Max($r.Total - $r.Done.Count, 0))
        }
        & $add '</table></div>'
    }

    # По категориям профиля: что удалено, что не нашлось и какие записи реестра внесены.
    $registry = @($results | Where-Object { $_.Kind -eq 'Registry' }) | Select-Object -First 1
    & $add ('<h2>{0}</h2>' -f (& $h (Get-LunqText 'Recipe.HtmlCategories')))
    foreach ($category in @($LunqProfile.Categories)) {
        if (-not $category.Enabled) { continue }
        $removed = @()
        $missing = @()
        $failed = @()
        foreach ($r in @($results | Where-Object { $_.Kind -in 'Appx', 'Capabilities', 'Features', 'Packages' })) {
            $patterns = @($category.($r.Kind))
            if ($patterns.Count -eq 0) { continue }
            $removed += @($r.Done | Where-Object { Test-NamePattern -Name $_ -Patterns $patterns })
            $failed += @($r.Failed | Where-Object { Test-NamePattern -Name $_ -Patterns $patterns })
            $missing += @($r.NotMatched | Where-Object { $patterns -contains $_ })
        }
        $regDone = @()
        if ($registry) {
            foreach ($entry in @($category.Registry)) {
                $label = '{0}\{1}' -f $entry.Hive, $entry.Path
                if ($entry.PSObject.Properties['Name'] -and $entry.Name) { $label = "$label\$($entry.Name)" }
                $value = ''
                $action = [string](Get-ConfigValue $entry 'Action')
                if (-not $action -or $action -eq 'Set') { $value = ' = ' + (@(Get-ConfigValue $entry 'Value') -join ', ') }
                else { $value = " ($action)" }
                if ($registry.Failed -contains $label) { $failed += $label } else { $regDone += $label + $value }
            }
        }
        $class = if ($failed.Count -gt 0) { 'warn' } else { 'ok' }
        & $add ('<details><summary><span class="{0}">{1}</span> <span class="muted">{2}</span></summary>' -f $class, (& $h $category.Name), (& $h (Get-LunqText 'Recipe.HtmlCategoryCounts' $removed.Count $regDone.Count)))
        foreach ($block in @(
                @((Get-LunqText 'Recipe.HtmlRemovedList'), $removed, ''),
                @((Get-LunqText 'Recipe.HtmlRegistryList'), $regDone, ''),
                @((Get-LunqText 'Recipe.HtmlFailedList'), $failed, 'bad'),
                @((Get-LunqText 'Recipe.HtmlMissingList'), $missing, 'muted'))) {
            if (@($block[1]).Count -eq 0) { continue }
            & $add ('<div class="{0}">{1}</div><ul>' -f $block[2], (& $h $block[0]))
            foreach ($item in @($block[1])) { & $add ('<li><code>{0}</code></li>' -f (& $h $item)) }
            & $add '</ul>'
        }
        & $add '</details>'
    }
    $off = @($LunqProfile.Categories | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    if ($off.Count -gt 0) { & $add ('<p class="muted">{0}</p>' -f (& $h (Get-LunqText 'Report.SkippedCategories' ($off -join ', ')))) }

    # Остальные шаги одной строкой, как в итоге в консоли.
    $other = @($results | Where-Object { $_.Kind -notin 'Appx', 'Capabilities', 'Features', 'Packages', 'Registry' })
    if ($other.Count -gt 0) {
        & $add ('<h2>{0}</h2>' -f (& $h (Get-LunqText 'Recipe.HtmlOtherSteps')))
        & $add '<div class="wrap"><table>'
        foreach ($r in $other) {
            $text = if ($r.Summary) { $r.Summary } else { Get-LunqText 'Recipe.HtmlStepCounts' $r.Done.Count $r.Failed.Count }
            $items = ''
            if ($r.Done.Count -gt 0 -and -not $r.Summary) { $items = '<br><span class="muted">' + (& $h ($r.Done -join ', ')) + '</span>' }
            if ($r.Failed.Count -gt 0) { $items += '<br><span class="bad">' + (& $h (Get-LunqText 'Report.Failed' ($r.Failed -join ', '))) + '</span>' }
            & $add ('<tr><th>{0}</th><td>{1}{2}</td></tr>' -f (& $h $r.Title), (& $h $text), $items)
        }
        & $add '</table></div>'
    }

    $times = @($StepTimes | Where-Object { $_ })
    if ($times.Count -gt 0) {
        & $add ('<h2>{0}</h2>' -f (& $h (Get-LunqText 'Recipe.HtmlSteps')))
        & $add '<div class="wrap"><table>'
        foreach ($t in $times) { & $add ('<tr><th>{0}</th><td class="num">{1}</td></tr>' -f (& $h $t.Title), (& $h ('{0:hh\:mm\:ss}' -f $t.Elapsed))) }
        & $add '</table></div>'
    }
    & $add '</main></body></html>'
    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}
