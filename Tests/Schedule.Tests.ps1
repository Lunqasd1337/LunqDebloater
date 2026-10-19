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
            Get-LunqScheduleName -RecipePath 'D:\ISO\Win11_Lunq.lunq.json' | Should -Be 'LunqDebloater\Win11_Lunq'
            Get-LunqScheduleName -RecipePath 'D:\ISO\a"b.lunq.json' | Should -Be 'LunqDebloater\a_b'
        }
    }

    It 'первый запуск 15-го в 03:00 этого месяца, если он ещё впереди, иначе следующего' {
        InModuleScope LunqDebloater {
            $args1 = @{ ScriptPath = 'C:\Lunq\LunqDebloater.ps1'; RecipePath = 'D:\Win11.lunq.json'; Language = 'ru'; Description = 'd' }
            (New-LunqScheduleXml @args1 -Now ([datetime]'2026-10-03 12:00')).Start | Should -Be ([datetime]'2026-10-15 03:00')
            (New-LunqScheduleXml @args1 -Now ([datetime]'2026-10-19 12:00')).Start | Should -Be ([datetime]'2026-11-15 03:00')
            (New-LunqScheduleXml @args1 -Now ([datetime]'2026-12-20 12:00')).Start | Should -Be ([datetime]'2027-01-15 03:00')
        }
    }

    It 'задание запускает скрипт от SYSTEM с рецептом и свежими обновлениями, пути экранированы' {
        InModuleScope LunqDebloater {
            $task = New-LunqScheduleXml -ScriptPath 'C:\Lunq & Co\LunqDebloater.ps1' -RecipePath 'D:\ISO\Win11.lunq.json' -Language en -Description 'rebuild <D:\ISO>' -Now ([datetime]'2026-10-19')
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
                Should -Be '-NoProfile -ExecutionPolicy Bypass -File "C:\Lunq & Co\LunqDebloater.ps1" -Recipe "D:\ISO\Win11.lunq.json" -DownloadUpdates -Force -Language en'
            $xml.SelectSingleNode('//t:RunOnlyIfNetworkAvailable', $ns).InnerText | Should -Be 'true'
        }
    }
}

Describe 'Создание и удаление задания' {
    BeforeEach {
        InModuleScope LunqDebloater {
            Mock Write-Check { }
            Mock Write-Info { }
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

    It 'schtasks /Create получает описание в UTF-16, временный файл удаляется' {
        $temp = Join-Path $TestDrive 'temp'
        InModuleScope LunqDebloater -Parameters @{ Temp = $temp } {
            param($Temp)
            $start = Register-LunqSchedule -ScriptPath 'C:\Lunq\LunqDebloater.ps1' -RecipePath 'D:\ISO\Win11_Lunq.lunq.json' -TempDir $Temp
            $start.Day | Should -Be 15
            $call = $script:SchtasksCalls[0]
            $call.Arguments[0..2] | Should -Be @('/Create', '/TN', 'LunqDebloater\Win11_Lunq')
            $call.Arguments[-1] | Should -Be '/F'
            $call.Bytes[0..1] | Should -Be @(0xFF, 0xFE)
            [Text.Encoding]::Unicode.GetString($call.Bytes) | Should -Match 'по рецепту D:\\ISO\\Win11_Lunq\.lunq\.json'
            Should -Invoke Write-Check -ParameterFilter { $Message -match 'Задание LunqDebloater\\Win11_Lunq создано' }
        }
        @(Get-ChildItem -LiteralPath $temp -File).Count | Should -Be 0
    }

    It 'schtasks вернул ошибку: сообщение с кодом' {
        InModuleScope LunqDebloater -Parameters @{ Temp = (Join-Path $TestDrive 'temp2') } {
            param($Temp)
            $script:SchtasksCode = 5
            { Register-LunqSchedule -ScriptPath 'C:\Lunq\LunqDebloater.ps1' -RecipePath 'D:\Win11.lunq.json' -TempDir $Temp } | Should -Throw '*schtasks, код 5*'
        }
    }

    It '-Schedule Off удаляет задание, а если его нет, только говорит об этом' {
        InModuleScope LunqDebloater {
            Unregister-LunqSchedule -RecipePath 'D:\Win11.lunq.json'
            $script:SchtasksCalls[0].Arguments | Should -Be @('/Delete', '/TN', 'LunqDebloater\Win11', '/F')
            Should -Invoke Write-Check -Times 1 -ParameterFilter { $Message -match 'удалено' }
            $script:SchtasksCode = 1
            Unregister-LunqSchedule -RecipePath 'D:\Win11.lunq.json'
            Should -Invoke Write-Info -Times 1 -ParameterFilter { $Message -match 'Задания LunqDebloater\\Win11 нет' }
        }
    }
}
