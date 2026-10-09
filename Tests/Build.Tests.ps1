#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Сквозные проверки: LunqDebloater.ps1 целиком, с заглушкой DISM вместо настоящего образа.
# Каждый тест работает со своей копией скрипта в TestDrive и ничего не меняет в системе.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function Start-TestBuild {
        # Новая копия скрипта, запуск с параметрами и возврат вывода.
        param([hashtable]$Parameters = @{}, [string[]]$Answers, [switch]$Interactive, [scriptblock]$Prepare)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Test = New-LunqTestApp -Root $root
        Enter-LunqTestEnvironment -Test $script:Test
        try {
            if ($Prepare) { & $Prepare $script:Test }
            $all = @{}
            if (-not $Interactive) {
                $all = @{ IsoPath = $script:Test.Iso; Index = 5; WorkDir = $script:Test.WorkDir; KeepWorkDir = $true; Force = $true }
            }
            else { $all = @{ WorkDir = $script:Test.WorkDir } }
            foreach ($key in $Parameters.Keys) { $all[$key] = $Parameters[$key] }
            if ($Interactive) { return Invoke-LunqTestRun -Test $script:Test -Parameters $all -Answers $Answers }
            return Invoke-LunqTestRun -Test $script:Test -Parameters $all
        }
        finally { Exit-LunqTestEnvironment }
    }

    function Assert-Steps {
        # Шаги идут подряд с 1 и заканчиваются на общем числе.
        param([Parameter(Mandatory)][string]$Output, [int]$Expected)
        $steps = Get-LunqStepNumbers -Output $Output
        $steps.Count | Should -Be $Expected
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $steps[$i].N | Should -Be ($i + 1)
            $steps[$i].M | Should -Be $Expected
        }
    }
}

