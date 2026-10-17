# События для программ, которые запускают скрипт (например, окно с полосой прогресса).
# С -EventsPath каждая строка вывода дублируется событием в отдельный файл: одна строка
# в UTF-8 это один объект JSON. Обычный вывод и лог при этом не меняются. Формат описан
# в README («События для своих программ»).
$script:EventWriter = $null
$script:EventWarnings = 0

function Start-LunqEvents {
    # Открывает файл событий. Другие программы могут читать его, пока он пишется.
    param([Parameter(Mandatory)][string]$Path)
    Stop-LunqEvents
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { throw (Get-LunqText 'Events.DirNotFound' $dir) }
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)))
    # Каждое событие сразу попадает в файл: окно показывает прогресс, пока идёт долгий шаг.
    $writer.AutoFlush = $true
    $writer.NewLine = "`n"
    $script:EventWriter = $writer
    $script:EventWarnings = 0
}

function Stop-LunqEvents {
    if ($script:EventWriter) {
        try { $script:EventWriter.Dispose() } catch { }
        $script:EventWriter = $null
    }
}

function Send-LunqEvent {
    # Пишет одно событие: type, time и поля из -Data. Без -EventsPath ничего не делает.
    param([Parameter(Mandatory)][string]$Type, [hashtable]$Data = @{})
    if (-not $script:EventWriter) { return }
    if ($Type -eq 'warning' -or ($Type -eq 'check' -and $Data['status'] -eq 'warn')) { $script:EventWarnings++ }
    $record = [ordered]@{ type = $Type; time = (Get-Date).ToString('o') }
    foreach ($key in @($Data.Keys | Sort-Object)) { $record[$key] = $Data[$key] }
    $line = ConvertTo-Json -InputObject $record -Compress -Depth 6
    # Сбой записи (например, диск заполнен) не должен останавливать сборку.
    try { $script:EventWriter.WriteLine($line) } catch { }
}

function Send-LunqFailure {
    # Ошибка до начала работы (нет прав, идёт другой запуск): последнее событие, как и в конце сборки, done.
    param([Parameter(Mandatory)][string]$Message)
    Send-LunqEvent 'error' @{ text = $Message; where = @() }
    Send-LunqEvent 'done' @{ ok = $false; warnings = $script:EventWarnings }
    Stop-LunqEvents
}

function Get-LunqEventWarnings {
    # Сколько предупреждений ушло в события: окно показывает это число в итоге.
    return $script:EventWarnings
}

function Send-LunqResultEvents {
    # Итог каждого шага: что сделано, что не удалось, что пропущено.
    param([object[]]$Results = @())
    foreach ($r in @($Results | Where-Object { $null -ne $_ })) {
        Send-LunqEvent 'result' @{
            kind       = $r.Kind
            title      = $r.Title
            done       = @($r.Done)
            failed     = @($r.Failed)
            skipped    = @($r.Skipped)
            notMatched = @($r.NotMatched)
            summary    = $r.Summary
        }
    }
}
