#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Рецепт сборки и отчёт HTML (Private\Recipe.ps1): что записывается, как читается и что
# берётся для повторной сборки.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru
    $script:Profile = Join-Path $repo 'Config\Profile.json'

    # Сборка в миниатюре: ISO, копия профиля, два обновления и Safe OS.
    function global:New-LunqRecipeTest {
        param([string]$Root, [string]$ProfileSource)
        New-Item -ItemType Directory -Path (Join-Path $Root 'upd\SafeOS') -Force | Out-Null
        $iso = Join-Path $Root 'Win11.iso'
        Set-Content -LiteralPath $iso -Value 'iso'
        $profilePath = Join-Path $Root 'Profile.json'
        Copy-Item -LiteralPath $ProfileSource -Destination $profilePath
        foreach ($name in 'windows11.0-kb5090000-x64.msu', 'windows11.0-kb5090001-x64-ndp481.msu', 'SafeOS\windows11.0-kb5090002-x64.cab') {
            Set-Content -LiteralPath (Join-Path $Root "upd\$name") -Value $name
        }
        return [pscustomobject]@{ Root = $Root; Iso = $iso; Profile = $profilePath; Updates = (Join-Path $Root 'upd') }
    }
}

AfterAll {
    Remove-Item function:global:New-LunqRecipeTest -ErrorAction SilentlyContinue
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Запись и чтение рецепта' {
    BeforeAll {
        $script:T = New-LunqRecipeTest -Root (Join-Path $TestDrive 'r1') -ProfileSource $script:Profile
        $script:RecipePath = Join-Path $script:T.Root 'Win11_Lunq.lunq.json'
        InModuleScope LunqDebloater -Parameters @{ T = $script:T; Path = $script:RecipePath } {
            param($T, $Path)
            Mock Write-Host { }
            $lunqProfile = Read-LunqProfile -Path $T.Profile
            # Одна категория выключена: в рецепт идут только включённые.
            $lunqProfile.Categories[0].Enabled = $false
            $updates = @(Get-ChildItem -LiteralPath $T.Updates -File)
            $safeOS = @(Get-ChildItem -LiteralPath (Join-Path $T.Updates 'SafeOS') -File)
            $recipe = New-LunqRecipe -Values @{
                ProfilePath = $T.Profile; Profile = $lunqProfile; IsoPath = $T.Iso; Index = 5; EditionName = 'Windows 11 Pro'; BuildText = '26300.7000'
                OutputIso = (Join-Path $T.Root 'Win11_Lunq.iso'); Label = 'LUNQ'; SkipRegistry = $true
                DownloadUpdates = $false; UpdatesPath = $T.Updates; Updates = $updates; SafeOS = $safeOS; SetupDU = @()
                Drivers = @(); Apps = @('Git.Git'); Scripts = @(); HostWifi = $true; SetupAnswers = $true; LocalAccount = $true
            }
            Save-LunqRecipe -Recipe $recipe -Path $Path
            $script:SavedProfile = $lunqProfile
        }
        $script:Json = Get-Content -LiteralPath $script:RecipePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It 'в рецепте исходный ISO с SHA-256, редакция и выбранные шаги' {
        $iso = Get-FileHash -LiteralPath $script:T.Iso -Algorithm SHA256
        $script:Json.Kind | Should -Be 'LunqDebloaterRecipe'
        $script:Json.Iso.Path | Should -Be $script:T.Iso
        $script:Json.Iso.Sha256 | Should -Be $iso.Hash.ToLowerInvariant()
        $script:Json.Edition.Index | Should -Be 5
        $script:Json.Steps.SkipRegistry | Should -BeTrue
        $script:Json.Steps.SkipAppx | Should -BeFalse
        $script:Json.Unattend.LocalAccount | Should -BeTrue
        $script:Json.FirstLogon.Wifi | Should -BeTrue
        @($script:Json.FirstLogon.Apps) | Should -Be @('Git.Git')
    }

    It 'в рецепте профиль целиком и только включённые категории' {
        $source = Get-Content -LiteralPath $script:T.Profile -Raw -Encoding UTF8 | ConvertFrom-Json
        @($script:Json.Profile.Content.Categories).Count | Should -Be @($source.Categories).Count
        $first = @($source.Categories)[0].Id
        @($script:Json.Categories) | Should -Not -Contain $first
        # Остальные включённые категории профиля на месте (часть категорий выключена в самом профиле).
        $enabled = @($source.Categories | Select-Object -Skip 1 | Where-Object { -not ($_.PSObject.Properties['Enabled'] -and $_.Enabled -eq $false) } | ForEach-Object { $_.Id })
        @($script:Json.Categories) | Should -Be $enabled
    }

    It 'обновления записаны каждое отдельно, с видом и суммой' {
        $files = @($script:Json.Updates.Files)
        $files.Count | Should -Be 3
        @($files | ForEach-Object { $_.Kind }) | Should -Be @('Update', 'Update', 'SafeOS')
        $files[2].Name | Should -Be 'windows11.0-kb5090002-x64.cab'
        $files[2].Sha256 | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:T.Updates 'SafeOS\windows11.0-kb5090002-x64.cab') -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'параметры для повтора: пути, которые есть, и пропуск того, чего в сборке не было' {
        InModuleScope LunqDebloater -Parameters @{ Path = $script:RecipePath; T = $script:T } {
            param($Path, $T)
            $values = Get-LunqRecipeParameters -Recipe (Read-LunqRecipe -Path $Path)
            $values.IsoPath | Should -Be $T.Iso
            $values.Index | Should -Be 5
            $values.UpdatesPath | Should -Be $T.Updates
            $values.Contains('SkipUpdates') | Should -BeFalse
            $values.SkipDrivers | Should -BeTrue
            $values.Contains('SkipApps') | Should -BeFalse
            $values.SkipScripts | Should -BeTrue
            $values.HostWifi | Should -BeTrue
            $values.SkipRegistry | Should -BeTrue
            $values.Label | Should -Be 'LUNQ'
            # В рецепте нет имени ISO (как до 1.13.0): путь берётся как записан.
            $values.OutputIso | Should -Be (Join-Path $T.Root 'Win11_Lunq.iso')
            $values.Contains('OutputName') | Should -BeFalse
        }
    }

    It 'с именем ISO в рецепте путь не берётся: его считают заново с версией этого запуска' {
        InModuleScope LunqDebloater -Parameters @{ Path = $script:RecipePath } {
            param($Path)
            $recipe = Read-LunqRecipe -Path $Path
            $recipe | Add-Member -NotePropertyName OutputName -NotePropertyValue 'Win11_Lunq' -Force
            $values = Get-LunqRecipeParameters -Recipe $recipe
            $values.OutputName | Should -Be 'Win11_Lunq'
            $values.Contains('OutputIso') | Should -BeFalse
        }
    }

    It 'папки обновлений нет на этом компьютере: путь не берётся, со скачиванием тоже' {
        InModuleScope LunqDebloater -Parameters @{ Path = $script:RecipePath } {
            param($Path)
            $recipe = Read-LunqRecipe -Path $Path
            $recipe.Updates.Path = 'Z:\nowhere'
            (Get-LunqRecipeParameters -Recipe $recipe).Contains('UpdatesPath') | Should -BeFalse
            $recipe.Updates.Path = $Path | Split-Path
            $recipe.Updates.Download = $true
            $values = Get-LunqRecipeParameters -Recipe $recipe
            $values.DownloadUpdates | Should -BeTrue
            $values.Contains('UpdatesPath') | Should -BeFalse
            $values.Contains('SkipUpdates') | Should -BeFalse
        }
    }

    It 'профиль не менялся: берётся сам файл, изменился: копия из рецепта' {
        $temp = Join-Path $script:T.Root 'temp'
        InModuleScope LunqDebloater -Parameters @{ Path = $script:RecipePath; T = $script:T; Temp = $temp } {
            param($Path, $T, $Temp)
            $recipe = Read-LunqRecipe -Path $Path
            $same = Get-LunqRecipeProfile -Recipe $recipe -TempDir $Temp
            $same.Path | Should -Be $T.Profile
            $same.FromRecipe | Should -BeFalse
            Add-Content -LiteralPath $T.Profile -Value ' '
            $copy = Get-LunqRecipeProfile -Recipe $recipe -TempDir $Temp
            $copy.FromRecipe | Should -BeTrue
            $copy.Path | Should -Be (Join-Path $Temp 'Profile.json')
            # Копия читается как обычный профиль.
            Mock Write-Host { }
            @((Read-LunqProfile -Path $copy.Path).Categories).Count | Should -Be @($recipe.Profile.Content.Categories).Count
        }
    }
}

Describe 'Read-LunqRecipe' {
    It 'неподходящий файл: понятная ошибка, а не сбой посреди сборки' {
        $dir = Join-Path $TestDrive 'bad'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'broken.lunq.json') -Value '{ not json'
        Set-Content -LiteralPath (Join-Path $dir 'other.lunq.json') -Value '{ "Kind": "Something" }'
        Set-Content -LiteralPath (Join-Path $dir 'newer.lunq.json') -Value '{ "Kind": "LunqDebloaterRecipe", "FormatVersion": 2, "LunqVersion": "9.0.0" }'
        Set-Content -LiteralPath (Join-Path $dir 'partial.lunq.json') -Value '{ "Kind": "LunqDebloaterRecipe", "FormatVersion": 1, "Iso": {} }'
        InModuleScope LunqDebloater -Parameters @{ Dir = $dir } {
            param($Dir)
            { Read-LunqRecipe -Path (Join-Path $Dir 'none.lunq.json') } | Should -Throw 'Рецепт не найден:*'
            { Read-LunqRecipe -Path (Join-Path $Dir 'broken.lunq.json') } | Should -Throw '*не читается как JSON*'
            { Read-LunqRecipe -Path (Join-Path $Dir 'other.lunq.json') } | Should -Throw '*не рецепт LunqDebloater*'
            { Read-LunqRecipe -Path (Join-Path $Dir 'newer.lunq.json') } | Should -Throw '*более новой версией LunqDebloater (9.0.0)*'
            { Read-LunqRecipe -Path (Join-Path $Dir 'partial.lunq.json') } | Should -Throw '*нет раздела Edition*'
        }
    }
}

