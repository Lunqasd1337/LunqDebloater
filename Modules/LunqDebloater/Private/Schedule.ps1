# Пересборка образа по расписанию: задание планировщика раз в месяц запускает скрипт с рецептом
# прошлой сборки и свежими обновлениями из каталога Microsoft.

function Get-LunqScheduleName {
    # Имя задания по имени рецепта: у каждого собираемого ISO своё задание в папке LunqDebloater.
    param([Parameter(Mandatory)][string]$RecipePath)
    # Имя файла вырезается сразу по обоим разделителям: путь бывает и с / .
    $name = ($RecipePath -split '[\\/]')[-1] -replace '\.lunq\.json$', ''
    # Имя задания не может содержать \ / : * ? " < > |.
    $name = $name -replace '[\\/:*?"<>|]', '_'
    return "LunqDebloater\$name"
}

function New-LunqScheduleXml {
    # Описание задания для schtasks /XML. 15-е число выбрано потому, что накопительные обновления
    # выходят во второй вторник месяца, а он бывает не позже 14-го. Запуск идёт от SYSTEM: сборке
    # нужны права администратора, а пользователь в это время может быть не в системе.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$RecipePath,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$Description,
        [datetime]$Now = (Get-Date)
    )
    $start = New-Object DateTime($Now.Year, $Now.Month, 15, 3, 0, 0)
    if ($start -le $Now) { $start = $start.AddMonths(1) }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Recipe "{1}" -DownloadUpdates -Force -Language {2}' -f $ScriptPath, $RecipePath, $Language
    # Полный путь: задание не должно зависеть от PATH системной учётной записи.
    $windows = $env:SystemRoot
    if (-not $windows) { $windows = 'C:\Windows' }
    $powershell = $windows.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
    $months = (@('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December') |
            ForEach-Object { "<$_ />" }) -join ''
    $e = { param($text) [Security.SecurityElement]::Escape([string]$text) }
    $lines = @(
        '<?xml version="1.0" encoding="UTF-16"?>',
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">',
        '  <RegistrationInfo>',
        "    <Description>$(& $e $Description)</Description>",
        '  </RegistrationInfo>',
        '  <Triggers>',
        '    <CalendarTrigger>',
        "      <StartBoundary>$($start.ToString('yyyy-MM-ddTHH:mm:ss'))</StartBoundary>",
        '      <Enabled>true</Enabled>',
        '      <ScheduleByMonth>',
        '        <DaysOfMonth><Day>15</Day></DaysOfMonth>',
        "        <Months>$months</Months>",
        '      </ScheduleByMonth>',
        '    </CalendarTrigger>',
        '  </Triggers>',
        '  <Principals>',
        '    <Principal id="Author">',
        '      <UserId>S-1-5-18</UserId>',
        '      <RunLevel>HighestAvailable</RunLevel>',
        '    </Principal>',
        '  </Principals>',
        '  <Settings>',
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
        # Ноутбук от батареи тоже собирает, а пропущенный запуск (компьютер был выключен) идёт при включении.
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
        '    <StartWhenAvailable>true</StartWhenAvailable>',
        '    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>',
        '    <ExecutionTimeLimit>PT8H</ExecutionTimeLimit>',
        '    <Enabled>true</Enabled>',
        '  </Settings>',
        '  <Actions Context="Author">',
        '    <Exec>',
        "      <Command>$(& $e $powershell)</Command>",
        "      <Arguments>$(& $e $arguments)</Arguments>",
        '    </Exec>',
        '  </Actions>',
        '</Task>',
        '')
    return [pscustomobject]@{ Xml = ($lines -join "`r`n"); Start = $start }
}

function Register-LunqSchedule {
    # Создаёт или заменяет задание пересборки. Возвращает дату первого запуска.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$RecipePath,
        [Parameter(Mandatory)][string]$TempDir
    )
    $name = Get-LunqScheduleName -RecipePath $RecipePath
    $task = New-LunqScheduleXml -ScriptPath $ScriptPath -RecipePath $RecipePath -Language (Get-LunqLanguage) `
        -Description (Get-LunqText 'Schedule.Description' $RecipePath)
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $xmlPath = Join-Path $TempDir 'LunqSchedule.xml'
    # schtasks читает описание задания только в UTF-16.
    [IO.File]::WriteAllText($xmlPath, $task.Xml, [Text.Encoding]::Unicode)
    try {
        $code = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/Create', '/TN', $name, '/XML', $xmlPath, '/F')
        if ($code -ne 0) { throw (Get-LunqText 'Schedule.CreateFailed' $code) }
    }
    finally { Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue }
    Write-Check Ok (Get-LunqText 'Schedule.Created' $name ($task.Start.ToString('yyyy-MM-dd HH:mm')))
    return $task.Start
}

function Unregister-LunqSchedule {
    # Удаляет задание пересборки. Задания нет: только сообщение, это не ошибка.
    param([Parameter(Mandatory)][string]$RecipePath)
    $name = Get-LunqScheduleName -RecipePath $RecipePath
    $code = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/Delete', '/TN', $name, '/F')
    if ($code -eq 0) { Write-Check Ok (Get-LunqText 'Schedule.Removed' $name) }
    else { Write-Info (Get-LunqText 'Schedule.NotFound' $name) }
}
