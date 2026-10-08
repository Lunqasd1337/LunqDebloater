<#
.SYNOPSIS
    Преднастройка ISO-образа Windows 11: удаление Appx, компонентов Windows и твики реестра.

.DESCRIPTION
    Скрипт копирует содержимое ISO во временную папку, оставляет в install.wim одну
    выбранную редакцию, монтирует её через DISM и применяет профиль (JSON):
      - удаляет предустановленные Appx-приложения;
      - удаляет компоненты Windows (Capabilities, Optional Features, при желании CBS-пакеты);
      - вносит изменения в офлайн-реестр (SOFTWARE, SYSTEM, профиль Default).
    Затем образ пересжимается, и oscdimg собирает загрузочный ISO (BIOS + UEFI).

    Все настройки лежат в папке Config рядом со скриптом: профиль (Profile.json), список
    программ (Apps.txt), свои скрипты (Scripts), драйверы (Drivers) и обновления (Updates).
    Всё, что там найдено, попадает в образ.

    Если запустить скрипт без -IsoPath, он работает в пошаговом режиме: предложит
    выбрать ISO и редакцию, покажет сводку того, что найдено в Config, и даст выключить
    лишнее, проверит систему, покажет план и спросит подтверждение. Исходный ISO при этом
    не изменяется.

.PARAMETER IsoPath
    Путь к исходному ISO Windows 11. Без него скрипт запускается в пошаговом режиме.

.PARAMETER OutputIso
    Путь к итоговому ISO. По умолчанию рядом с исходным с суффиксом _Lunq.

.PARAMETER ConfigPath
    Папка с настройками. По умолчанию Config рядом со скриптом. Удобно, если настроек
    несколько: например, -ConfigPath .\Config-Office.

.PARAMETER ProfilePath
    JSON-профиль. По умолчанию Config\Profile.json.

.PARAMETER SkipCategory
    Id категорий профиля, которые нужно пропустить, через запятую: -SkipCategory drivers,store.
    Список Id показывается в плане сборки и в пошаговом режиме.

.PARAMETER Index
    Индекс редакции в install.wim / install.esd.

.PARAMETER Edition
    Имя редакции, например "Windows 11 Pro". Если не указаны ни Index, ни Edition,
    скрипт покажет список с пояснениями и спросит.

.PARAMETER WorkDir
    Рабочая папка (нужно около 25 ГБ свободного места на NTFS-диске). Скрипт полностью
    очищает её, поэтому принимает только новую или пустую папку либо папку, которую
    сам создал раньше. Корень диска и папка с исходным ISO не подойдут.

.PARAMETER OscdimgPath
    Путь к oscdimg.exe, если он не в стандартной папке Windows ADK.

.PARAMETER UpdatesPath
    Папка с обновлениями (.msu, .cab) вместо Config\Updates.

.PARAMETER DriversPath
    Папка с драйверами (распакованные .inf, можно в подпапках) вместо Config\Drivers.

.PARAMETER DriversToSetup
    Добавить драйверы контроллеров дисков ещё и в установщик (boot.wim) и среду восстановления
    (WinRE). Нужно, если установщик не видит диск, например на контроллерах Intel RST/VMD или RAID.
    Остальные драйверы туда не добавляются.

.PARAMETER UpdatesToSetup
    Встроить обновления Windows ещё и в установщик (boot.wim) и среду восстановления (WinRE).
    Сборка займёт на 10-20 минут дольше.

.PARAMETER SkipUpdates
    Не встраивать обновления, даже если они есть в Config\Updates.

.PARAMETER SkipDrivers
    Не встраивать драйверы, даже если они есть в Config\Drivers.

.PARAMETER SkipApps
    Не ставить программы из Config\Apps.txt при первом входе.

.PARAMETER SkipScripts
    Не выполнять скрипты из Config\Scripts при первом входе.

.PARAMETER Unattend
    Положить в ISO файл ответов (autounattend.xml): установка не спрашивает про лицензию и
    конфиденциальность (всё выключено), язык, формат, раскладки и часовой пояс берутся с этого
    компьютера. Диск для установки по-прежнему выбирается вручную. В пошаговом режиме включено
    по умолчанию.

.PARAMETER BypassRequirements
    Добавить в файл ответов обход требований Windows 11: TPM 2.0, Secure Boot и памяти. Включает -Unattend.

.PARAMETER LocalAccount
    Добавить в файл ответов вход без учётной записи Майкрософт: Windows сразу предложит создать
    локальную учётную запись. Включает -Unattend.

.PARAMETER Label
    Метка тома итогового ISO, её видно в Проводнике и в меню загрузки. По умолчанию LUNQ_WIN11.

.PARAMETER SkipAppx
    Не удалять приложения Appx из профиля.

.PARAMETER SkipComponents
    Не удалять компоненты (Capabilities) и не отключать функции Windows (Optional Features) из профиля.

.PARAMETER SkipRegistry
    Не вносить записи реестра из профиля. Отметка о сборке (HKLM\SOFTWARE\LunqDebloater) пишется всё равно.

.PARAMETER KeepWorkDir
    Не удалять рабочую папку после сборки, например чтобы посмотреть, что попало в образ.

.PARAMETER Force
    Перезаписать итоговый ISO, если он уже есть, не спрашивая.

.PARAMETER ListContents
    Ничего не собирать, а сохранить в текстовый файл рядом с ISO список приложений Appx,
    компонентов и функций выбранной редакции. Помогает составить свой профиль.

.PARAMETER SkipVersionCheck
    Не останавливаться, если сборка или архитектура ISO не совпадает с Requirements профиля.
    Нужен только тем, кто сознательно собирает образ на другой версии Windows.

.PARAMETER CleanupComponents
    Выполнить очистку хранилища компонентов (StartComponentCleanup /ResetBase).
    Образ станет меньше, но установленные в него обновления нельзя будет удалить.

