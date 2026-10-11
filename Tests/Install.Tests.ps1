#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Проверки загрузчика Install.ps1 (запуск одной командой irm | iex). Сеть и запуск LunqDebloater
# заменены заглушками, релиз собирается в TestDrive.

BeforeAll {
    $script:Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install.ps1'
    # Функции загрузчика берутся из его текста без выполнения: в конце файла стоит сам запуск.
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($script:Source, [ref]$tokens, [ref]$errors)
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    function New-TestRelease {
        # Распакованный релиз: главный скрипт, модуль и Config.
        param([string]$Root, [string]$Version, [hashtable]$Config)
        New-Item -ItemType Directory -Path (Join-Path $Root 'Modules\LunqDebloater\Private') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'LunqDebloater.ps1') -Value "# $Version"
        Set-Content -LiteralPath (Join-Path $Root "Modules\LunqDebloater\Private\$Version.ps1") -Value "# $Version"
        foreach ($name in $Config.Keys) {
            $file = Join-Path (Join-Path $Root 'Config') $name
            New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
            Set-Content -LiteralPath $file -Value $Config[$name]
        }
    }

    $script:OldOS = $env:OS
    $env:OS = 'Windows_NT'
}

AfterAll {
    $env:OS = $script:OldOS
}

Describe 'Install.ps1' {
    It 'только ASCII и без BOM: irm передаёт его в iex текстом' {
        $bytes = [IO.File]::ReadAllBytes($script:Source)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'разбирается без ошибок' {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($script:Source, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Test-LunqInstallFolder' {
    It 'новая, пустая папка и прежняя установка подходят, чужая папка нет' {
        Test-LunqInstallFolder -Path (Join-Path $TestDrive 'none') | Should -BeTrue
        $empty = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty')
        Test-LunqInstallFolder -Path $empty.FullName | Should -BeTrue
        $own = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'own')
        Set-Content -LiteralPath (Join-Path $own.FullName 'LunqDebloater.ps1') -Value ''
        Test-LunqInstallFolder -Path $own.FullName | Should -BeTrue
        $foreign = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'foreign')
        Set-Content -LiteralPath (Join-Path $foreign.FullName 'photo.jpg') -Value ''
        Test-LunqInstallFolder -Path $foreign.FullName | Should -BeFalse
    }
}

Describe 'Install-LunqFiles' {
    It 'обновление заменяет программу, а изменённые пользователем файлы Config оставляет' {
        $target = Join-Path $TestDrive 'Lunq'
        $old = Join-Path $TestDrive 'v1'
        New-TestRelease -Root $old -Version 'v1' -Config @{ 'Apps.txt' = 'v1'; 'Profile.json' = 'v1' }
        @(Install-LunqFiles -Source $old -Destination $target -Tag 'v1') | Should -BeNullOrEmpty

        # Пользователь правит Apps.txt и кладёт рядом свой ISO.
        Set-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') -Value 'my apps'
        Set-Content -LiteralPath (Join-Path $target 'Win11.iso') -Value 'iso'

        $new = Join-Path $TestDrive 'v2'
        New-TestRelease -Root $new -Version 'v2' -Config @{ 'Apps.txt' = 'v2'; 'Profile.json' = 'v2'; 'Scripts\10-new.ps1' = 'v2' }
        $kept = Install-LunqFiles -Source $new -Destination $target -Tag 'v2'

        $kept | Should -Be @('Apps.txt')
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be 'my apps'
        Get-Content -LiteralPath (Join-Path $target 'Config\Profile.json') | Should -Be 'v2'
        Get-Content -LiteralPath (Join-Path $target 'Config\Scripts\10-new.ps1') | Should -Be 'v2'
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -Be '# v2'
        # Файл, убранный из модуля, не остаётся и не подключается.
        Test-Path -LiteralPath (Join-Path $target 'Modules\LunqDebloater\Private\v1.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'Modules\LunqDebloater\Private\v2.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'Win11.iso') | Should -BeTrue
        (Get-LunqInstallState -Path $target).Tag | Should -Be 'v2'
    }

    It 'изменённый файл остаётся и на следующих обновлениях' {
        $target = Join-Path $TestDrive 'Lunq2'
        $v1 = Join-Path $TestDrive 'r1'
        New-TestRelease -Root $v1 -Version 'v1' -Config @{ 'Apps.txt' = 'v1' }
        Install-LunqFiles -Source $v1 -Destination $target -Tag 'v1' | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') -Value 'my apps'
        foreach ($version in 'v2', 'v3') {
            $release = Join-Path $TestDrive "r$version"
            New-TestRelease -Root $release -Version $version -Config @{ 'Apps.txt' = $version }
            Install-LunqFiles -Source $release -Destination $target -Tag $version | Should -Be @('Apps.txt')
        }
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be 'my apps'
    }
}

Describe 'Invoke-LunqInstall' {
    BeforeEach {
        $script:Archive = Join-Path $TestDrive ('archive-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-TestRelease -Root (Join-Path $script:Archive 'LunqDebloater-1.7.0') -Version 'v1.7.0' -Config @{ 'Apps.txt' = '7zip.7zip' }
        Mock Write-Host { }
        Mock Start-LunqDebloater { }
        Mock Get-LunqLatestRelease { [pscustomobject]@{ Tag = 'v1.7.0'; ZipUrl = 'https://example.invalid/v1.7.0.zip' } }
        Mock Invoke-WebRequest { Compress-Archive -Path (Join-Path $script:Archive 'LunqDebloater-1.7.0') -DestinationPath $OutFile }
    }

    It 'скачивает релиз, раскладывает его и запускает LunqDebloater' {
        $target = Join-Path $TestDrive 'Fresh'
        Invoke-LunqInstall -Path $target
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -Be '# v1.7.0'
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be '7zip.7zip'
        Should -Invoke Start-LunqDebloater -Times 1 -Exactly -ParameterFilter { $Path -eq $target }
    }

    It 'та же версия уже стоит: не скачивает заново' {
        $target = Join-Path $TestDrive 'Same'
        Invoke-LunqInstall -Path $target
        Invoke-LunqInstall -Path $target
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-LunqDebloater -Times 2 -Exactly
    }

    It 'GitHub недоступен: запускает установленную версию' {
        $target = Join-Path $TestDrive 'Offline'
        Invoke-LunqInstall -Path $target
        Mock Get-LunqLatestRelease { throw 'нет сети' }
        Mock Write-Warning { }
        Invoke-LunqInstall -Path $target
        Should -Invoke Write-Warning -Times 1 -Exactly
        Should -Invoke Start-LunqDebloater -Times 2 -Exactly
    }

    It 'чужую папку не трогает' {
        $foreign = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Photos')
        Set-Content -LiteralPath (Join-Path $foreign.FullName 'photo.jpg') -Value ''
        { Invoke-LunqInstall -Path $foreign.FullName } | Should -Throw '*not a LunqDebloater folder*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Start-LunqDebloater -Times 0 -Exactly
    }
}