Describe 'Сборка с параметрами' {
    It 'полная сборка доходит до конца, шаги посчитаны верно' {
        $root = Join-Path $TestDrive 'full'
        $t = New-LunqTestApp -Root $root
        Enter-LunqTestEnvironment -Test $t
        try {
            $run = Invoke-LunqTestRun -Test $t -Parameters @{
                IsoPath = $t.Iso; Index = 5; WorkDir = $t.WorkDir; KeepWorkDir = $true; Force = $true
                UpdatesPath = $t.Updates; DriversPath = $t.Drivers; UpdatesToSetup = $true; DriversToSetup = $true; CleanupComponents = $true
            }
        }
        finally { Exit-LunqTestEnvironment }
        $run.Error | Should -BeNullOrEmpty
        # 7 обязательных шагов, обновления, драйверы, WinRE и установщик, первый вход, Appx,
        # компоненты (2), реестр и очистка.
        Assert-Steps -Output $run.Output -Expected 17
        Test-Path -LiteralPath $t.OutputIso | Should -BeTrue
        $run.Output | Should -Match 'Драйверы: добавлено 2, ошибок 1'
        $run.Output | Should -Match 'Обновления в установщике: установлено 2'
        $run.Output | Should -Match 'Очистка хранилища компонентов: старые версии системных файлов удалены'
        # После обновления boot.wim setup.exe в sources берётся из него, иначе версии не совпадут.
        $run.Output | Should -Match 'Файлы установщика: setup.exe, setuphost.exe скопированы из boot.wim в sources'
        Get-Content -LiteralPath (Join-Path $t.WorkDir 'iso\sources\setup.exe') | Should -Be 'from boot.wim'

        $native = Get-Content -LiteralPath $t.NativeLog -Encoding UTF8
        # Очистка идёт через dism.exe: в основном образе, в WinRE и в установщике.
        @($native | Where-Object { $_ -like 'dism.exe|*/StartComponentCleanup|/ResetBase*' }).Count | Should -Be 3
        $registry = Get-Content -LiteralPath $t.RegLog -Encoding UTF8
        $registry | Should -Contain 'set|HKLM\LUNQ_SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry|DWord|0'
        $registry | Should -Contain 'set|HKLM\LUNQ_SOFTWARE\LunqDebloater|CleanupComponents|String|да'
        # Категория drivers выключена по умолчанию.
        ($registry -join "`n") | Should -Not -Match 'DriverSearching'
    }

    It 'Safe OS и Setup Dynamic Update из подпапок Updates' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true; UpdatesToSetup = $true } -Prepare {
            param($t)
            $updates = Join-Path $t.App 'Config\Updates'
            New-Item -ItemType Directory -Path (Join-Path $updates 'SafeOS'), (Join-Path $updates 'Setup') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $updates 'windows11.0-kb5080000-x64.msu') -Value 'msu'
            Set-Content -LiteralPath (Join-Path $updates 'SafeOS\windows11.0-kb5080100-x64.cab') -Value 'cab'
            Set-Content -LiteralPath (Join-Path $updates 'Setup\windows11.0-kb5080200-x64.cab') -Value 'cab'
        }
        $run.Error | Should -BeNullOrEmpty
        # Обязательные шаги и профиль (11), обновления, WinRE и установщик.
        Assert-Steps -Output $run.Output -Expected 14
        $run.Output | Should -Match 'Установщик/WinRE: обновления \(1 шт\.\), Safe OS Dynamic Update \(1 шт\.\) и Setup Dynamic Update \(1 шт\.\)'
        # В систему идёт только накопительное обновление из самой папки Updates.
        $run.Output | Should -Match 'Обновления:\s+1 шт\.'
        $run.Output | Should -Match 'Safe OS Dynamic Update в WinRE: установлено 1, ошибок 0'
        $run.Output | Should -Match 'Setup Dynamic Update: установлено 1, ошибок 0'
        $run.Output | Should -Match 'Файлы установщика: setup.exe, setuphost.exe скопированы'
        $expand = @(Get-Content -LiteralPath $script:Test.NativeLog -Encoding UTF8 | Where-Object { $_ -like 'expand.exe|*' })
        $expand.Count | Should -Be 1
        $expand[0] | Should -BeLike '*windows11.0-kb5080200-x64.cab|-F:`*|*iso?sources|*'
    }

    It 'Setup Dynamic Update без других обновлений: WinRE не трогается' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true; UpdatesToSetup = $true } -Prepare {
            param($t)
            $setup = Join-Path $t.App 'Config\Updates\Setup'
            New-Item -ItemType Directory -Path $setup -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $setup 'windows11.0-kb5080200-x64.cab') -Value 'cab'
        }
        $run.Error | Should -BeNullOrEmpty
        Assert-Steps -Output $run.Output -Expected 12
        $run.Output | Should -Not -Match 'Среда восстановления \(WinRE\)'
        $run.Output | Should -Match 'Setup Dynamic Update: установлено 1'
    }

    It 'Safe OS и Setup Dynamic Update без -UpdatesToSetup не встраиваются' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true } -Prepare {
            param($t)
            $safeOS = Join-Path $t.App 'Config\Updates\SafeOS'
            New-Item -ItemType Directory -Path $safeOS -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $safeOS 'windows11.0-kb5080100-x64.cab') -Value 'cab'
        }
        $run.Error | Should -BeNullOrEmpty
        Assert-Steps -Output $run.Output -Expected 11
        $run.Output | Should -Match 'Safe OS и Setup Dynamic Update не встраиваются без -UpdatesToSetup'
        $run.Output | Should -Not -Match 'Safe OS Dynamic Update в WinRE'
    }

    It 'без обновлений и драйверов: только обязательные шаги и профиль' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true }
        $run.Error | Should -BeNullOrEmpty
        Assert-Steps -Output $run.Output -Expected 11
        $run.Output | Should -Match 'Установка:\s+без файла ответов'
    }

    It 'с -SkipAppx -SkipComponents -SkipRegistry шагов профиля нет' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true; SkipAppx = $true; SkipComponents = $true; SkipRegistry = $true }
        $run.Error | Should -BeNullOrEmpty
        Assert-Steps -Output $run.Output -Expected 7
    }

    It 'файл ответов с обходом требований и локальной учётной записью' {
        $run = Start-TestBuild -Parameters @{ BypassRequirements = $true; LocalAccount = $true }
        $run.Error | Should -BeNullOrEmpty
        $xmlPath = Join-Path $script:Test.WorkDir 'iso\autounattend.xml'
        Test-Path -LiteralPath $xmlPath | Should -BeTrue
        $xml = [xml](Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8)
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        @(Select-Xml -Xml $xml -XPath '//u:RunSynchronousCommand' -Namespace $ns).Count | Should -Be 3
        (Select-Xml -Xml $xml -XPath '//u:HideOnlineAccountScreens' -Namespace $ns).Node.InnerText | Should -Be 'true'
        # Программы из Apps.txt есть, поэтому команда первого входа тоже в файле ответов.
        (Select-Xml -Xml $xml -XPath '//u:FirstLogonCommands//u:CommandLine' -Namespace $ns).Node.InnerText | Should -BeLike '*FirstLogon.ps1*'
        $run.Output | Should -Match 'В ISO уже есть файл ответов LunqDebloater'
    }

    It 'режим «Что в образе» сохраняет список и ничего не собирает' {
        $run = Start-TestBuild -Parameters @{ ListContents = $true }
        $run.Error | Should -BeNullOrEmpty
        Assert-Steps -Output $run.Output -Expected 4
        $contents = Join-Path $script:Test.Root 'Win11_5_contents.txt'
        Test-Path -LiteralPath $contents | Should -BeTrue
        Get-Content -LiteralPath $contents -Raw -Encoding UTF8 | Should -Match 'Microsoft\.BingNews\s+\[apps\]'
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeFalse
    }
}