.EXAMPLE
    .\LunqDebloater.ps1
    Пошаговый режим: скрипт сам спросит всё, что нужно.

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11_26H2.iso -Edition "Windows 11 Pro"

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Edition "Windows 11 Pro" -CleanupComponents
    Встраивает обновления из Config\Updates и затем очищает хранилище компонентов.

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Index 6 -SkipDrivers -SkipApps -SkipRegistry

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Edition "Windows 11 Pro" -ListContents
    Сохраняет список приложений и компонентов редакции в D:\Win11_<номер>_contents.txt.
#>
# #Requires стоит после справки: перед ней он мешает Get-Help её найти.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$OutputIso,
    [string]$ConfigPath,
    [string]$ProfilePath,
    [string[]]$SkipCategory,
    [int]$Index = 0,
    [string]$Edition,
    [string]$WorkDir = (Join-Path $env:SystemDrive 'LunqWork'),
    [string]$OscdimgPath,
    [string]$UpdatesPath,
    [string]$DriversPath,
    [switch]$DriversToSetup,
    [switch]$UpdatesToSetup,
    [switch]$SkipUpdates,
    [switch]$SkipDrivers,
    [switch]$SkipApps,
    [switch]$SkipScripts,
    [switch]$Unattend,
    [switch]$BypassRequirements,
    [switch]$LocalAccount,
    [switch]$ListContents,
    [string]$Label = 'LUNQ_WIN11',
    [switch]$SkipAppx,
    [switch]$SkipComponents,
    [switch]$SkipRegistry,
    [switch]$CleanupComponents,
    [switch]$SkipVersionCheck,
    [switch]$KeepWorkDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$interactive = -not $IsoPath

if ($env:OS -ne 'Windows_NT') { throw 'Скрипт работает только в Windows.' }

Import-Module (Join-Path $PSScriptRoot 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
# Параметры с путями: при перезапуске они передаются полными, ведь новое окно может открыться в другой папке.
$pathParams = 'IsoPath', 'OutputIso', 'ConfigPath', 'ProfilePath', 'WorkDir', 'OscdimgPath', 'UpdatesPath', 'DriversPath'

# В PowerShell 7 часть командлетов модуля DISM (например, Get-AppxProvisionedPackage)
# падает с ошибкой «Класс не зарегистрирован». Поэтому скрипт всегда работает
# в Windows PowerShell 5.1 и при запуске из PowerShell 7 перезапускает себя в нём.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPowerShell)) {
        throw 'Не найден Windows PowerShell 5.1, а в PowerShell 7 модуль DISM работает с ошибками.'
    }
    Write-Host 'Модуль DISM надёжно работает только в Windows PowerShell 5.1, перезапускаю скрипт в нём...' -ForegroundColor Yellow
    $forward = ConvertTo-LunqArgumentList -BoundParameters $PSBoundParameters -PathParameters $pathParams
    & $winPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forward
    exit $LASTEXITCODE
}
Import-Module Dism

if (-not (Test-Administrator)) {
    if (-not $interactive) { throw 'Запустите PowerShell от имени администратора: DISM работает только с правами администратора.' }
    Write-Host ''
    Write-Host 'Для работы с образом через DISM нужны права администратора.' -ForegroundColor Yellow
    $elevated = $false
    if (Read-YesNo 'Перезапустить скрипт от имени администратора?') {
        $shell = (Get-Process -Id $PID).Path
        # Новое окно открывается в System32, поэтому пути передаются полными. Start-Process
        # склеивает аргументы через пробел, поэтому каждый берётся в кавычки.
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") +
            (ConvertTo-LunqArgumentList -BoundParameters $PSBoundParameters -PathParameters $pathParams -Quote)
        try {
            Start-Process -FilePath $shell -Verb RunAs -ArgumentList ($relaunch -join ' ')
            $elevated = $true
        }
        catch { Write-Warning 'Права администратора не выданы (в окне UAC нажата «Нет»?).' }
    }
    if (-not $elevated) {
        Write-Info 'Без прав администратора собрать образ нельзя. Запустите скрипт снова и разрешите запуск.'
        Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null
    }
    return
}

