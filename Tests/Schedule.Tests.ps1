#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Пересборка по расписанию (Private\Schedule.ps1): имя и описание задания, вызов schtasks.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Описание задания' {
    It 'имя задания берётся из имени рецепта, без недопустимых знаков' {
        InModuleScope LunqDebloater {
            $name = Get-LunqScheduleName -RecipePath 'D:\ISO\Win11_Lunq.lunq.json'
            $name | Should -Match '^LunqDebloater\\Win11_Lunq-[0-9a-f]{8}$'
            Get-LunqScheduleName -RecipePath 'D:\ISO\a"b.lunq.json' | Should -Match '^LunqDebloater\\a_b-[0-9a-f]{8}$'
            # Регистр пути не важен, а тот же рецепт в другой папке получает своё задание.
            Get-LunqScheduleName -RecipePath 'd:\iso\WIN11_Lunq.lunq.json' | Should -Be $name
            Get-LunqScheduleName -RecipePath 'E:\Other\Win11_Lunq.lunq.json' | Should -Not -Be $name
            Get-LunqScheduleName -RecipePath 'D:\ISO\Win11_Lunq.lunq.json' -Legacy | Should -Be 'LunqDebloater\Win11_Lunq'
        }
    }

    It 'первый запуск 15-го в 03:00 этого месяца, если он ещё впереди, иначе следующего' {
        InModuleScope LunqDebloater {
            $args1 = @{ ScriptPath = 'C:\Lunq\LunqDebloater.ps1'; RecipePath = 'D:\Win11.lunq.json'; ConfigPath = 'C:\Lunq\Config'; Language = 'ru'; Description = 'd' }
            (New-LunqScheduleXml @args1 -Now ([datetime]'2026-10-03 12:00')).Start | Should -Be ([datetime]'2026-10-15 03:00')
            (New-LunqScheduleXml @args1 -Now ([datetime]'2026-10-19 12:00')).Start | Should -Be ([datetime]'2026-11-15 03:00')
            (New-LunqScheduleXml @args1 -Now ([datetime]'2026-12-20 12:00')).Start | Should -Be ([datetime]'2027-01-15 03:00')
        }
    }

    It 'задание запускает скрипт от SYSTEM с рецептом и свежими обновлениями, пути экранированы' {
        InModuleScope LunqDebloater {
            $task = New-LunqScheduleXml -ScriptPath 'C:\Lunq & Co\LunqDebloater.ps1' -RecipePath 'D:\ISO\Win11.lunq.json' -ConfigPath 'C:\Lunq & Co\Config' -Language en -Description 'rebuild <D:\ISO>' -Now ([datetime]'2026-10-19')
            $xml = [xml]$task.Xml
            $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
            $xml.SelectSingleNode('//t:Principal/t:UserId', $ns).InnerText | Should -Be 'S-1-5-18'
            $xml.SelectSingleNode('//t:Description', $ns).InnerText | Should -Be 'rebuild <D:\ISO>'
            $xml.SelectSingleNode('//t:StartBoundary', $ns).InnerText | Should -Be '2026-11-15T03:00:00'
            $xml.SelectSingleNode('//t:DaysOfMonth/t:Day', $ns).InnerText | Should -Be '15'
            @($xml.SelectSingleNode('//t:Months', $ns).ChildNodes).Count | Should -Be 12
            $xml.SelectSingleNode('//t:Exec/t:Command', $ns).InnerText | Should -Match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$'
            $xml.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText |
                Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\Lunq & Co\LunqDebloater.ps1" -Recipe "D:\ISO\Win11.lunq.json" -ConfigPath "C:\Lunq & Co\Config" -DownloadUpdates -Force -Language en'
            $xml.SelectSingleNode('//t:RunOnlyIfNetworkAvailable', $ns).InnerText | Should -Be 'true'
        }
    }
}

