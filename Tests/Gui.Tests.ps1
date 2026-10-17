#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Окно на Tauri (папка Gui): его тексты, параметры, которые оно передаёт скрипту, и версия.
# Само окно собирается отдельным заданием CI, здесь проверяется то, что ломается без сборки Rust.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $ui = Join-Path $repo 'Gui\ui'
    $script:AppJs = [IO.File]::ReadAllText((Join-Path $ui 'app.js'))
    $script:IndexHtml = [IO.File]::ReadAllText((Join-Path $ui 'index.html'))
    $stringsJs = [IO.File]::ReadAllText((Join-Path $ui 'strings.js'))

    function Get-GuiStrings {
        # Ключи и тексты одного языка из strings.js: блок от «ru: {» или «en: {» до закрывающей скобки.
        param([string]$Text, [string]$Language)
        $block = [regex]::Match($Text, "(?s)\n  $Language\: \{(.*?)\n  \}").Groups[1].Value
        $table = [ordered]@{}
        foreach ($m in [regex]::Matches($block, "'([\w.]+)':\s*'((?:[^'\\]|\\.)*)'")) { $table[$m.Groups[1].Value] = $m.Groups[2].Value }
        return $table
    }
    $script:Ru = Get-GuiStrings $stringsJs 'ru'
    $script:En = Get-GuiStrings $stringsJs 'en'
}

Describe 'Тексты окна' {
    It 'в ru и en одни и те же ключи и подстановки' {
        $script:Ru.Count | Should -BeGreaterThan 50
        @($script:Ru.Keys) | Should -Be @($script:En.Keys)
        foreach ($key in $script:Ru.Keys) {
            $ruArgs = @([regex]::Matches($script:Ru[$key], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $enArgs = @([regex]::Matches($script:En[$key], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            ($enArgs -join ',') | Should -Be ($ruArgs -join ',') -Because "подстановки в '$key'"
        }
    }

    It 'каждый ключ из app.js и index.html есть в strings.js' {
        $used = @([regex]::Matches($script:AppJs, "\bt\('([\w.]+)'") | ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches($script:IndexHtml, 'data-t="([\w.]+)"') | ForEach-Object { $_.Groups[1].Value })
        $used.Count | Should -BeGreaterThan 30
        $missing = @($used | Sort-Object -Unique | Where-Object { -not $script:Ru.Contains($_) })
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Параметры, которые окно передаёт скрипту' {
    It 'каждый есть у LunqDebloater.ps1' {
        # Окно собирает командную строку из строк вида '-SkipUpdates': переименование параметра
        # в скрипте иначе заметили бы только при сборке.
        $repo = Split-Path $PSScriptRoot -Parent
        $known = @((Get-Command (Join-Path $repo 'LunqDebloater.ps1')).Parameters.Keys)
        $passed = @([regex]::Matches($script:AppJs, "'-([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $passed.Count | Should -BeGreaterThan 15
        $unknown = @($passed | Where-Object { $known -notcontains $_ })
        $unknown | Should -BeNullOrEmpty
        # -EventsPath и -ListEditions добавляет Rust, его строки проверяются отдельно.
        $rust = [IO.File]::ReadAllText((Join-Path $repo 'Gui\src-tauri\src\main.rs'))
        foreach ($name in 'EventsPath', 'ListEditions', 'IsoPath', 'Language') {
            $rust | Should -Match ('"-' + $name + '"')
            $known | Should -Contain $name
        }
    }
}

Describe 'Версия окна' {
    It 'совпадает с версией модуля' {
        $repo = Split-Path $PSScriptRoot -Parent
        $version = (Import-PowerShellDataFile (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1')).ModuleVersion
        $cargo = [IO.File]::ReadAllText((Join-Path $repo 'Gui\src-tauri\Cargo.toml'))
        $cargo | Should -Match ('(?m)^version = "' + [regex]::Escape($version) + '"')
        $conf = [IO.File]::ReadAllText((Join-Path $repo 'Gui\src-tauri\tauri.conf.json')) | ConvertFrom-Json
        $conf.version | Should -Be $version
    }
}