# Относительные пути считаются от текущей папки PowerShell. [IO.Path]::GetFullPath
# для этого не годится: он берёт рабочую папку процесса, а она не меняется после cd.
$defaultWorkDir = Join-Path $env:SystemDrive 'LunqWork'
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir).TrimEnd('\')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'Config' }
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath).TrimEnd('\')

$mounted = $false
$bootMountDir = Join-Path $WorkDir 'bootmount'
$reMountDir = Join-Path $WorkDir 'remount'
$allMountDirs = @((Join-Path $WorkDir 'mount'), $bootMountDir, $reMountDir)
$listMode = [bool]$ListContents
$lunqLog = $null
$isoDir = Join-Path $WorkDir 'iso'
$mountDir = Join-Path $WorkDir 'mount'
$wimPath = Join-Path $isoDir 'sources\install.wim'

# Заголовок окна не меняется в некоторых консолях (например, при перенаправленном выводе), это не ошибка.
try { $Host.UI.RawUI.WindowTitle = "LunqDebloater $(Get-LunqVersion)" } catch { }

try {
    # Лог ведётся с самого начала: так в него попадают и ошибки при выборе ISO и проверке системы.
    $lunqLog = Start-LunqLog -Dir (Join-Path $PSScriptRoot 'Logs')
    Write-LunqRunInfo -BoundParameters $PSBoundParameters -DismLog $lunqLog.DismPath

    # ---------- Подготовка: всё, что можно проверить до долгой работы ----------
    if ($interactive) {
        Write-Host ''
        Write-Host "LunqDebloater $(Get-LunqVersion): преднастройка ISO-образа Windows 11" -ForegroundColor Cyan
        Write-Info 'Скрипт удалит лишние приложения и компоненты из установочного образа'
        Write-Info 'и внесёт настройки реестра. Исходный ISO не изменяется: результат'
        Write-Info 'сохраняется в новый файл. Сборка обычно занимает 15-40 минут.'

        Write-Section 'Что сделать'
        Write-Host '    [1] ' -ForegroundColor Cyan -NoNewline; Write-Host 'Собрать преднастроенный ISO'
        Write-Host '    [2] ' -ForegroundColor Cyan -NoNewline; Write-Host 'Посмотреть, что есть в образе: список приложений и компонентов для своего профиля'
        $listMode = ((Read-Host '    Введите номер (Enter: 1)').Trim() -eq '2')

        Write-Section 'Выбор ISO'
        Write-Info 'Выберите оригинальный ISO Windows 11 в открывшемся окне.'
        $IsoPath = Select-IsoFile
        Write-Info "ISO: $IsoPath"
    }
    else {
        $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
    }

    if (-not $OutputIso) {
        $OutputIso = Join-Path (Split-Path $IsoPath -Parent) ('{0}_Lunq.iso' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath))
    }
    $OutputIso = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputIso)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Container)) { throw "Папка с настройками не найдена: $ConfigPath" }
    if (-not $ProfilePath) {
        if ($interactive) {
            Write-Section 'Выбор профиля'
            $ProfilePath = Select-LunqProfile -ProfileDir $ConfigPath
        }
        else {
            $ProfilePath = Join-Path $ConfigPath 'Profile.json'
        }
    }
    $lunqProfile = Read-LunqProfile -Path $ProfilePath
    # При запуске через -File список приходит одной строкой, поэтому делим по запятым сами.
    $SkipCategory = @($SkipCategory | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($SkipCategory.Count -gt 0) { Disable-LunqCategories -LunqProfile $lunqProfile -Ids $SkipCategory }
    if ($interactive -and -not $listMode) {
        Write-Section 'Выбор категорий'
        Select-LunqCategories -LunqProfile $lunqProfile
    }
    if (-not $listMode -and -not ($lunqProfile.Categories | Where-Object { $_.Enabled })) {
        Write-Warning 'Все категории профиля выключены: образ будет собран без удалений и твиков.'
    }
    $config = Get-LunqEffectiveConfig -LunqProfile $lunqProfile

    # ---------- Что лежит в Config ----------
    # Обновления, драйверы, программы и скрипты берутся из Config. -UpdatesPath и -DriversPath
    # заменяют свои подпапки и должны указывать на непустую папку.
    $updatesDir = Join-Path $ConfigPath 'Updates'
    $driversDir = Join-Path $ConfigPath 'Drivers'
    $foundUpdates = @()
    $foundDrivers = @()
    $foundLogon = Get-LunqFirstLogon -AppsPath (Join-Path $ConfigPath 'Apps.txt') -ScriptsPath (Join-Path $ConfigPath 'Scripts')
    if (-not $listMode) {
        if ($UpdatesPath) {
            if (-not (Test-Path -LiteralPath $UpdatesPath -PathType Container)) { throw "Папка с обновлениями не найдена: $UpdatesPath" }
            $updatesDir = (Resolve-Path -LiteralPath $UpdatesPath).Path
        }
        $foundUpdates = Get-LunqUpdateFiles -Path $updatesDir
        if ($UpdatesPath -and $foundUpdates.Count -eq 0) { throw "В папке $UpdatesPath нет файлов .msu или .cab." }

        if ($DriversPath) {
            if (-not (Test-Path -LiteralPath $DriversPath -PathType Container)) { throw "Папка с драйверами не найдена: $DriversPath" }
            $driversDir = (Resolve-Path -LiteralPath $DriversPath).Path
        }
        $foundDrivers = Get-LunqDriverFiles -Path $driversDir
        if ($DriversPath -and $foundDrivers.Count -eq 0) {
            throw "В папке $DriversPath нет файлов .inf. Драйверы в виде .exe нужно сначала распаковать (см. README)."
        }
        if ($foundDrivers.Count -gt 0) { $DriversPath = (Resolve-Path -LiteralPath $driversDir).Path }
    }

    $useUpdates = $foundUpdates.Count -gt 0 -and -not $SkipUpdates
    $useDrivers = $foundDrivers.Count -gt 0 -and -not $SkipDrivers
    $useApps = $foundLogon.Apps.Count -gt 0 -and -not $SkipApps
    $useScripts = $foundLogon.Scripts.Count -gt 0 -and -not $SkipScripts
    # Файл ответов: в пошаговом режиме включён по умолчанию, с параметрами только по ключам.
    $useUnattend = $interactive -or $Unattend -or $BypassRequirements -or $LocalAccount
    $useOobe = $useUnattend
    $useRegion = $useUnattend
    $useBypass = [bool]$BypassRequirements
    $useLocalAccount = [bool]$LocalAccount
    $hostRegion = $null
    if (-not $listMode) { $hostRegion = Get-LunqHostRegion }

    if ($interactive -and -not $listMode) {
        Write-Section 'Что войдёт в образ'
        Write-Info "Вот что найдено в папке настроек $ConfigPath. [x] попадёт в образ, [ ] нет."
        Write-Info 'Чтобы добавить своё, положите файлы в эту папку и запустите скрипт снова (подробнее в Config\README.txt).'
        $hasUpdates = $foundUpdates.Count -gt 0
        $hasDrivers = $foundDrivers.Count -gt 0
        $hasApps = $foundLogon.Apps.Count -gt 0
        $hasScripts = $foundLogon.Scripts.Count -gt 0

        if ($hasUpdates) {
            $sum = [long]0
            foreach ($u in $foundUpdates) { $sum += $u.Length }
            $updatesName = "Обновления: $($foundUpdates.Count) шт., $(Format-Size $sum)"
            $updatesDetails = @($foundUpdates | ForEach-Object { $_.Name }) + 'Windows будет обновлённой сразу после установки, но сборка займёт заметно дольше.'
        }
        else {
            $updatesName = 'Обновления: не найдены'
            $updatesDetails = 'Скачайте .msu с catalog.update.microsoft.com и положите в Config\Updates.'
        }
        if ($hasDrivers) {
            $driversName = "Драйверы: $($foundDrivers.Count) шт. (.inf), $(Format-Size (Get-FolderSize $driversDir))"
            $driversDetails = 'Windows сама поставит их во время установки.'
        }
        else {
            $driversName = 'Драйверы: не найдены'
            $driversDetails = 'Положите распакованные драйверы в Config\Drivers, например: Export-WindowsDriver -Online -Destination .\Config\Drivers'
        }
        if ($hasApps) {
            $appsName = "Программы после установки: $($foundLogon.Apps.Count) шт. (winget)"
            $appsDetails = $foundLogon.Apps -join ', '
        }
        else {
            $appsName = 'Программы после установки: список пуст'
            $appsDetails = 'Впишите Id программ из winget в Config\Apps.txt.'
        }
        if ($hasScripts) {
            $scriptsName = "Скрипты после установки: $($foundLogon.Scripts.Count) шт."
            $scriptsDetails = ($foundLogon.Scripts | ForEach-Object { $_.Name }) -join ', '
        }
        else {
            $scriptsName = 'Скрипты после установки: не найдены'
            $scriptsDetails = 'Положите свои *.ps1 в Config\Scripts.'
        }
        $regionDetails = "Формат: {0}, раскладки: {1}, часовой пояс: {2}." -f $hostRegion.Locale, ($hostRegion.Keyboards -join ', '), $hostRegion.TimeZone
        $peDriversCount = (Select-LunqPEDrivers $foundDrivers).Count

        $options = @(
            (New-LunqOption -Key 'updates' -Enabled $useUpdates -Available $hasUpdates -Name $updatesName -Details $updatesDetails),
            (New-LunqOption -Key 'cleanup' -Parent 'updates' -Enabled ([bool]$CleanupComponents) -Available $hasUpdates `
                -Name 'Очистить хранилище компонентов после обновлений' `
                -Details 'Образ станет меньше, но удалить встроенные обновления потом будет нельзя.'),
            (New-LunqOption -Key 'updatesToSetup' -Parent 'updates' -Enabled ([bool]$UpdatesToSetup) -Available $hasUpdates `
                -Name 'Обновить и установщик со средой восстановления (WinRE)' `
                -Details 'В них будут те же исправления, что и в системе. Сборка займёт на 10-20 минут дольше.'),
            (New-LunqOption -Key 'drivers' -Enabled $useDrivers -Available $hasDrivers -Name $driversName -Details $driversDetails),
            (New-LunqOption -Key 'driversToSetup' -Parent 'drivers' -Enabled ([bool]$DriversToSetup) -Available $hasDrivers `
                -Name "Добавить драйверы дисков и в установщик со средой восстановления (WinRE): $peDriversCount шт." `
                -Details 'Нужно, если установщик не видит диск (контроллеры Intel RST/VMD, RAID). Остальные драйверы туда не добавляются.'),
            (New-LunqOption -Key 'apps' -Enabled $useApps -Available $hasApps -Name $appsName -Details $appsDetails),
            (New-LunqOption -Key 'scripts' -Enabled $useScripts -Available $hasScripts -Name $scriptsName -Details $scriptsDetails),
            (New-LunqOption -Key 'unattend' -Enabled $useUnattend -Name 'Файл ответов: меньше вопросов при установке Windows' `
                -Details 'В ISO добавится autounattend.xml. Диск для установки по-прежнему выбирается вручную.'),
            (New-LunqOption -Key 'oobe' -Parent 'unattend' -Enabled $useOobe -Name 'Не спрашивать про лицензию и конфиденциальность' `
                -Details 'Все параметры конфиденциальности (диагностика, реклама, местоположение) будут выключены.'),
            (New-LunqOption -Key 'region' -Parent 'unattend' -Enabled $useRegion -Name 'Язык, регион и часовой пояс как на этом компьютере' `
                -Details $regionDetails),
            (New-LunqOption -Key 'bypass' -Parent 'unattend' -Enabled $useBypass -Name 'Обойти требования Windows 11: TPM 2.0, Secure Boot и память' `
                -Details 'Для компьютеров, на которые Windows 11 иначе не ставится. На остальных ничего не меняет.'),
            (New-LunqOption -Key 'localAccount' -Parent 'unattend' -Enabled $useLocalAccount -Name 'Локальная учётная запись вместо учётной записи Майкрософт' `
                -Details 'Windows не будет предлагать войти в учётную запись Майкрософт и сразу спросит имя и пароль.')
        )
        Select-LunqBuildOptions -Options $options
        $useUpdates = Test-LunqOption -Options $options -Key 'updates'
        $useDrivers = Test-LunqOption -Options $options -Key 'drivers'
        $useApps = Test-LunqOption -Options $options -Key 'apps'
        $useScripts = Test-LunqOption -Options $options -Key 'scripts'
        $useUnattend = Test-LunqOption -Options $options -Key 'unattend'
        $useOobe = Test-LunqOption -Options $options -Key 'oobe'
        $useRegion = Test-LunqOption -Options $options -Key 'region'
        $useBypass = Test-LunqOption -Options $options -Key 'bypass'
        $useLocalAccount = Test-LunqOption -Options $options -Key 'localAccount'
        $UpdatesToSetup = [switch](Test-LunqOption -Options $options -Key 'updatesToSetup')
        $DriversToSetup = [switch](Test-LunqOption -Options $options -Key 'driversToSetup')
        if ($hasUpdates) { $CleanupComponents = [switch](Test-LunqOption -Options $options -Key 'cleanup') }
    }

    $updates = @()
    if ($useUpdates) { $updates = $foundUpdates }
    $updatesSize = [long]0
    foreach ($u in $updates) { $updatesSize += $u.Length }

    $drivers = @()
    if ($useDrivers) { $drivers = $foundDrivers }
    $driversSize = [long]0
    if ($drivers.Count -gt 0) { $driversSize = Get-FolderSize $DriversPath }
    if ($drivers.Count -eq 0) { $DriversToSetup = [switch]$false }

    # Установщик и WinRE получают только обновления самой Windows.
    $peUpdates = @()
    if ($UpdatesToSetup) { $peUpdates = Select-LunqPEUpdates $updates }
    $peDrivers = @()
    if ($DriversToSetup) {
        $peDrivers = Select-LunqPEDrivers $drivers
        if ($peDrivers.Count -eq 0) { Write-Warning 'Среди драйверов нет драйверов контроллеров дисков, в установщик и WinRE добавлять нечего.' }
    }
    $servicePE = ($peUpdates.Count + $peDrivers.Count) -gt 0

    $firstLogon = $null
    if (-not $listMode -and ($useApps -or $useScripts)) {
        $logonApps = @()
        if ($useApps) { $logonApps = $foundLogon.Apps }
        $logonScripts = @()
        if ($useScripts) { $logonScripts = $foundLogon.Scripts }
        $firstLogon = [pscustomobject]@{
            AppsPath    = $foundLogon.AppsPath
            Apps        = $logonApps
            ScriptsPath = $foundLogon.ScriptsPath
            Scripts     = $logonScripts
        }
    }

    $setupAnswers = $null
    if (-not $listMode -and $useUnattend -and ($useOobe -or $useRegion -or $useBypass -or $useLocalAccount)) {
        $setupAnswers = [pscustomobject]@{
            Oobe         = [bool]$useOobe
            Region       = $(if ($useRegion) { $hostRegion } else { $null })
            Bypass       = [bool]$useBypass
            LocalAccount = [bool]$useLocalAccount
        }
    }

    Write-Section 'Проверка системы'
    $extraSize = [long]0
    if ($servicePE) { $extraSize = [long](3GB) }
    $protected = @($IsoPath, $OutputIso, $PSScriptRoot, $ConfigPath, $UpdatesPath, $DriversPath, $ProfilePath) | Where-Object { $_ } |
        ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) }
    $check = Test-LunqPrerequisites -IsoPath $IsoPath -WorkDir $WorkDir -OutputIso $OutputIso -OscdimgPath $OscdimgPath `
        -UpdatesSize $updatesSize -DriversSize $driversSize -ProtectedPaths $protected -DefaultWorkDir:($WorkDir -eq $defaultWorkDir) `
        -ExtraSize $extraSize -SkipOscdimg:$listMode -SkipOutputCheck:$listMode -OwnMountPaths $allMountDirs
    if ($check.Errors -gt 0) { throw 'Исправьте ошибки, отмеченные [FAIL], и запустите скрипт снова.' }
    if ($check.Warnings -gt 0 -and $interactive -and -not (Read-YesNo 'Есть предупреждения. Всё равно продолжить?')) { return }

    if (-not $listMode -and (Test-Path -LiteralPath $OutputIso)) {
        if ($interactive -and -not $Force) {
            Write-Warning "Файл $OutputIso уже существует."
            if (-not (Read-YesNo 'Перезаписать его?')) { return }
        }
        elseif (-not $Force) {
            throw "Файл $OutputIso уже существует. Укажите другой -OutputIso или добавьте -Force."
        }
    }

    Write-Section 'Выбор редакции'
    Write-Info 'Читаю список редакций из ISO...'
    # ISO подключается один раз и для списка редакций, и для версии выбранной.
    $iso = Mount-IsoImage -IsoPath $IsoPath
    try {
        $images = Get-IsoEditions -IsoRoot $iso.Root
        $selected = Select-LunqEdition -Images $images -Index $Index -Edition $Edition
        $editionName = ($images | Where-Object ImageIndex -eq $selected).ImageName
        $imageInfo = Get-IsoImageInfo -IsoRoot $iso.Root -Index $selected
    }
    finally { Dismount-IsoImage -Iso $iso }

    Write-Section 'Проверка версии Windows'
    $buildText = '{0}.{1}' -f $imageInfo.Build, $imageInfo.Revision
    $release = Get-WindowsReleaseName -Build $imageInfo.Build
    if ($release) { $buildText = "$buildText ($release)" }
    $buildText = "$buildText, $($imageInfo.Architecture)"
    $req = $lunqProfile.Requirements
    if ($listMode) {
        Write-Check Ok "Сборка образа: $buildText"
    }
    elseif (-not ($req.Build -or $req.MinRevision -or $req.Architecture)) {
        Write-Check Ok "Сборка образа: $buildText (профиль не задаёт требований к версии)"
    }
    else {
        $versionCheck = Test-LunqImageRequirements -Info $imageInfo -Requirements $req -HasCumulativeUpdate:(Test-CumulativeUpdate $updates)
        foreach ($w in $versionCheck.Warnings) { Write-Check Warn $w }
        if ($versionCheck.Errors.Count -eq 0) {
            if ($versionCheck.Warnings.Count -eq 0) { Write-Check Ok "Сборка образа: $buildText, подходит профилю" }
        }
        else {
            foreach ($e in $versionCheck.Errors) { Write-Check Fail $e }
            if ($SkipVersionCheck) {
                Write-Warning 'Указан -SkipVersionCheck: продолжаю, но часть твиков и имён приложений может не совпасть с этой сборкой.'
            }
            else {
                Write-Info ''
                Write-Info 'Что сделать:'
                Write-Info '  1. Скачайте свежий ISO: https://www.microsoft.com/software-download/windows11'
                if ($req.Build -and $imageInfo.Build -eq $req.Build) {
                    Write-Info '  2. Или положите последнее накопительное обновление в Config\Updates (см. README).'
                }
                Write-Info 'Если вы сознательно собираете образ на другой сборке, запустите скрипт с -SkipVersionCheck.'
                throw 'Версия Windows в ISO не подходит профилю.'
            }
        }
    }
    $hostWarning = Get-LunqHostWarning -ImageBuild $imageInfo.Build
    if ($hostWarning) { Write-Check Warn $hostWarning 'Надёжнее собирать образ на Windows 11 той же версии, что и ISO, или новее.' }

    # ---------- Режим «Что в образе» ----------
    if ($listMode) {
        $contentsPath = Join-Path (Split-Path $IsoPath -Parent) ('{0}_{1}_contents.txt' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $selected)
        Initialize-LunqSteps -Total 4
        Write-Step 'Подготовка рабочей папки' "Очищаю следы прошлого запуска и создаю $WorkDir."
        Reset-LunqWorkDir -WorkDir $WorkDir -MountPaths $allMountDirs
        New-Item -ItemType Directory -Path $mountDir, (Split-Path $wimPath -Parent) -Force | Out-Null

        Write-Step 'Копирование редакции' 'Редакция копируется из ISO в рабочую папку, чтобы её можно было открыть. Исходный ISO не изменяется.'
        $iso = Mount-IsoImage -IsoPath $IsoPath
        try {
            Export-WindowsImage -SourceImagePath (Get-InstallImagePath -IsoRoot $iso.Root) -SourceIndex $selected `
                -DestinationImagePath $wimPath -CompressionType Fast | Out-Null
        }
        finally { Dismount-IsoImage -Iso $iso }

        Write-Step 'Открытие образа' 'Образ монтируется только для чтения, в нём ничего не меняется.'
        Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir -ReadOnly | Out-Null
        $mounted = $true

        Write-Step 'Чтение приложений и компонентов' 'Списки сравниваются с профилем, чтобы было видно, что уже в нём есть.'
        $inventory = Write-LunqInventory -MountPath $mountDir -LunqProfile $lunqProfile -Path $contentsPath -Header @(
            "Содержимое образа: [$selected] $editionName, $buildText",
            "ISO: $IsoPath",
            "Создано LunqDebloater $(Get-LunqVersion), $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
            '')
        Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
        $mounted = $false

        Write-Section 'Итог'
        Write-Info ("Приложений Appx: {0}, компонентов: {1}, функций включено: {2}, выключено: {3}" -f $inventory.Appx, $inventory.Capabilities, $inventory.Enabled, $inventory.Disabled)
        if ($inventory.Missing -gt 0) { Write-Info "Записей профиля, которых нет в образе: $($inventory.Missing) (в конце файла)" }
        Write-Info "Список сохранён: $contentsPath"
        if ($interactive) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$contentsPath`"" -ErrorAction SilentlyContinue }
        return
    }

    # ---------- План и подтверждение ----------
    $skipped = 'пропущено (указан ключ -Skip)'

    Write-Section 'План сборки'
    Write-Info "Исходный ISO:     $IsoPath"
    Write-Info "Редакция:         [$selected] $editionName"
    Write-Info "Сборка:           $buildText"
    Write-Info "Профиль:          $($lunqProfile.Name) ($ProfilePath)"
    if ($updates.Count -gt 0) {
        Write-Info ("Обновления:       {0} шт., {1}" -f $updates.Count, (Format-Size $updatesSize))
        Write-UpdateList -Files $updates
    }
    else { Write-Info 'Обновления:       не встраиваются' }
    if ($drivers.Count -gt 0) {
        Write-Info ("Драйверы:         {0} шт. (.inf), {1}, в систему: {2}" -f $drivers.Count, (Format-Size $driversSize), $DriversPath)
    }
    else { Write-Info 'Драйверы:         не встраиваются' }
    if ($servicePE) {
        $what = @()
        if ($peUpdates.Count -gt 0) { $what += "обновления ($($peUpdates.Count) шт.)" }
        if ($peDrivers.Count -gt 0) { $what += "драйверы дисков ($($peDrivers.Count) шт.)" }
        Write-Info ("Установщик/WinRE: {0}" -f ($what -join ' и '))
        if ($UpdatesToSetup -and $peUpdates.Count -lt $updates.Count) { Write-Info '                  обновления .NET и прочие не для Windows PE пропускаются' }
    }
    if ($firstLogon) {
        Write-Info ("После установки:  {0}, при первом входе в Windows" -f (Format-FirstLogonSummary -FirstLogon $firstLogon))
    }
    else { Write-Info 'После установки:  ничего не выполняется' }
    if ($setupAnswers) { Write-Info ("Установка:        файл ответов, {0}" -f (Format-LunqUnattendSummary -Unattend $setupAnswers)) }
    else { Write-Info 'Установка:        без файла ответов, все вопросы как обычно' }
    $enabledCount = @($lunqProfile.Categories | Where-Object { $_.Enabled }).Count
    Write-Info ("Категории:        включено {0} из {1}" -f $enabledCount, $lunqProfile.Categories.Count)
    Write-CategoryList -LunqProfile $lunqProfile
    if ($SkipAppx) { Write-Info "Приложения Appx:  $skipped" }
    if ($SkipComponents) { Write-Info "Компоненты:       $skipped" }
    elseif ($config.Packages.Remove.Count -gt 0) { Write-Warning 'Профиль удаляет системные пакеты: это может помешать установке обновлений.' }
    if ($SkipRegistry) { Write-Info "Реестр:           $skipped" }
    if ($CleanupComponents) { Write-Info 'Очистка WinSxS:   да (/ResetBase)' }
    Write-Info "Итоговый ISO:     $OutputIso"
    Write-Info "Рабочая папка:    $WorkDir (удаляется после сборки)"
    Write-Info "Лог:              $($lunqLog.Path)"

    if ($interactive) {
        Write-Info ''
        Write-Info 'Во время сборки не закрывайте окно и не выключайте компьютер.'
        if (-not (Read-YesNo 'Начать сборку?')) {
            Write-Info 'Сборка отменена, ничего не изменено.'
            return
        }
    }

    # ---------- Сборка ----------
    # Шаги описаны списком. When решает, выполняется ли шаг, и по нему же считается «Шаг N из M».
    # Run выполняется через точку, в области видимости скрипта: так шаги дописывают $results
    # и меняют $mounted (через $script:, чтобы это было видно и анализатору).
    $results = @()
    $buildSteps = @(
        @{
            Title = 'Подготовка рабочей папки'; When = $true
            Hint  = "Очищаю следы прошлого запуска и создаю $WorkDir."
            Run   = {
                Reset-LunqWorkDir -WorkDir $WorkDir -MountPaths $allMountDirs
                New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
            }
        },
        @{
            Title = 'Копирование файлов ISO'; When = $true
            Hint  = 'Файлы установщика копируются во временную папку. Исходный ISO не изменяется.'
            Run   = { Copy-IsoContent -IsoPath $IsoPath -Destination $isoDir }
        },
        @{
            Title = 'Экспорт выбранной редакции'; When = $true
            Hint  = 'В образе остаётся только выбранная редакция: так он меньше, а следующие шаги быстрее.'
            Run   = {
                Export-SingleEdition -SourceImage (Get-InstallImagePath -IsoRoot $isoDir) -SourceIndex $selected -DestinationImage $wimPath
                $info = Get-WindowsImage -ImagePath $wimPath -Index 1
                Write-Info ("{0}, версия {1}" -f $info.ImageName, $info.Version)
            }
        },
        @{
            Title = 'Монтирование образа'; When = $true
            Hint  = 'Система распаковывается в папку mount, чтобы в ней можно было что-то менять. Это займёт несколько минут.'
            Run   = {
                Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir | Out-Null
                $script:mounted = $true
            }
        },
        @{
            Title = 'Встраивание обновлений'; When = $updates.Count -gt 0
            Hint  = 'Обновления устанавливаются в образ по порядку номеров KB. Накопительное обновление может ставиться 10-30 минут.'
            Run   = { $results += Add-LunqUpdates -MountPath $mountDir -Files $updates -ScratchDir (Join-Path $WorkDir 'scratch') }
        },
        @{
            Title = 'Встраивание драйверов'; When = $drivers.Count -gt 0
            Hint  = 'Драйверы добавляются в хранилище драйверов образа. Windows сама поставит подходящие во время установки.'
            Run   = { $results += Add-LunqDrivers -MountPath $mountDir -InfFiles $drivers -Root $DriversPath }
        },
        @{
            Title = 'Среда восстановления (WinRE)'; When = $servicePE
            Hint  = 'Обновления и драйверы добавляются в Winre.wim внутри системы: это среда, которая открывается при сбое загрузки.'
            Run   = { $results += Update-LunqRecovery -MountPath $mountDir -WorkDir $WorkDir -PEMountPath $reMountDir -Updates $peUpdates -Drivers $peDrivers -DriversRoot $DriversPath }
        },
        @{
            Title = 'Программы и скрипты после установки'; When = [bool]$firstLogon
            Hint  = 'В образ кладутся список программ и ваши скрипты. Они выполнятся один раз, когда вы впервые войдёте в Windows.'
            Run   = { $results += Install-LunqFirstLogon -MountPath $mountDir -FirstLogon $firstLogon -Architecture $imageInfo.Architecture }
        },
        @{
            Title = 'Файл ответов'; When = [bool]$setupAnswers
            Hint  = 'В корень ISO кладётся autounattend.xml: с ним установка Windows задаёт меньше вопросов.'
            Run   = {
                $results += Install-LunqUnattend -IsoRoot $isoDir -Unattend $setupAnswers -Architecture $imageInfo.Architecture `
                    -ImageLanguage (Get-LunqImageLanguage -Image $info) -WithFirstLogon:([bool]$firstLogon)
            }
        },
        @{
            Title = 'Удаление приложений Appx'; When = -not $SkipAppx
            Hint  = 'Удаляются предустановленные приложения из профиля. У новых пользователей они не появятся.'
            Run   = { $results += Remove-LunqAppx -MountPath $mountDir -Config $config }
        },
        @{
            Title = 'Удаление компонентов (Capabilities)'; When = -not $SkipComponents
            Hint  = 'Удаляются дополнительные компоненты Windows из профиля.'
            Run   = { $results += Remove-LunqCapabilities -MountPath $mountDir -Config $config }
        },
        @{
            Title = 'Отключение функций Windows (Optional Features)'; When = -not $SkipComponents
            Hint  = 'Отключаются функции из профиля, как в окне «Включение или отключение компонентов Windows».'
            Run   = {
                $results += Disable-LunqFeatures -MountPath $mountDir -Config $config
                $packages = Remove-LunqPackages -MountPath $mountDir -Config $config
                if ($packages) { $results += $packages }
            }
        },
        @{
            Title = 'Внесение настроек реестра'; When = -not $SkipRegistry
            Hint  = 'Записи из профиля вносятся в реестр образа: для всей системы и для профиля Default, от которого создаются новые пользователи.'
            Run   = { $results += Set-LunqRegistry -MountPath $mountDir -Config $config }
        },
        @{
            Title = 'Очистка хранилища компонентов'; When = [bool]$CleanupComponents
            Hint  = 'Удаляются старые версии системных файлов. Это самый долгий шаг.'
            Run   = {
                $cleanup = New-LunqResult 'Очистка хранилища компонентов' 'Cleanup'
                if (Invoke-LunqComponentCleanup -MountPath $mountDir -ScratchDir (Join-Path $WorkDir 'scratch')) {
                    $cleanup.Summary = 'старые версии системных файлов удалены'
                }
                else {
                    $cleanup.Summary = 'не удалась, образ будет больше обычного'
                    $cleanup.Failed.Add('StartComponentCleanup')
                }
                $results += $cleanup
            }
        },
        @{
            Title = 'Сохранение образа'; When = $true
            Hint  = 'В реестр образа записывается отметка о сборке, затем изменения записываются обратно в install.wim.'
            Run   = {
                $skippedSteps = @()
                if ($SkipAppx) { $skippedSteps += 'Appx' }
                if ($SkipComponents) { $skippedSteps += 'Components' }
                if ($SkipRegistry) { $skippedSteps += 'Registry' }
                Set-LunqBuildStamp -MountPath $mountDir -Values ([ordered]@{
                        Version           = Get-LunqVersion
                        BuildDate         = Get-Date -Format 'yyyy-MM-dd HH:mm'
                        SourceIso         = Split-Path $IsoPath -Leaf
                        Edition           = $editionName
                        SourceBuild       = $buildText
                        Profile           = "$($lunqProfile.Name) ($(Split-Path $ProfilePath -Leaf))"
                        Categories        = (@($lunqProfile.Categories | Where-Object { $_.Enabled } | ForEach-Object { $_.Id }) -join ', ')
                        SkippedCategories = (@($lunqProfile.Categories | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Id }) -join ', ')
                        SkippedSteps      = ($skippedSteps -join ', ')
                        Updates           = (@($updates | ForEach-Object { $_.Name }) -join ', ')
                        Drivers           = [string]$drivers.Count
                        SetupAndWinRE     = $(if ($servicePE) { 'да' } else { 'нет' })
                        SetupAnswerFile   = $(if ($setupAnswers) { Format-LunqUnattendSummary -Unattend $setupAnswers } else { 'нет' })
                        CleanupComponents = $(if ($CleanupComponents) { 'да' } else { 'нет' })
                        Apps              = $(if ($firstLogon) { $firstLogon.Apps -join ', ' } else { '' })
                        Scripts           = $(if ($firstLogon) { @($firstLogon.Scripts | ForEach-Object { $_.Name }) -join ', ' } else { '' })
                    })
                Dismount-WindowsImage -Path $mountDir -Save | Out-Null
                $script:mounted = $false
            }
        },
        @{
            Title = 'Установщик (boot.wim)'; When = $servicePE
            Hint  = 'Обновления и драйверы добавляются в установщик, с которого загружается флешка.'
            Run   = { $results += Update-LunqSetup -IsoRoot $isoDir -WorkDir $WorkDir -PEMountPath $bootMountDir -Updates $peUpdates -Drivers $peDrivers -DriversRoot $DriversPath }
        },
        @{
            Title = 'Пересжатие install.wim'; When = $true
            Hint  = 'Образ пересобирается, чтобы освободить место, которое занимали удалённые файлы.'
            Run   = { Export-SingleEdition -SourceImage $wimPath -SourceIndex 1 -DestinationImage $wimPath }
        },
        @{
            Title = 'Сборка ISO'; When = $true
            Hint  = 'oscdimg собирает загрузочный ISO для BIOS и UEFI.'
            Run   = { New-BootableIso -IsoRoot $isoDir -OutputPath $OutputIso -Oscdimg $check.Oscdimg -Label $Label }
        }
    )

    $activeSteps = @($buildSteps | Where-Object { $_.When })
    Initialize-LunqSteps -Total $activeSteps.Count
    $started = Get-Date
    foreach ($step in $activeSteps) {
        Write-Step $step.Title $step.Hint
        . $step.Run
    }

    Write-LunqReport -Results $results -LunqProfile $lunqProfile -OutputIso $OutputIso -Elapsed ((Get-Date) - $started) -LogPath $lunqLog.Path -HasFirstLogon:([bool]$firstLogon) -HasUnattend:([bool]$setupAnswers)
}
catch {
    Write-Host ''
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    Dismount-OfflineHives
    if ($mounted) {
        Write-Info 'Отключаю образ без сохранения изменений...'
        Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
        $mounted = (Get-LunqMountedPaths -Paths $mountDir).Count -gt 0
    }
    if ($lunqLog) {
        Write-Info "Подробности в логе: $($lunqLog.Path)"
        if (Test-Path -LiteralPath $lunqLog.DismPath) { Write-Info "Подробный лог DISM: $($lunqLog.DismPath)" }
    }
    if (-not $interactive) { throw }
}
finally {
    # Папку нельзя удалять, пока в ней смонтирован образ: DISM потеряет его, и понадобится dism /Cleanup-Wim.
    $stillMounted = $mounted -or ((Test-Path -LiteralPath $isoDir) -and (Get-LunqMountedPaths -Paths $allMountDirs).Count -gt 0)
    if ($stillMounted) { Write-Info "Рабочая папка $WorkDir оставлена: в ней смонтирован образ. Его отключит следующий запуск скрипта." }
    elseif (-not $KeepWorkDir -and (Test-Path -LiteralPath $isoDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lunqLog) { Stop-LunqLog }
    if ($interactive) {
        Write-Host ''
        Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null
    }
}
