#Requires -Version 5.1
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
    Добавить драйверы ещё и в установщик (boot.wim) и среду восстановления (WinRE). Нужно,
    если установщик не видит диск, например на контроллерах Intel RST/VMD или RAID.

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

# В PowerShell 7 часть командлетов модуля DISM (например, Get-AppxProvisionedPackage)
# падает с ошибкой «Класс не зарегистрирован». Поэтому скрипт всегда работает
# в Windows PowerShell 5.1 и при запуске из PowerShell 7 перезапускает себя в нём.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPowerShell)) {
        throw 'Не найден Windows PowerShell 5.1, а в PowerShell 7 модуль DISM работает с ошибками.'
    }
    Write-Host 'Модуль DISM надёжно работает только в Windows PowerShell 5.1, перезапускаю скрипт в нём...' -ForegroundColor Yellow
    $forward = @()
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Value -is [switch]) {
            if ($param.Value) { $forward += "-$($param.Key)" }
        }
        elseif ($param.Value -is [array]) {
            $forward += "-$($param.Key)"
            $forward += ($param.Value -join ',')
        }
        else {
            $forward += "-$($param.Key)"
            $forward += [string]$param.Value
        }
    }
    & $winPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forward
    exit $LASTEXITCODE
}
Import-Module Dism
Import-Module (Join-Path $PSScriptRoot 'Modules\LunqDebloater.psm1') -Force -DisableNameChecking

