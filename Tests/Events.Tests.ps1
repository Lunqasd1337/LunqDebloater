#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# События для своих программ (Private\Events.ps1): файл JSON по строке на событие.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru

    function Read-TestEvents {
        # Читает файл, пока скрипт держит его открытым, как это делала бы программа с окном.
        param([Parameter(Mandatory)][string]$Path)
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $text = (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd() }
        finally { $stream.Dispose() }
        return @($text -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

AfterAll {
    Stop-LunqEvents
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'События' {
    It 'вывод в консоль дублируется событиями, а файл читается, пока открыт' {
        $path = Join-Path $TestDrive 'events.jsonl'
        Start-LunqEvents -Path $path
        try {
            & (Get-Module LunqDebloater) {
                Initialize-LunqSteps -Total 2
                Write-Section 'Проверка системы'
                Write-Step 'Копирование ISO' 'Подсказка' -Id 'CopyIso'
                Write-Check Warn 'Мало места' 'Освободите диск'
                Write-Info ''
                Write-Info 'Готово: «образ»'
                Write-LunqWarning 'Не удалось удалить пакет'
            } 6>$null 3>$null
            $events = Read-TestEvents -Path $path
        }
        finally { Stop-LunqEvents }
        @($events | ForEach-Object { $_.type }) | Should -Be @('section', 'step', 'check', 'info', 'warning')
        $events[1].index | Should -Be 1
        $events[1].total | Should -Be 2
        $events[1].id | Should -Be 'CopyIso'
        $events[1].hint | Should -Be 'Подсказка'
        $events[2].status | Should -Be 'warn'
        # Русский текст в UTF-8 без искажений, пустые строки вывода событиями не становятся.
        $events[3].text | Should -Be 'Готово: «образ»'
        [datetime]$events[0].time | Should -BeOfType [datetime]
        Get-LunqEventWarnings | Should -Be 2
        # В начале файла нет BOM: каждая строка сразу разбирается как JSON.
        [IO.File]::ReadAllBytes($path)[0] | Should -Be ([byte][char]'{')
    }

    It 'итог шагов: списки остаются списками, даже из одного элемента' {
        $path = Join-Path $TestDrive 'results.jsonl'
        Start-LunqEvents -Path $path
        try {
            $r = & (Get-Module LunqDebloater) { New-LunqResult -Title 'Драйверы' -Kind 'Drivers' }
            $r.Done.Add('net.inf')
            Send-LunqResultEvents -Results @($r, $null)
            $events = Read-TestEvents -Path $path
        }
        finally { Stop-LunqEvents }
        $events.Count | Should -Be 1
        $events[0].kind | Should -Be 'Drivers'
        , $events[0].done | Should -BeOfType [object[]]
        $events[0].done | Should -Be @('net.inf')
        @($events[0].failed).Count | Should -Be 0
    }

    It 'без -EventsPath ничего не пишется, а папки для файла нет: понятная ошибка' {
        { Send-LunqEvent 'info' @{ text = 'x' } } | Should -Not -Throw
        { Start-LunqEvents -Path (Join-Path $TestDrive 'нет\events.jsonl') } | Should -Throw '*Нет папки для файла событий*'
    }
}
