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

    It 'с -NoStart ошибка установки даёт код выхода 1: по нему её видит окно' {
        # Чужая папка отклоняется до обращения к сети.
        $foreign = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ForeignExit')
        Set-Content -LiteralPath (Join-Path $foreign.FullName 'photo.jpg') -Value ''
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -ExecutionPolicy Bypass -File $script:Source -Path $foreign.FullName -NoStart 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'not a LunqDebloater folder'
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

    It 'папка, где лежит только окно LunqDebloater.exe, подходит' {
        # Пользователь положил exe в папку и дал ему скачать остальное.
        $window = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'window')
        Set-Content -LiteralPath (Join-Path $window.FullName 'LunqDebloater.exe') -Value ''
        Test-LunqInstallFolder -Path $window.FullName | Should -BeTrue
    }

    It 'клон репозитория не принимается за прежнюю установку, а установка с файлом состояния принимается' {
        # В клоне тоже есть LunqDebloater.ps1, но папки релиза заменились бы целиком вместе с несохранённой работой.
        $clone = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'clone')
        Set-Content -LiteralPath (Join-Path $clone.FullName 'LunqDebloater.ps1') -Value ''
        New-Item -ItemType Directory -Path (Join-Path $clone.FullName '.git') | Out-Null
        Test-LunqInstallFolder -Path $clone.FullName | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $clone.FullName '.lunq-install.json') -Value '{}'
        Test-LunqInstallFolder -Path $clone.FullName | Should -BeTrue
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
        Mock Get-LunqLatestRelease {
            [pscustomobject]@{ Tag = 'v1.7.0'; ZipUrl = 'https://example.invalid/v1.7.0.zip'; ExeUrl = 'https://example.invalid/v1.7.0/LunqDebloater.exe' }
        }
        Mock Invoke-WebRequest { Compress-Archive -Path (Join-Path $script:Archive 'LunqDebloater-1.7.0') -DestinationPath $OutFile } -ParameterFilter { $Uri -like '*.zip' }
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'window v1.7.0' } -ParameterFilter { $Uri -like '*/LunqDebloater.exe' }
    }

    It 'папку установки могут менять только владелец, администраторы и SYSTEM' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $target = Join-Path $TestDrive 'Protected'
        Protect-LunqInstallFolder -Path $target
        $acl = Get-Acl -LiteralPath $target
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        $expected = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-32-544', 'S-1-5-18') | Sort-Object -Unique
        $sids | Should -Be $expected
    }

    It 'скачивает релиз, раскладывает его и запускает LunqDebloater' {
        $target = Join-Path $TestDrive 'Fresh'
        Invoke-LunqInstall -Path $target
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -Be '# v1.7.0'
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be '7zip.7zip'
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.exe') | Should -Be 'window v1.7.0'
        Should -Invoke Start-LunqDebloater -Times 1 -Exactly -ParameterFilter { $Path -eq $target }
    }

    It 'та же версия уже стоит: не скачивает заново' {
        $target = Join-Path $TestDrive 'Same'
        Invoke-LunqInstall -Path $target
        Invoke-LunqInstall -Path $target
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*.zip' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*/LunqDebloater.exe' }
        Should -Invoke Start-LunqDebloater -Times 2 -Exactly
    }

    It 'установке без окна докачивает только окно' {
        # Так выглядят установки до 1.10.0 и те, что прошли раньше, чем к выпуску добавился exe.
        $target = Join-Path $TestDrive 'NoWindow'
        Invoke-LunqInstall -Path $target
        Remove-Item -LiteralPath (Join-Path $target 'LunqDebloater.exe')
        Invoke-LunqInstall -Path $target
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*.zip' }
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $Uri -like '*/LunqDebloater.exe' }
        Test-Path -LiteralPath (Join-Path $target 'LunqDebloater.exe') | Should -BeTrue
    }

    It 'окна в выпуске ещё нет: скрипт ставится и запускается с предупреждением' {
        Mock Invoke-WebRequest { throw 'Response status code does not indicate success: 404 (Not Found).' } -ParameterFilter { $Uri -like '*/LunqDebloater.exe' }
        Mock Write-Warning { }
        $target = Join-Path $TestDrive 'NoAsset'
        Invoke-LunqInstall -Path $target
        Test-Path -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Filter 'LunqDebloater.exe*') | Should -BeNullOrEmpty
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*LunqDebloater.exe*404*' }
        Should -Invoke Start-LunqDebloater -Times 1 -Exactly
    }

    It '-NoStart ставит, но не запускает: так установку делает окно' {
        $target = Join-Path $TestDrive 'FromWindow'
        Invoke-LunqInstall -Path $target -NoStart
        Test-Path -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -BeTrue
        Should -Invoke Start-LunqDebloater -Times 0 -Exactly
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
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*' }
        Should -Invoke Start-LunqDebloater -Times 0 -Exactly
    }
}

Describe 'Get-LunqLatestRelease' {
    It 'API GitHub отказал (лимит запросов): версия берётся со страницы релизов' {
        Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 403 (rate limit exceeded).' }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [uri]'https://github.com/Lunqasd1337/LunqDebloater/releases/tag/v1.9.2' } }
        } -ParameterFilter { $Uri -like '*/releases/latest' }
        $release = Get-LunqLatestRelease
        $release.Tag | Should -Be 'v1.9.2'
        $release.ZipUrl | Should -Be 'https://github.com/Lunqasd1337/LunqDebloater/archive/refs/tags/v1.9.2.zip'
        $release.ExeUrl | Should -Be 'https://github.com/Lunqasd1337/LunqDebloater/releases/download/v1.9.2/LunqDebloater.exe'
        # В PowerShell 7 адрес лежит в RequestMessage.
        Mock Invoke-WebRequest {
            [pscustomobject]@{ BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://github.com/Lunqasd1337/LunqDebloater/releases/tag/v1.9.3' } } }
        } -ParameterFilter { $Uri -like '*/releases/latest' }
        (Get-LunqLatestRelease).Tag | Should -Be 'v1.9.3'
        # Страница не дала тега: видна исходная ошибка API.
        Mock Invoke-WebRequest { [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [uri]'https://github.com/login' } } } -ParameterFilter { $Uri -like '*/releases/latest' }
        { Get-LunqLatestRelease } | Should -Throw '*403*'
    }
}