Describe 'Ошибки и предупреждения' {
    It 'нет папки для итогового ISO: остановка до сборки' {
        $run = Start-TestBuild -Parameters @{ OutputIso = (Join-Path $TestDrive 'missing\out.iso') }
        $run.Error | Should -Not -BeNullOrEmpty
        $run.Output | Should -Match '\[FAIL\] Итоговый ISO'
        Get-LunqStepNumbers -Output $run.Output | Should -BeNullOrEmpty
    }

    It 'чужая папка с подпапкой iso: проверка её отвергает, и она не удаляется' {
        $run = Start-TestBuild -Parameters @{ KeepWorkDir = $false } -Prepare {
            param($t)
            New-Item -ItemType Directory -Path (Join-Path $t.WorkDir 'iso') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $t.WorkDir 'mine.txt') -Value 'x'
        }
        $run.Error | Should -Not -BeNullOrEmpty
        $run.Output | Should -Match 'папка не пустая и создана не этим скриптом'
        Test-Path -LiteralPath (Join-Path $script:Test.WorkDir 'mine.txt') | Should -BeTrue
    }

    It 'несколько Setup Dynamic Update: в sources распаковывается каждый .cab и только они' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true; UpdatesToSetup = $true } -Prepare {
            param($t)
            $setup = Join-Path $t.App 'Config\Updates\Setup'
            New-Item -ItemType Directory -Path $setup -Force | Out-Null
            foreach ($name in 'windows11.0-kb5080200-x64.cab', 'windows11.0-kb5080201-x64.cab', 'windows11.0-kb5080202-x64.msu') {
                Set-Content -LiteralPath (Join-Path $setup $name) -Value 'x'
            }
        }
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Match 'Setup Dynamic Update: установлено 2'
        $expand = @(Get-Content -LiteralPath $script:Test.NativeLog -Encoding UTF8 | Where-Object { $_ -like 'expand.exe|*' })
        $expand.Count | Should -Be 2
        ($expand -join "`n") | Should -Not -Match '\.msu'
    }

    It 'сбой посреди сборки: образ отключается без сохранения, ISO не создаётся' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true } -Prepare { $env:LUNQ_TEST_FAIL_APPX = '1' }
        $run.Error | Should -Not -BeNullOrEmpty
        $run.Output | Should -Match 'Ошибка: DISM failure to test the rollback'
        $run.Output | Should -Match 'Отключаю образ без сохранения'
        $run.Output | Should -Match 'dismount .*mount save=False discard=True'
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeFalse
    }

    It 'неудачная очистка хранилища не срывает сборку' {
        $run = Start-TestBuild -Parameters @{ CleanupComponents = $true; SkipApps = $true } -Prepare { $env:LUNQ_TEST_DISM_EXIT = '1' }
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Match 'Очистка хранилища компонентов: не удалась'
        $run.Output | Should -Match 'Не удалось: StartComponentCleanup'
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeTrue
    }

    It 'остаток прерванного запуска в своей папке: без предупреждения' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true } -Prepare {
            param($t)
            $env:LUNQ_TEST_MOUNTED = Join-Path $t.WorkDir 'mount'
        }
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Match 'Остался образ от прерванного запуска'
        $run.Output | Should -Not -Match 'В системе уже есть смонтированные образы'
    }

    It 'система старше образа: предупреждение, сборка продолжается' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true } -Prepare { $env:LUNQ_TEST_HOST_BUILD = '19045' }
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Match '\[ !! \] Windows на этом компьютере \(сборка 19045 \(Windows 10\)\) старше образа'
    }

    It 'сборка не подходит профилю: остановка с подсказкой' {
        $run = Start-TestBuild -Prepare { $env:LUNQ_TEST_IMAGE_VERSION = '10.0.26200.100' }
        $run.Error | Should -Not -BeNullOrEmpty
        $run.Output | Should -Match 'профиль рассчитан на сборку 26300'
    }

    It 'рабочая папка с пробелом: oscdimg получает пути без пробелов' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true } -Prepare {
            param($t)
            $t.WorkDir = Join-Path $t.Root 'my work'
        }
        $run.Error | Should -BeNullOrEmpty
        $oscdimg = @(Get-Content -LiteralPath $script:Test.NativeLog -Encoding UTF8 | Where-Object { $_ -like 'oscdimg.exe|*' })
        $oscdimg.Count | Should -Be 1
        $parts = $oscdimg[0] -split '\|'
        $bootData = $parts | Where-Object { $_ -like '-bootdata:*' }
        $bootData | Should -Not -BeNullOrEmpty
        $bootData | Should -Not -Match '\s'
        $parts[-1] | Should -BeLike '*my work'
    }
}

