function New-LunqResult {
    # Результат шага, один формат для всех шагов:
    #   Done, Failed, Skipped: что сделано, что не удалось, что пропущено (например, уже нет в образе);
    #   NotMatched: шаблоны профиля, которые ничего не нашли;
    #   Summary: одна строка для итога вместо счётчиков (первый вход, файл ответов, очистка);
    #   ByCategory: счётчики по категориям профиля (для реестра).
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Kind)
    return [pscustomobject]@{
        Title      = $Title
        Kind       = $Kind
        Done       = New-Object System.Collections.Generic.List[string]
        Failed     = New-Object System.Collections.Generic.List[string]
        Skipped    = New-Object System.Collections.Generic.List[string]
        NotMatched = New-Object System.Collections.Generic.List[string]
        Summary    = $null
        ByCategory = @{}
    }
}

function Add-NotMatched {
    param($Result, [string[]]$Patterns, [string[]]$Names)
    foreach ($pattern in $Patterns) {
        if (-not ($Names | Where-Object { $_ -like $pattern })) { $Result.NotMatched.Add($pattern) }
    }
}

function Write-LunqReport {
    # Итог сборки: обновления и результат по каждой включённой категории профиля.
    param(
        [object[]]$Results = @(),
        $LunqProfile,
        [string]$OutputIso,
        [TimeSpan]$Elapsed,
        [string]$LogPath,
        [switch]$HasFirstLogon,
        [switch]$HasUnattend
    )

    Write-Section 'Итог'
    $results = @($Results | Where-Object { $null -ne $_ })

    # Удаления и реестр показываются ниже по категориям профиля, остальные шаги здесь.
    $byCategoryKinds = 'Appx', 'Capabilities', 'Features', 'Packages', 'Registry'
    foreach ($r in @($results | Where-Object { $byCategoryKinds -notcontains $_.Kind })) {
        if ($r.Summary) { Write-Info ("{0}: {1}" -f $r.Title, $r.Summary) }
        else {
            $verb = if ($r.Kind -like 'Updates*') { 'установлено' } else { 'добавлено' }
            Write-Info ("{0}: {1} {2}, ошибок {3}" -f $r.Title, $verb, $r.Done.Count, $r.Failed.Count)
        }
        if ($r.Failed.Count -gt 0) { Write-Host "        Не удалось: $($r.Failed -join ', ')" -ForegroundColor Yellow }
    }
    $registry = @($results | Where-Object { $_.Kind -eq 'Registry' }) | Select-Object -First 1

    if ($LunqProfile) {
        foreach ($category in @($LunqProfile.Categories | Where-Object { $_.Enabled })) {
            $done = 0
            $failed = @()
            $missing = @()
            foreach ($r in $results) {
                if ($r.Kind -notin 'Appx', 'Capabilities', 'Features', 'Packages') { continue }
                $patterns = @($category.($r.Kind))
                if ($patterns.Count -eq 0) { continue }
                $done += @($r.Done | Where-Object { Test-NamePattern -Name $_ -Patterns $patterns }).Count
                $failed += @($r.Failed | Where-Object { Test-NamePattern -Name $_ -Patterns $patterns })
                $missing += @($r.NotMatched | Where-Object { $patterns -contains $_ })
            }
            $parts = @()
            if (($category.Appx.Count + $category.Capabilities.Count + $category.Features.Count + $category.Packages.Count) -gt 0) {
                $parts += "удалено или отключено: $done"
            }
            if ($registry -and $registry.ByCategory.ContainsKey($category.Id)) {
                $r = $registry.ByCategory[$category.Id]
                $parts += ("реестр: {0} из {1}" -f ($r.Applied + $r.Skipped), $category.Registry.Count)
                if ($r.Failed -gt 0) { $failed += "записей реестра: $($r.Failed)" }
            }
            if ($parts.Count -eq 0) { continue }
            $color = if ($failed.Count -gt 0) { 'Yellow' } else { 'Gray' }
            Write-Host ("    {0}: {1}" -f $category.Name, ($parts -join ', ')) -ForegroundColor $color
            if ($failed.Count -gt 0) { Write-Host "        Не удалось: $($failed -join ', ')" -ForegroundColor Yellow }
            if ($missing.Count -gt 0) { Write-Host "        Нет в образе или уже убрано: $($missing -join ', ')" -ForegroundColor DarkGray }
        }
        $off = @($LunqProfile.Categories | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count -gt 0) { Write-Info "Пропущены категории: $($off -join ', ')" }
    }

    if ($OutputIso -and (Test-Path -LiteralPath $OutputIso)) {
        Write-Info ("Итоговый ISO: {0} ({1})" -f $OutputIso, (Format-Size (Get-Item -LiteralPath $OutputIso).Length))
    }
    if ($Elapsed) { Write-Info ('Время сборки: {0:hh\:mm\:ss}, LunqDebloater {1}' -f $Elapsed, (Get-LunqVersion)) }
    if ($LogPath) { Write-Info "Лог: $LogPath" }
    Write-Info ''
    Write-Info 'Что дальше: запишите ISO на флешку (например, через Rufus) или подключите его к виртуальной машине.'
    if ($HasUnattend) {
        # Файл ответов Rufus заменил бы autounattend.xml из ISO.
        Write-Host '    В ISO уже есть файл ответов LunqDebloater. Если записываете флешку через Rufus, не отмечайте' -ForegroundColor Yellow
        Write-Host '    в его окне настройки Windows: Rufus добавит свой файл ответов, и выбранные настройки установки,' -ForegroundColor Yellow
        Write-Host '    программы и скрипты после установки не сработают.' -ForegroundColor Yellow
    }
    elseif ($HasFirstLogon) {
        # Свой файл ответов Rufus важнее Sysprep\unattend.xml, и тогда FirstLogonCommands из образа не выполнятся.
        Write-Host '    Rufus при записи предлагает настройки Windows: обход требований TPM, Secure Boot и памяти,' -ForegroundColor Yellow
        Write-Host '    локальную учётную запись и другие. Не отмечайте ни одну: иначе программы и скрипты после' -ForegroundColor Yellow
        Write-Host '    установки не запустятся сами. Нужные настройки можно включить в файле ответов LunqDebloater' -ForegroundColor Yellow
        Write-Host '    (сводка «Что войдёт в образ»), а программы и скрипты запустить вручную: команда в README.' -ForegroundColor Yellow
    }
}
