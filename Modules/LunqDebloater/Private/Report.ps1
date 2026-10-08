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

    Write-Section (Get-LunqText 'Report.Section')
    $results = @($Results | Where-Object { $null -ne $_ })

    # Удаления и реестр показываются ниже по категориям профиля, остальные шаги здесь.
    $byCategoryKinds = 'Appx', 'Capabilities', 'Features', 'Packages', 'Registry'
    foreach ($r in @($results | Where-Object { $byCategoryKinds -notcontains $_.Kind })) {
        if ($r.Summary) { Write-Info ("{0}: {1}" -f $r.Title, $r.Summary) }
        else {
            $key = if ($r.Kind -like 'Updates*') { 'Report.StepInstalled' } else { 'Report.StepAdded' }
            Write-Info (Get-LunqText $key $r.Title $r.Done.Count $r.Failed.Count)
        }
        if ($r.Failed.Count -gt 0) { Write-Host ('        ' + (Get-LunqText 'Report.Failed' ($r.Failed -join ', '))) -ForegroundColor Yellow }
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
                $parts += Get-LunqText 'Report.RemovedOrDisabled' $done
            }
            if ($registry -and $registry.ByCategory.ContainsKey($category.Id)) {
                $r = $registry.ByCategory[$category.Id]
                $parts += Get-LunqText 'Report.RegistryPart' ($r.Applied + $r.Skipped) $category.Registry.Count
                if ($r.Failed -gt 0) { $failed += Get-LunqText 'Report.RegistryFailed' $r.Failed }
            }
            if ($parts.Count -eq 0) { continue }
            $color = if ($failed.Count -gt 0) { 'Yellow' } else { 'Gray' }
            Write-Host ("    {0}: {1}" -f $category.Name, ($parts -join ', ')) -ForegroundColor $color
            if ($failed.Count -gt 0) { Write-Host ('        ' + (Get-LunqText 'Report.Failed' ($failed -join ', '))) -ForegroundColor Yellow }
            if ($missing.Count -gt 0) { Write-Host ('        ' + (Get-LunqText 'Report.Missing' ($missing -join ', '))) -ForegroundColor DarkGray }
        }
        $off = @($LunqProfile.Categories | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count -gt 0) { Write-Info (Get-LunqText 'Report.SkippedCategories' ($off -join ', ')) }
    }

    if ($OutputIso -and (Test-Path -LiteralPath $OutputIso)) {
        Write-Info (Get-LunqText 'Report.OutputIso' $OutputIso (Format-Size (Get-Item -LiteralPath $OutputIso).Length))
    }
    if ($Elapsed) { Write-Info (Get-LunqText 'Report.Elapsed' $Elapsed (Get-LunqVersion)) }
    if ($LogPath) { Write-Info (Get-LunqText 'Report.Log' $LogPath) }
    Write-Info ''
    Write-Info (Get-LunqText 'Report.Next')
    if ($HasUnattend) {
        # Файл ответов Rufus заменил бы autounattend.xml из ISO.
        foreach ($i in 1..3) { Write-Host ('    ' + (Get-LunqText "Report.UnattendRufus$i")) -ForegroundColor Yellow }
    }
    elseif ($HasFirstLogon) {
        # Свой файл ответов Rufus важнее Sysprep\unattend.xml, и тогда FirstLogonCommands из образа не выполнятся.
        foreach ($i in 1..4) { Write-Host ('    ' + (Get-LunqText "Report.FirstLogonRufus$i")) -ForegroundColor Yellow }
    }
}
