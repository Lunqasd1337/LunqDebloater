#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Модуль целиком: манифест, справка скрипта, аргументы перезапуска и таблицы строк.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru
    $script:ProfilePath = Join-Path $repo 'Config\Profile.json'

    function New-TestProfile {
        # Профиль во временной папке из готового объекта.
        param([Parameter(Mandatory)]$Content)
        $path = Join-Path $TestDrive ("profile_{0}.json" -f [guid]::NewGuid().ToString('N'))
        $Content | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Манифест и версия' {
    It 'версия берётся из манифеста' {
        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\LunqDebloater\LunqDebloater.psd1')
        Get-LunqVersion | Should -Be $manifest.ModuleVersion
    }

    It 'внутренние функции не видны снаружи' {
        Get-Command -Module LunqDebloater -Name Invoke-Native -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command -Module LunqDebloater -Name Write-LunqReport | Should -Not -BeNullOrEmpty
    }

    It 'каждая функция из FunctionsToExport есть в модуле' {
        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\LunqDebloater\LunqDebloater.psd1')
        foreach ($name in $manifest.FunctionsToExport) {
            Get-Command -Module LunqDebloater -Name $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $name
        }
    }

    It 'скрипты и README в Config сохранены в UTF-8 с BOM' {
        # Без BOM Windows PowerShell 5.1 читает русский текст как ANSI. Install.ps1 исключение:
        # он только в ASCII, его проверяет Tests\Install.Tests.ps1.
        $repo = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
                Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Name -ne 'Install.ps1' })
        $files += @(Get-ChildItem -LiteralPath (Join-Path $repo 'Config') -File -Filter 'README*.txt')
        $files.Count | Should -BeGreaterThan 30
        $noBom = @($files | Where-Object {
                $bytes = New-Object byte[] 3
                $stream = [IO.File]::OpenRead($_.FullName)
                try { $read = $stream.Read($bytes, 0, 3) } finally { $stream.Dispose() }
                -not ($read -eq 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            } | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
        $noBom | Should -BeNullOrEmpty
    }

    It 'наружу видны только функции, которые вызывает LunqDebloater.ps1' {
        $repo = Split-Path $PSScriptRoot -Parent
        $manifest = Import-PowerShellDataFile (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1')
        $script = Get-Content -LiteralPath (Join-Path $repo 'LunqDebloater.ps1') -Raw
        $unused = @($manifest.FunctionsToExport | Where-Object { $script -notmatch ('(?<![\w-])' + [regex]::Escape($_) + '(?![\w-])') })
        $unused | Should -BeNullOrEmpty
    }
}

Describe 'Справка скрипта' {
    It 'Get-Help показывает описание и ссылку на GitHub' {
        $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'LunqDebloater.ps1'
        $help = Get-Help $script -Full
        $help.Synopsis | Should -Match 'Windows 11'
        # Get-Help -Online открывает первую ссылку.
        @($help.relatedLinks.navigationLink)[0].uri | Should -BeLike 'https://github.com/*'
    }

    It 'каждый параметр описан в README.md и README.en.md' {
        # Подробная справка живёт только в README, поэтому новый параметр нельзя забыть там.
        $repo = Split-Path $PSScriptRoot -Parent
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        $names = @((Get-Command (Join-Path $repo 'LunqDebloater.ps1')).Parameters.Keys | Where-Object { $common -notcontains $_ })
        foreach ($readme in 'README.md', 'README.en.md') {
            $text = [IO.File]::ReadAllText((Join-Path $repo $readme))
            foreach ($name in $names) {
                $text | Should -Match "``-$name\b" -Because "-$name должен быть в $readme"
            }
        }
    }
}

Describe 'ConvertTo-LunqArgumentList' {
    It 'ключи, списки и значения' {
        $bound = [ordered]@{ Index = 6; SkipCategory = @('drivers', 'store'); Force = [switch]$true; KeepWorkDir = [switch]$false }
        $result = ConvertTo-LunqArgumentList -BoundParameters $bound
        $result | Should -Be @('-Index', '6', '-SkipCategory', 'drivers,store', '-Force')
    }

    It 'в кавычках обратная косая черта в конце удваивается' {
        $bound = [ordered]@{ DriversPath = 'D:\' ; Label = 'MY WIN' }
        $result = ConvertTo-LunqArgumentList -BoundParameters $bound -Quote
        $result | Should -Be @('-DriversPath', '"D:\\"', '-Label', '"MY WIN"')
    }

    It 'относительные пути становятся полными' {
        $bound = [ordered]@{ WorkDir = 'work' }
        $result = ConvertTo-LunqArgumentList -BoundParameters $bound -PathParameters 'WorkDir'
        [IO.Path]::IsPathRooted($result[1]) | Should -BeTrue
    }
}

Describe 'Лог' {
    It 'вывод внешней программы попадает в лог, только если она завершилась с ошибкой' {
        # Внешняя программа: тот же PowerShell, который выполняет тесты.
        $shell = (Get-Process -Id $PID).Path
        & (Get-Module LunqDebloater) {
            param($shell)
            $failed = & { Invoke-Native $shell @('-NoProfile', '-Command', 'Write-Output first; Write-Output second; exit 3') } 6>&1
            @($failed | Where-Object { $_ -is [int] }) | Should -Be @(3)
            $text = ($failed | Where-Object { $_ -isnot [int] } | Out-String)
            $text | Should -Match 'завершился с кодом 3'
            $text | Should -Match 'second'
            # Код из -SuccessCodes считается успехом: вывода нет.
            $ok = & { Invoke-Native $shell @('-NoProfile', '-Command', 'Write-Output quiet; exit 1') -SuccessCodes 0, 1 } 6>&1
            @($ok | Where-Object { $_ -isnot [int] }).Count | Should -Be 0
        } $shell
    }

    It 'архив для отчёта: логи и профиль с заменёнными путём профиля и именами' {
        $dir = Join-Path $TestDrive 'logs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $log = [pscustomobject]@{ Path = Join-Path $dir 'LunqDebloater_1.log'; DismPath = Join-Path $dir 'LunqDebloater_1_dism.log' }
        Set-Content -LiteralPath $log.Path -Value @('Путь: C:\Users\Nikolai\Downloads\Win11.iso', 'Компьютер PC-NIKOLAI, пользователь Nikolai, папка Users') -Encoding UTF8
        Set-Content -LiteralPath $log.DismPath -Value 'Image path C:\USERS\NIKOLAI\work' -Encoding ASCII
        $replace = [ordered]@{ 'C:\Users\Nikolai' = '%USERPROFILE%'; 'Nikolai' = '<user>'; 'PC-NIKOLAI' = '<computer>' }

        $zip = New-LunqBugReport -Log $log -ProfilePath (Join-Path $dir 'none.json') -Replace $replace
        $zip | Should -Be (Join-Path $dir 'LunqDebloater_1_report.zip')
        $out = Join-Path $TestDrive 'report'
        Expand-Archive -LiteralPath $zip -DestinationPath $out
        $names = @(Get-ChildItem -LiteralPath $out | ForEach-Object { $_.Name })
        $names.Count | Should -Be 2
        $names | Should -Contain 'LunqDebloater_1.log'
        $names | Should -Contain 'LunqDebloater_1_dism.log'
        $text = Get-Content -LiteralPath (Join-Path $out 'LunqDebloater_1.log') -Raw -Encoding UTF8
        $text | Should -Match ([regex]::Escape('Путь: %USERPROFILE%\Downloads\Win11.iso'))
        $text | Should -Match 'Компьютер <computer>, пользователь <user>, папка Users'
        Get-Content -LiteralPath (Join-Path $out 'LunqDebloater_1_dism.log') -Raw | Should -Match ([regex]::Escape('%USERPROFILE%\work'))
    }
}

Describe 'Один запуск за раз' {
    It 'второй запуск не получает мьютекс, пока первый его держит' {
        $name = 'Global\LunqDebloaterTest_' + [guid]::NewGuid().ToString('N')
        $ready = New-Object System.Threading.ManualResetEvent($false)
        $release = New-Object System.Threading.ManualResetEvent($false)
        # Первый запуск изображает другой поток: мьютекс принадлежит потоку, а не процессу.
        $other = [powershell]::Create()
        $null = $other.AddScript({
                param($Name, $Ready, $Release)
                $m = New-Object System.Threading.Mutex($false, $Name)
                $null = $m.WaitOne()
                $null = $Ready.Set()
                $null = $Release.WaitOne(30000)
                $m.ReleaseMutex()
                $m.Dispose()
            }).AddArgument($name).AddArgument($ready).AddArgument($release)
        $handle = $other.BeginInvoke()
        try {
            $ready.WaitOne(10000) | Should -BeTrue
            Enter-LunqRunLock -Name $name | Should -BeNullOrEmpty
        }
        finally {
            $null = $release.Set()
            $other.EndInvoke($handle)
            $other.Dispose()
        }
        $lock = Enter-LunqRunLock -Name $name
        $lock | Should -Not -BeNullOrEmpty
        Exit-LunqRunLock -Lock $lock
    }
}

Describe 'Размер логов' {
    It 'лог DISM в конце запуска сжимается в архив рядом' {
        $log = Join-Path $TestDrive 'LunqDebloater_2_dism.log'
        Set-Content -LiteralPath $log -Value (1..2000 | ForEach-Object { "2026-10-15 01:00:00, Info DISM line $_" }) -Encoding ASCII
        $zip = Compress-LunqDismLog -Path $log
        $zip | Should -Be (Join-Path $TestDrive 'LunqDebloater_2_dism.zip')
        Test-Path -LiteralPath $log | Should -BeFalse
        (Get-Item -LiteralPath $zip).Length | Should -BeLessThan 20000
        $out = Join-Path $TestDrive 'dism'
        Expand-Archive -LiteralPath $zip -DestinationPath $out
        @(Get-Content -LiteralPath (Join-Path $out 'LunqDebloater_2_dism.log')).Count | Should -Be 2000
        # Лога нет, например сборка не дошла до DISM: и архива нет.
        Compress-LunqDismLog -Path (Join-Path $TestDrive 'none_dism.log') | Should -BeNullOrEmpty
    }

    It 'большой лог DISM попадает в отчёт сокращённым: ошибки, метки шагов и конец лога' {
        $dir = Join-Path $TestDrive 'big'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $log = [pscustomobject]@{ Path = Join-Path $dir 'LunqDebloater_3.log'; DismPath = Join-Path $dir 'LunqDebloater_3_dism.log' }
        Set-Content -LiteralPath $log.Path -Value 'run log' -Encoding UTF8
        $lines = @('===== LunqDebloater 2026-10-15 01:00:00: step 5/9: Updates =====')
        $lines += 1..500 | ForEach-Object { "2026-10-15 01:00:00, Info                  DISM   middle $_" }
        $lines += '2026-10-15 01:00:01, Error                 DISM   DISM Package Manager: Failed hr:0x800f081e'
        $lines += 1..500 | ForEach-Object { "2026-10-15 01:00:02, Info                  DISM   end $_" }
        Set-Content -LiteralPath $log.DismPath -Value $lines -Encoding ASCII

        $zip = New-LunqBugReport -Log $log -Replace ([ordered]@{}) -MaxDismBytes 1KB -DismTail 100
        $out = Join-Path $TestDrive 'bigreport'
        Expand-Archive -LiteralPath $zip -DestinationPath $out
        $copy = Join-Path $out 'LunqDebloater_3_dism.log'
        # Лог DISM в ANSI, а копия в UTF-8 с BOM: русская пометка читается в любой Windows.
        $bom = [IO.File]::ReadAllBytes($copy)[0..2]
        $bom | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = Get-Content -LiteralPath $copy -Raw -Encoding UTF8
        $text | Should -Match 'Лог DISM сокращён для отчёта'
        $text | Should -Match 'step 5/9: Updates'
        $text | Should -Match 'Failed hr:0x800f081e'
        $text | Should -Match 'end 500'
        $text | Should -Match 'end 401\b'
        $text | Should -Not -Match 'end 400\b'
        $text | Should -Not -Match 'middle 250\b'
    }

    It 'старые логи DISM удаляются и в виде архива' {
        $dir = Join-Path $TestDrive 'rotate'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($day in 1..4) {
            Set-Content -LiteralPath (Join-Path $dir "LunqDebloater_2026-10-0${day}_10-00-00.log") -Value 'log'
            Set-Content -LiteralPath (Join-Path $dir "LunqDebloater_2026-10-0${day}_10-00-00_dism.zip") -Value 'zip'
        }
        InModuleScope LunqDebloater -Parameters @{ Dir = $dir } {
            param($Dir)
            # Транскрипт не нужен: проверяется только уборка старых файлов.
            Mock Start-Transcript { }
            Mock Stop-Transcript { }
            Start-LunqLog -Dir $Dir -Keep 3 -KeepDism 2 | Out-Null
            Stop-LunqLog
        }
        @(Get-ChildItem -LiteralPath $dir -Filter '*_dism.zip' | ForEach-Object { $_.Name }) | Should -Be @('LunqDebloater_2026-10-04_10-00-00_dism.zip')
        Test-Path -LiteralPath (Join-Path $dir 'LunqDebloater_2026-10-01_10-00-00.log') | Should -BeFalse
    }
}

Describe 'Строки интерфейса' {
    BeforeAll {
        $script:Repo = Split-Path $PSScriptRoot -Parent
        $script:Tables = & (Get-Module LunqDebloater) { @{ ru = Import-LunqStrings -Language ru; en = Import-LunqStrings -Language en } }
        function Get-Placeholders([string]$Text) {
            @([regex]::Matches(($Text -replace '\{\{|\}\}', ''), '\{(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
        }
    }

    It 'в русской и английской таблицах одни и те же ключи' {
        $ru = @($script:Tables.ru.Keys | Sort-Object)
        $en = @($script:Tables.en.Keys | Sort-Object)
        @(Compare-Object $ru $en | ForEach-Object { "$($_.InputObject) $($_.SideIndicator)" }) | Should -BeNullOrEmpty
    }

    It 'у каждого ключа одинаковые подстановки {N} в обоих языках' {
        $mismatch = foreach ($key in $script:Tables.ru.Keys) {
            if ($script:Tables.en.ContainsKey($key) -and ((Get-Placeholders $script:Tables.ru[$key]) -join ',') -ne ((Get-Placeholders $script:Tables.en[$key]) -join ',')) { $key }
        }
        @($mismatch) | Should -BeNullOrEmpty
    }

    It 'каждый ключ из кода есть в таблицах' {
        $files = @(Get-Item -LiteralPath (Join-Path $script:Repo 'LunqDebloater.ps1')) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'Modules\LunqDebloater\Private') -Filter '*.ps1' -File)
        $missing = foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($match in [regex]::Matches($text, "Get-LunqText\s+'([^']+)'")) {
                $key = $match.Groups[1].Value
                if (-not $script:Tables.ru.ContainsKey($key)) { "$($file.Name): $key" }
            }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'в английской таблице нет русских букв' {
        @($script:Tables.en.Keys | Where-Object { $script:Tables.en[$_] -match '[А-Яа-яЁё]' }) | Should -BeNullOrEmpty
    }

    It 'текст профиля: строка или перевод, запасной язык английский' {
        & (Get-Module LunqDebloater) {
            try {
                Set-LunqLanguage -Language en
                Get-LunqLocalized 'Просто строка' | Should -Be 'Просто строка'
                Get-LunqLocalized ([pscustomobject]@{ ru = 'Приложения'; en = 'Apps' }) | Should -Be 'Apps'
                Set-LunqLanguage -Language ru
                Get-LunqLocalized ([pscustomobject]@{ ru = 'Приложения'; en = 'Apps' }) | Should -Be 'Приложения'
                Get-LunqLocalized ([pscustomobject]@{ en = 'Apps only' }) | Should -Be 'Apps only'
                Get-LunqLocalized $null | Should -Be ''
            }
            finally { Set-LunqLanguage -Language ru }
        }
    }

    It 'профиль по умолчанию переведён целиком' {
        & (Get-Module LunqDebloater) {
            param($Path)
            try {
                Set-LunqLanguage -Language en
                $loaded = Read-LunqProfile -Path $Path
                ($loaded.Description + ($loaded.Categories | ForEach-Object { $_.Name + $_.Description })) | Should -Not -Match '[А-Яа-яЁё]'
            }
            finally { Set-LunqLanguage -Language ru }
        } $script:ProfilePath
    }
}