Describe 'Создание и удаление задания' {
    BeforeEach {
        InModuleScope LunqDebloater {
            Mock Write-Check { }
            Mock Write-Info { }
            Mock Get-LunqScheduleRoot { Join-Path $TestDrive 'ProgramFiles\LunqDebloater-Schedule' }
            $script:SchtasksCalls = New-Object System.Collections.Generic.List[object]
            $script:SchtasksCode = 0
            Mock Invoke-Native {
                # Файл задания читается до того, как Register-LunqSchedule его удалит.
                $xmlIndex = [array]::IndexOf([string[]]$Arguments, '/XML')
                $bytes = $null
                if ($xmlIndex -ge 0) { $bytes = [IO.File]::ReadAllBytes($Arguments[$xmlIndex + 1]) }
                $script:SchtasksCalls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($Arguments); Bytes = $bytes })
                return $script:SchtasksCode
            } -ParameterFilter { $FilePath -eq 'schtasks.exe' }
        }
    }

    It 'задание запускает копию программы, настроек и рецепта, а не их исходную папку' {
        $app = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'app') -Force
        Set-Content -LiteralPath (Join-Path $app 'LunqDebloater.ps1') -Value '# main'
        New-Item -ItemType Directory -Path (Join-Path $app 'Modules\LunqDebloater') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'Modules\LunqDebloater\M.psm1') -Value '# module'
        New-Item -ItemType Directory -Path (Join-Path $app 'ThirdParty\EdgeRemover') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'ThirdParty\EdgeRemover\RemoveEdge.ps1') -Value '# edge'
        foreach ($dir in 'Config\Scripts', 'Config\Updates\Catalog', 'Config\Drivers') { New-Item -ItemType Directory -Path (Join-Path $app $dir) -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $app 'Config\Profile.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $app 'Config\Scripts\a.ps1') -Value '# a'
        Set-Content -LiteralPath (Join-Path $app 'Config\Updates\big.msu') -Value 'msu'
        Set-Content -LiteralPath (Join-Path $app 'Config\Drivers\net.inf') -Value 'inf'
        $recipe = Join-Path $TestDrive 'iso\Win11_Lunq.lunq.json'
        New-Item -ItemType Directory -Path (Split-Path $recipe -Parent) -Force | Out-Null
        Set-Content -LiteralPath $recipe -Value '{}'
        InModuleScope LunqDebloater -Parameters @{ App = $app.FullName; Recipe = $recipe } {
            param($App, $Recipe)
            $start = Register-LunqSchedule -SourceRoot $App -ConfigPath (Join-Path $App 'Config') -RecipePath $Recipe
            $start.Day | Should -Be 15
            $call = $script:SchtasksCalls[0]
            $name = Get-LunqScheduleName -RecipePath $Recipe
            $call.Arguments[0..2] | Should -Be @('/Create', '/TN', $name)
            $call.Arguments[-1] | Should -Be '/F'
            # schtasks читает описание задания только в UTF-16.
            $call.Bytes[0..1] | Should -Be @(0xFF, 0xFE)
            $xml = [Text.Encoding]::Unicode.GetString($call.Bytes)
            $copy = Join-Path $TestDrive ('ProgramFiles\LunqDebloater-Schedule\' + ($name -replace '^LunqDebloater\\', ''))
            $xml | Should -Match ('-File &quot;' + [regex]::Escape((Join-Path $copy 'LunqDebloater.ps1')) + '&quot;')
            $xml | Should -Match ('-Recipe &quot;' + [regex]::Escape((Join-Path $copy 'Win11_Lunq.lunq.json')) + '&quot;')
            $xml | Should -Match ('-ConfigPath &quot;' + [regex]::Escape((Join-Path $copy 'Config')) + '&quot;')
            $xml | Should -Match ('по рецепту ' + [regex]::Escape($Recipe))
            # Файл задания лежал в копии и удалён после schtasks.
            [string]$call.Arguments[4] | Should -BeLike (Join-Path $copy '*')
            Test-Path -LiteralPath $call.Arguments[4] | Should -BeFalse
            foreach ($file in 'LunqDebloater.ps1', 'Modules\LunqDebloater\M.psm1', 'ThirdParty\EdgeRemover\RemoveEdge.ps1', 'Config\Profile.json', 'Config\Scripts\a.ps1', 'Win11_Lunq.lunq.json') {
                Test-Path -LiteralPath (Join-Path $copy $file) | Should -BeTrue
            }
            # Обновления копия скачивает сама, а папка драйверов записана в рецепте.
            Test-Path -LiteralPath (Join-Path $copy 'Config\Updates') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $copy 'Config\Drivers') | Should -BeFalse
            Should -Invoke Write-Check -ParameterFilter { $Message -match 'Задание LunqDebloater\\Win11_Lunq-[0-9a-f]{8} создано' }
            Should -Invoke Write-Info -ParameterFilter { $Message -match 'Задание запускает копию LunqDebloater' }
            # Задание старого формата с тем же именем удаляется: оно запускало папку программы.
            $script:SchtasksCalls[1].Arguments | Should -Be @('/Delete', '/TN', 'LunqDebloater\Win11_Lunq', '/F')
            Should -Invoke Write-Info -ParameterFilter { $Message -match 'Удалено задание LunqDebloater\\Win11_Lunq старого формата' }

            # Повторное создание заменяет копию целиком: файлы прошлой версии не остаются.
            Set-Content -LiteralPath (Join-Path $copy 'Modules\LunqDebloater\Old.ps1') -Value '# old'
            $null = Register-LunqSchedule -SourceRoot $App -ConfigPath (Join-Path $App 'Config') -RecipePath $Recipe
            Test-Path -LiteralPath (Join-Path $copy 'Modules\LunqDebloater\Old.ps1') | Should -BeFalse

            # -Schedule Off удаляет и копию.
            Unregister-LunqSchedule -RecipePath $Recipe
            Test-Path -LiteralPath $copy | Should -BeFalse
        }
    }

    It 'schtasks вернул ошибку: сообщение с кодом' {
        $app = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'app2\Config') -Force
        $recipe = Join-Path $TestDrive 'Win11.lunq.json'
        Set-Content -LiteralPath $recipe -Value '{}'
        InModuleScope LunqDebloater -Parameters @{ Config = $app.FullName; Recipe = $recipe } {
            param($Config, $Recipe)
            $script:SchtasksCode = 5
            { Register-LunqSchedule -SourceRoot (Split-Path $Config -Parent) -ConfigPath $Config -RecipePath $Recipe } | Should -Throw '*schtasks, код 5*'
        }
    }

    It '-Schedule Off удаляет задание, а если его нет, только говорит об этом' {
        InModuleScope LunqDebloater {
            Unregister-LunqSchedule -RecipePath 'D:\Win11.lunq.json'
            $script:SchtasksCalls[0].Arguments | Should -Be @('/Delete', '/TN', (Get-LunqScheduleName -RecipePath 'D:\Win11.lunq.json'), '/F')
            $script:SchtasksCalls[1].Arguments | Should -Be @('/Delete', '/TN', 'LunqDebloater\Win11', '/F')
            Should -Invoke Write-Check -Times 1 -ParameterFilter { $Message -match 'удалено' }
            $script:SchtasksCode = 1
            Unregister-LunqSchedule -RecipePath 'D:\Win11.lunq.json'
            Should -Invoke Write-Info -Times 1 -ParameterFilter { $Message -match 'Задания LunqDebloater\\Win11-[0-9a-f]{8} нет' }
        }
    }
}
