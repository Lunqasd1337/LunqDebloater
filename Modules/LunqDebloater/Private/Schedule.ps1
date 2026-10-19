# Пересборка образа по расписанию: задание планировщика раз в месяц запускает скрипт с рецептом
# прошлой сборки и свежими обновлениями из каталога Microsoft.
#
# Задание идёт от SYSTEM, поэтому запускает не папку программы, а её копию вместе с рецептом и
# настройками в Program Files. Папка программы по умолчанию лежит в профиле пользователя, а рецепт
# рядом с ISO: там их может поменять любая программа пользователя и так получить права SYSTEM.

function Get-LunqScheduleName {
    # Имя задания по имени рецепта: у каждого собираемого ISO своё задание в папке LunqDebloater.
    param([Parameter(Mandatory)][string]$RecipePath)
    # Имя файла вырезается сразу по обоим разделителям: путь бывает и с / .
    $name = ($RecipePath -split '[\\/]')[-1] -replace '\.lunq\.json$', ''
    # Имя задания не может содержать \ / : * ? " < > |.
    $name = $name -replace '[\\/:*?"<>|]', '_'
    return "LunqDebloater\$name"
}

function Get-LunqScheduleRoot {
    # Папка копий для заданий. В Program Files обычный пользователь не может ничего создать, поэтому
    # заранее подложить туда свою папку нельзя. Отдельная папка, а не Program Files\LunqDebloater:
    # туда же можно поставить и саму программу, и тогда её владелец мог бы менять копии.
    $programFiles = $env:ProgramFiles
    if (-not $programFiles) { $programFiles = 'C:\Program Files' }
    return (Join-Path $programFiles 'LunqDebloater-Schedule')
}

function Get-LunqScheduleDir {
    # Папка копии для задания этого рецепта.
    param([Parameter(Mandatory)][string]$RecipePath)
    $name = (Get-LunqScheduleName -RecipePath $RecipePath) -replace '^LunqDebloater\\', ''
    return (Join-Path (Get-LunqScheduleRoot) $name)
}

function Copy-LunqScheduleFiles {
    # Копия скрипта, модулей, настроек и рецепта, которую запускает задание. Свежие обновления копия
    # скачивает в свою папку Config\Updates, поэтому Updates не копируется, как и Drivers: задание
    # всегда скачивает обновления, а папка драйверов записана в рецепте. Возвращает пути копии.
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RecipePath,
        [Parameter(Mandatory)][string]$Destination
    )
    $root = Split-Path $Destination -Parent
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Set-LunqAdminOnlyAccess -Path $root
    # Старая копия заменяется целиком, чтобы в ней не остались файлы прошлой версии.
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in 'LunqDebloater.ps1', 'Modules', 'ThirdParty') {
        $source = Join-Path $SourceRoot $item
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force }
    }
    $config = Join-Path $Destination 'Config'
    New-Item -ItemType Directory -Path $config -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $ConfigPath -Force | Where-Object { @('Updates', 'Drivers') -notcontains $_.Name })) {
        Copy-Item -LiteralPath $item.FullName -Destination $config -Recurse -Force
    }
    $recipe = Join-Path $Destination (Split-Path $RecipePath -Leaf)
    Copy-Item -LiteralPath $RecipePath -Destination $recipe -Force
    return [pscustomobject]@{ Dir = $Destination; Script = (Join-Path $Destination 'LunqDebloater.ps1'); Recipe = $recipe; Config = $config }
}

function New-LunqScheduleXml {
    # Описание задания для schtasks /XML. 15-е число выбрано потому, что накопительные обновления
    # выходят во второй вторник месяца, а он бывает не позже 14-го. Запуск идёт от SYSTEM: сборке
    # нужны права администратора, а пользователь в это время может быть не в системе.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$RecipePath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$Description,
        [datetime]$Now = (Get-Date)
    )
    $start = New-Object DateTime($Now.Year, $Now.Month, 15, 3, 0, 0)
    if ($start -le $Now) { $start = $start.AddMonths(1) }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Recipe "{1}" -ConfigPath "{2}" -DownloadUpdates -Force -Language {3}' -f $ScriptPath, $RecipePath, $ConfigPath, $Language
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
    # Создаёт или заменяет задание пересборки вместе с его копией программы. SourceRoot: папка
    # LunqDebloater.ps1. Возвращает дату первого запуска.
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RecipePath
    )
    $name = Get-LunqScheduleName -RecipePath $RecipePath
    $copy = Copy-LunqScheduleFiles -SourceRoot $SourceRoot -ConfigPath $ConfigPath -RecipePath $RecipePath -Destination (Get-LunqScheduleDir -RecipePath $RecipePath)
    $task = New-LunqScheduleXml -ScriptPath $copy.Script -RecipePath $copy.Recipe -ConfigPath $copy.Config -Language (Get-LunqLanguage) `
        -Description (Get-LunqText 'Schedule.Description' $RecipePath)
    # Файл задания лежит в закрытой копии, а не во временной папке пользователя: иначе его можно было бы
    # подменить, пока schtasks его не прочитал.
    $xmlPath = Join-Path $copy.Dir 'LunqSchedule.xml'
    # schtasks читает описание задания только в UTF-16.
    [IO.File]::WriteAllText($xmlPath, $task.Xml, [Text.Encoding]::Unicode)
    try {
        $code = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/Create', '/TN', $name, '/XML', $xmlPath, '/F')
        if ($code -ne 0) { throw (Get-LunqText 'Schedule.CreateFailed' $code) }
    }
    finally { Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue }
    Write-Check Ok (Get-LunqText 'Schedule.Created' $name ($task.Start.ToString('yyyy-MM-dd HH:mm')))
    Write-Info (Get-LunqText 'Schedule.Copy' $copy.Dir)
    return $task.Start
}

function Unregister-LunqSchedule {
    # Удаляет задание пересборки и его копию программы. Задания нет: только сообщение, это не ошибка.
    param([Parameter(Mandatory)][string]$RecipePath)
    $name = Get-LunqScheduleName -RecipePath $RecipePath
    $code = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/Delete', '/TN', $name, '/F')
    if ($code -eq 0) { Write-Check Ok (Get-LunqText 'Schedule.Removed' $name) }
    else { Write-Info (Get-LunqText 'Schedule.NotFound' $name) }
    $dir = Get-LunqScheduleDir -RecipePath $RecipePath
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}