Describe 'Compare-LunqRecipeFiles' {
    It 'называет пропавшие, изменённые и новые обновления' {
        InModuleScope LunqDebloater {
            $expected = @(@{ Name = 'a.msu'; Sha256 = '1' }, @{ Name = 'b.msu'; Sha256 = '2' }, @{ Name = 'c.msu'; Sha256 = '3' })
            $actual = @(@{ Name = 'a.msu'; Sha256 = '1' }, @{ Name = 'b.msu'; Sha256 = 'x' }, @{ Name = 'd.msu'; Sha256 = '4' })
            $lines = Compare-LunqRecipeFiles -Expected $expected -Actual $actual
            $lines | Should -Be @(
                'Обновление b.msu изменилось с прошлой сборки.',
                'В прошлой сборке было обновление c.msu, а сейчас его нет.',
                'Обновления d.msu не было в прошлой сборке.')
            (Compare-LunqRecipeFiles -Expected $expected -Actual $expected).Count | Should -Be 0
        }
    }
}

Describe 'Write-LunqHtmlReport' {
    It 'отчёт показывает «до и после» и что убрано по категориям, текст экранирован' {
        $path = Join-Path $TestDrive 'report.lunq.html'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; ProfilePath = $script:Profile } {
            param($Path, $ProfilePath)
            Mock Write-Host { }
            $lunqProfile = Read-LunqProfile -Path $ProfilePath
            $category = @($lunqProfile.Categories | Where-Object { @($_.Appx).Count -gt 0 })[0]
            $appx = New-LunqResult 'Приложения' 'Appx'
            $appx.Total = 40
            $appx.Done.Add('Microsoft.BingNews')
            $other = New-LunqResult 'Обновления <KB>' 'Updates'
            $other.Done.Add('windows11.0-kb5090000-x64.msu')
            # Шаблон категории, под который подходит удалённое приложение.
            $category.Appx = @('Microsoft.BingNews')
            Write-LunqHtmlReport -Path $Path -Results @($appx, $other) -LunqProfile $lunqProfile -Info @{
                IsoPath = 'D:\Win11.iso'; IsoSize = 6GB; OutputIso = 'D:\Win11_Lunq.iso'; OutputSize = 5GB; ProfilePath = $ProfilePath
                Elapsed = [timespan]::FromMinutes(42); RecipePath = 'D:\Win11_Lunq.lunq.json'; EditionName = 'Windows 11 Pro'; BuildText = '26300.7000'
            }
            $html = [IO.File]::ReadAllText($Path)
            $html | Should -Match '^<!doctype html>'
            $html | Should -Match '<title>LunqDebloater: Win11_Lunq\.iso</title>'
            $html | Should -Match '<th>Приложения Appx</th><td class="num">40</td><td class="num">1</td><td class="num">39</td>'
            $html | Should -Match ([regex]::Escape([Net.WebUtility]::HtmlEncode($category.Name)) + '.*убрано: 1')
            $html | Should -Match '<li><code>Microsoft\.BingNews</code></li>'
            $html | Should -Match 'Обновления &lt;KB&gt;'
            $html | Should -Not -Match 'Обновления <KB>'
            $html | Should -Match '00:42:00'
            # Внешних ссылок нет: отчёт открывается без интернета.
            $html | Should -Not -Match '(src|href)="https?:'
        }
    }
}