if (-not (Test-Administrator)) {
    if (-not $interactive) { throw 'Запустите PowerShell от имени администратора: DISM работает только с правами администратора.' }
    Write-Host ''
    Write-Host 'Для работы с образом через DISM нужны права администратора.' -ForegroundColor Yellow
    $elevated = $false
    if (Read-YesNo 'Перезапустить скрипт от имени администратора?') {
        $shell = (Get-Process -Id $PID).Path
        try {
            Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
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
$transcript = $false
$isoDir = Join-Path $WorkDir 'iso'
$mountDir = Join-Path $WorkDir 'mount'
$wimPath = Join-Path $isoDir 'sources\install.wim'

try {
    # ---------- Подготовка: всё, что можно проверить до долгой работы ----------
    if ($interactive) {
        Write-Host ''
        Write-Host 'LunqDebloater: преднастройка ISO-образа Windows 11' -ForegroundColor Cyan
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

    if ($interactive -and -not $listMode) {
        Write-Section 'Что войдёт в образ'
        Write-Info "Вот что найдено в папке настроек $ConfigPath. [x] попадёт в образ, [ ] нет."
        Write-Info 'Чтобы добавить своё, положите файлы в эту папку и запустите скрипт снова (подробнее в Config\README.txt).'
        $updatesSizeText = ''
        if ($foundUpdates.Count -gt 0) {
            $sum = [long]0
            foreach ($u in $foundUpdates) { $sum += $u.Length }
            $updatesSizeText = Format-Size $sum
        }
        $options = @(
            (New-LunqOption -Key 'updates' -Enabled $useUpdates -Available ($foundUpdates.Count -gt 0) `
                -Name $(if ($foundUpdates.Count -gt 0) { "Обновления: $($foundUpdates.Count) шт., $updatesSizeText" } else { 'Обновления: не найдены' }) `
                -Details $(if ($foundUpdates.Count -gt 0) { @($foundUpdates | ForEach-Object { $_.Name }) + 'Windows будет обновлённой сразу после установки, но сборка займёт заметно дольше.' }
                    else { 'Скачайте .msu с catalog.update.microsoft.com и положите в Config\Updates.' })),
            (New-LunqOption -Key 'cleanup' -Parent 'updates' -Enabled ([bool]$CleanupComponents) -Available ($foundUpdates.Count -gt 0) `
                -Name 'Очистить хранилище компонентов после обновлений' `
                -Details 'Образ станет меньше, но удалить встроенные обновления потом будет нельзя.'),
            (New-LunqOption -Key 'updatesToSetup' -Parent 'updates' -Enabled ([bool]$UpdatesToSetup) -Available ($foundUpdates.Count -gt 0) `
                -Name 'Обновить и установщик со средой восстановления (WinRE)' `
                -Details 'В них будут те же исправления, что и в системе. Сборка займёт на 10-20 минут дольше.'),
            (New-LunqOption -Key 'drivers' -Enabled $useDrivers -Available ($foundDrivers.Count -gt 0) `
                -Name $(if ($foundDrivers.Count -gt 0) { "Драйверы: $($foundDrivers.Count) шт. (.inf), $(Format-Size (Get-FolderSize $driversDir))" } else { 'Драйверы: не найдены' }) `
                -Details $(if ($foundDrivers.Count -gt 0) { 'Windows сама поставит их во время установки.' }
                    else { 'Положите распакованные драйверы в Config\Drivers, например: Export-WindowsDriver -Online -Destination .\Config\Drivers' })),
            (New-LunqOption -Key 'driversToSetup' -Parent 'drivers' -Enabled ([bool]$DriversToSetup) -Available ($foundDrivers.Count -gt 0) `
                -Name 'Добавить драйверы и в установщик со средой восстановления (WinRE)' `
                -Details 'Нужно, если установщик не видит диск (контроллеры Intel RST/VMD, RAID).'),
            (New-LunqOption -Key 'apps' -Enabled $useApps -Available ($foundLogon.Apps.Count -gt 0) `
                -Name $(if ($foundLogon.Apps.Count -gt 0) { "Программы при первом входе: $($foundLogon.Apps.Count) шт. (winget)" } else { 'Программы при первом входе: список пуст' }) `
                -Details $(if ($foundLogon.Apps.Count -gt 0) { $foundLogon.Apps -join ', ' } else { 'Впишите Id программ из winget в Config\Apps.txt.' })),
            (New-LunqOption -Key 'scripts' -Enabled $useScripts -Available ($foundLogon.Scripts.Count -gt 0) `
                -Name $(if ($foundLogon.Scripts.Count -gt 0) { "Скрипты при первом входе: $($foundLogon.Scripts.Count) шт." } else { 'Скрипты при первом входе: не найдены' }) `
                -Details $(if ($foundLogon.Scripts.Count -gt 0) { ($foundLogon.Scripts | ForEach-Object { $_.Name }) -join ', ' } else { 'Положите свои *.ps1 в Config\Scripts.' }))
        )
        Select-LunqBuildOptions -Options $options
        $useUpdates = Test-LunqOption -Options $options -Key 'updates'
        $useDrivers = Test-LunqOption -Options $options -Key 'drivers'
        $useApps = Test-LunqOption -Options $options -Key 'apps'
        $useScripts = Test-LunqOption -Options $options -Key 'scripts'
        $UpdatesToSetup = [switch](Test-LunqOption -Options $options -Key 'updatesToSetup')
        $DriversToSetup = [switch](Test-LunqOption -Options $options -Key 'driversToSetup')
        if ($foundUpdates.Count -gt 0) { $CleanupComponents = [switch](Test-LunqOption -Options $options -Key 'cleanup') }
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
    if ($DriversToSetup) { $peDrivers = $drivers }
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

    Write-Section 'Проверка системы'
    $extraSize = [long]0
    if ($servicePE) { $extraSize = [long](3GB) }
    $protected = @($IsoPath, $OutputIso, $PSScriptRoot, $ConfigPath, $UpdatesPath, $DriversPath, $ProfilePath) | Where-Object { $_ } |
        ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) }
    $check = Test-LunqPrerequisites -IsoPath $IsoPath -WorkDir $WorkDir -OutputIso $OutputIso -OscdimgPath $OscdimgPath `
        -UpdatesSize $updatesSize -DriversSize $driversSize -ProtectedPaths $protected -DefaultWorkDir:($WorkDir -eq $defaultWorkDir) `
        -ExtraSize $extraSize -SkipOscdimg:$listMode
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
    $images = Get-IsoEditions -IsoPath $IsoPath
    $selected = Select-LunqEdition -Images $images -Index $Index -Edition $Edition
    $editionName = ($images | Where-Object ImageIndex -eq $selected).ImageName

    Write-Section 'Проверка версии Windows'
    $imageInfo = Get-IsoImageInfo -IsoPath $IsoPath -Index $selected
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

    # ---------- Режим «Что в образе» ----------
    if ($listMode) {
        $contentsPath = Join-Path (Split-Path $IsoPath -Parent) ('{0}_{1}_contents.txt' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $selected)
        Initialize-LunqSteps -Total 4
        Write-Step 'Подготовка рабочей папки' "Очищаю следы прошлого запуска и создаю $WorkDir."
        Reset-LunqWorkDir -WorkDir $WorkDir -MountPaths $allMountDirs
        New-Item -ItemType Directory -Path $mountDir, (Split-Path $wimPath -Parent) -Force | Out-Null

        Write-Step 'Копирование редакции' 'Редакция копируется из ISO в рабочую папку, чтобы её можно было открыть. Исходный ISO не изменяется.'
        $isoRoot = Mount-IsoImage -IsoPath $IsoPath
        try {
            Export-WindowsImage -SourceImagePath (Get-InstallImagePath -IsoRoot $isoRoot) -SourceIndex $selected `
                -DestinationImagePath $wimPath -CompressionType Fast | Out-Null
        }
        finally { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }

        Write-Step 'Открытие образа' 'Образ монтируется только для чтения, в нём ничего не меняется.'
        Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir -ReadOnly | Out-Null
        $mounted = $true

        Write-Step 'Чтение приложений и компонентов' 'Списки сравниваются с профилем, чтобы было видно, что уже в нём есть.'
        $inventory = Write-LunqInventory -MountPath $mountDir -LunqProfile $lunqProfile -Path $contentsPath -Header @(
            "Содержимое образа: [$selected] $editionName, $buildText",
            "ISO: $IsoPath",
            "Создано LunqDebloater $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
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
    Start-Transcript -Path "$OutputIso.log" -Force | Out-Null
    $transcript = $true

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
        $where = 'в систему'
        if ($DriversToSetup) { $where = 'в систему, установщик и WinRE' }
        Write-Info ("Драйверы:         {0} шт. (.inf), {1}, {2}: {3}" -f $drivers.Count, (Format-Size $driversSize), $where, $DriversPath)
    }
    else { Write-Info 'Драйверы:         не встраиваются' }
    if ($servicePE) {
        $what = @()
        if ($peUpdates.Count -gt 0) { $what += "обновления ($($peUpdates.Count) шт.)" }
        if ($peDrivers.Count -gt 0) { $what += 'драйверы' }
        Write-Info ("Установщик/WinRE: {0}" -f ($what -join ' и '))
        if ($UpdatesToSetup -and $peUpdates.Count -lt $updates.Count) { Write-Info '                  обновления .NET и прочие не для Windows PE пропускаются' }
    }
    if ($firstLogon) {
        Write-Info 'Первый вход:      при первом входе в Windows'
        Write-FirstLogonSummary -FirstLogon $firstLogon
    }
    else { Write-Info 'Первый вход:      ничего не выполняется' }
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
    Write-Info "Лог:              $OutputIso.log"

    if ($interactive) {
        Write-Info ''
        Write-Info 'Во время сборки не закрывайте окно и не выключайте компьютер.'
        if (-not (Read-YesNo 'Начать сборку?')) {
            Stop-Transcript | Out-Null
            $transcript = $false
            Remove-Item -LiteralPath "$OutputIso.log" -Force -ErrorAction SilentlyContinue
            Write-Info 'Сборка отменена, ничего не изменено.'
            return
        }
    }

    # ---------- Сборка ----------
    $steps = 7
    if ($updates.Count -gt 0) { $steps += 1 }
    if ($drivers.Count -gt 0) { $steps += 1 }
    if ($servicePE) { $steps += 2 }
    if ($firstLogon) { $steps += 1 }
    if (-not $SkipAppx) { $steps += 1 }
    if (-not $SkipComponents) { $steps += 2 }
    if (-not $SkipRegistry) { $steps += 1 }
    if ($CleanupComponents) { $steps += 1 }
    Initialize-LunqSteps -Total $steps
    $started = Get-Date
    $results = @()
    $registry = $null

    Write-Step 'Подготовка рабочей папки' "Очищаю следы прошлого запуска и создаю $WorkDir."
    Reset-LunqWorkDir -WorkDir $WorkDir -MountPaths $allMountDirs
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

    Write-Step 'Копирование файлов ISO' 'Файлы установщика копируются во временную папку. Исходный ISO не изменяется.'
    Copy-IsoContent -IsoPath $IsoPath -Destination $isoDir

    Write-Step 'Экспорт выбранной редакции' 'В образе остаётся только выбранная редакция: так он меньше, а следующие шаги быстрее.'
    $sourceImage = Get-InstallImagePath -IsoRoot $isoDir
    Export-SingleEdition -SourceImage $sourceImage -SourceIndex $selected -DestinationImage $wimPath
    $info = Get-WindowsImage -ImagePath $wimPath -Index 1
    Write-Info ("{0}, версия {1}" -f $info.ImageName, $info.Version)

    Write-Step 'Монтирование образа' 'Система распаковывается в папку mount, чтобы в ней можно было что-то менять. Это займёт несколько минут.'
    Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir | Out-Null
    $mounted = $true

    if ($updates.Count -gt 0) {
        Write-Step 'Встраивание обновлений' 'Обновления устанавливаются в образ по порядку номеров KB. Накопительное обновление может ставиться 10-30 минут.'
        $results += Add-LunqUpdates -MountPath $mountDir -Files $updates -ScratchDir (Join-Path $WorkDir 'scratch')
    }

    if ($drivers.Count -gt 0) {
        Write-Step 'Встраивание драйверов' 'Драйверы добавляются в хранилище драйверов образа. Windows сама поставит подходящие во время установки.'
        $results += Add-LunqDrivers -MountPath $mountDir -InfFiles $drivers -Root $DriversPath
    }

    if ($servicePE) {
        Write-Step 'Среда восстановления (WinRE)' 'Обновления и драйверы добавляются в Winre.wim внутри системы: это среда, которая открывается при сбое загрузки.'
        $results += Update-LunqRecovery -MountPath $mountDir -WorkDir $WorkDir -PEMountPath $reMountDir -Updates $peUpdates -Drivers $peDrivers -DriversRoot $DriversPath
    }

    if ($firstLogon) {
        Write-Step 'Настройка первого входа' 'В образ кладутся список программ и ваши скрипты. Они выполнятся один раз, когда вы впервые войдёте в Windows.'
        $results += Install-LunqFirstLogon -MountPath $mountDir -FirstLogon $firstLogon -Architecture $imageInfo.Architecture
    }

    if (-not $SkipAppx) {
        Write-Step 'Удаление приложений Appx' 'Удаляются предустановленные приложения из профиля. У новых пользователей они не появятся.'
        $results += Remove-LunqAppx -MountPath $mountDir -Config $config
    }

    if (-not $SkipComponents) {
        Write-Step 'Удаление компонентов (Capabilities)' 'Удаляются дополнительные компоненты Windows из профиля.'
        $results += Remove-LunqCapabilities -MountPath $mountDir -Config $config
        Write-Step 'Отключение функций Windows (Optional Features)' 'Отключаются функции из профиля, как в окне «Включение или отключение компонентов Windows».'
        $results += Disable-LunqFeatures -MountPath $mountDir -Config $config
        $packages = Remove-LunqPackages -MountPath $mountDir -Config $config
        if ($packages) { $results += $packages }
    }

    if (-not $SkipRegistry) {
        Write-Step 'Внесение настроек реестра' 'Записи из профиля вносятся в реестр образа: для всей системы и для профиля Default, от которого создаются новые пользователи.'
        $registry = Set-LunqRegistry -MountPath $mountDir -Config $config
    }

    if ($CleanupComponents) {
        Write-Step 'Очистка хранилища компонентов' 'Удаляются старые версии системных файлов. Это самый долгий шаг.'
        Repair-WindowsImage -Path $mountDir -StartComponentCleanup -ResetBase | Out-Null
    }

    Write-Step 'Сохранение образа' 'Изменения записываются обратно в install.wim.'
    Dismount-WindowsImage -Path $mountDir -Save | Out-Null
    $mounted = $false

    if ($servicePE) {
        Write-Step 'Установщик (boot.wim)' 'Обновления и драйверы добавляются в установщик, с которого загружается флешка.'
        $results += Update-LunqSetup -IsoRoot $isoDir -WorkDir $WorkDir -PEMountPath $bootMountDir -Updates $peUpdates -Drivers $peDrivers -DriversRoot $DriversPath
    }

    Write-Step 'Пересжатие install.wim' 'Образ пересобирается, чтобы освободить место, которое занимали удалённые файлы.'
    Export-SingleEdition -SourceImage $wimPath -SourceIndex 1 -DestinationImage $wimPath

    Write-Step 'Сборка ISO' 'oscdimg собирает загрузочный ISO для BIOS и UEFI.'
    New-BootableIso -IsoRoot $isoDir -OutputPath $OutputIso -Oscdimg $check.Oscdimg -Label $Label

    Write-LunqReport -Results $results -Registry $registry -LunqProfile $lunqProfile -OutputIso $OutputIso -Elapsed ((Get-Date) - $started)
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
    if ($transcript) { Write-Info "Подробности в логе: $OutputIso.log" }
    if (-not $interactive) { throw }
}
finally {
    # Папку нельзя удалять, пока в ней смонтирован образ: DISM потеряет его, и понадобится dism /Cleanup-Wim.
    $stillMounted = $mounted -or ((Test-Path -LiteralPath $isoDir) -and (Get-LunqMountedPaths -Paths $allMountDirs).Count -gt 0)
    if ($stillMounted) { Write-Info "Рабочая папка $WorkDir оставлена: в ней смонтирован образ. Его отключит следующий запуск скрипта." }
    elseif (-not $KeepWorkDir -and (Test-Path -LiteralPath $isoDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($transcript) { Stop-Transcript | Out-Null }
    if ($interactive) {
        Write-Host ''
        Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null
    }
}