Describe 'Реестр из своего профиля' {
    It 'значение с кавычками записывается без искажений' {
        $run = Start-TestBuild -Parameters @{ SkipApps = $true } -Prepare {
            param($t)
            $profilePath = Join-Path $t.App 'Config\Profile.json'
            $custom = @{
                Name       = 'Quotes'
                Categories = @(@{
                        Id = 'run'; Name = 'Автозапуск'
                        Registry = @(@{ Hive = 'DefaultUser'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'App'; Type = 'REG_SZ'; Value = '"C:\Program Files\App\app.exe" /min' })
                    })
            }
            $custom | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $profilePath -Encoding UTF8
        }
        $run.Error | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:Test.RegLog -Encoding UTF8 | Should -Contain 'set|HKLM\LUNQ_NTUSER\Software\Microsoft\Windows\CurrentVersion\Run|App|String|"C:\Program Files\App\app.exe" /min'
    }
}

Describe 'Пошаговый режим' {
    It 'сборка с ответами по умолчанию: файл ответов включён' {
        # Ответы: [1] собрать, Enter для категорий, Enter для сводки, номер редакции, Y на план.
        $run = Start-TestBuild -Interactive -Answers @('1', '', '', '5', 'y')
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Match 'Установка:\s+файл ответов'
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Test.WorkDir 'iso') | Should -BeFalse
    }

    It 'отказ на плане: ничего не собирается' {
        $run = Start-TestBuild -Interactive -Answers @('1', '', '', '5', 'n')
        $run.Output | Should -Match 'Сборка отменена'
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeFalse
    }
}

Describe 'Английский интерфейс' {
    It 'полная сборка: ни одной русской буквы в выводе' {
        # Обновления и драйверы кладутся в Config копии скрипта, чтобы шли все шаги.
        $run = Start-TestBuild -Parameters @{
            Language = 'en'; UpdatesToSetup = $true; DriversToSetup = $true; CleanupComponents = $true; BypassRequirements = $true
        } -Prepare {
            param($t)
            Copy-Item -Path (Join-Path $t.Updates '*') -Destination (Join-Path $t.App 'Config\Updates') -Force
            Copy-Item -Path (Join-Path $t.Drivers '*') -Destination (Join-Path $t.App 'Config\Drivers') -Recurse -Force
            foreach ($folder in 'SafeOS', 'Setup') {
                $path = Join-Path $t.App "Config\Updates\$folder"
                New-Item -ItemType Directory -Path $path -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $path "windows11.0-kb50801$($folder.Length)-x64.cab") -Value 'cab'
            }
        }
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Not -Match '[А-Яа-яЁё]'
        # Все 18 шагов: как в полной сборке выше, плюс файл ответов.
        Assert-Steps -Output $run.Output -Expected 18
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeTrue
    }

    It 'пошаговый режим: ни одной русской буквы в выводе' {
        $run = Start-TestBuild -Interactive -Parameters @{ Language = 'en' } -Answers @('1', '', '', '5', 'y')
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Not -Match '[А-Яа-яЁё]'
        Test-Path -LiteralPath $script:Test.OutputIso | Should -BeTrue
    }

    It 'режим «Что в образе»: список без русских букв' {
        $run = Start-TestBuild -Parameters @{ Language = 'en'; ListContents = $true }
        $run.Error | Should -BeNullOrEmpty
        $run.Output | Should -Not -Match '[А-Яа-яЁё]'
        Get-Content -LiteralPath (Join-Path $script:Test.Root 'Win11_5_contents.txt') -Raw -Encoding UTF8 | Should -Not -Match '[А-Яа-яЁё]'
    }

    It 'ошибка до сборки тоже на английском' {
        $run = Start-TestBuild -Parameters @{ Language = 'en'; OutputIso = (Join-Path $TestDrive 'missing\out.iso') }
        $run.Error | Should -Not -BeNullOrEmpty
        $run.Output | Should -Match '\[FAIL\]'
        ($run.Output + $run.Error.ToString()) | Should -Not -Match '[А-Яа-яЁё]'
    }
}
