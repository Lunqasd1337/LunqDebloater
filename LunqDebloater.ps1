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

    Если запустить скрипт без -IsoPath, он работает в пошаговом режиме: предложит
    выбрать ISO, профиль и редакцию, проверит систему, покажет план и спросит
    подтверждение. Исходный ISO при этом не изменяется.

.PARAMETER IsoPath
    Путь к исходному ISO Windows 11. Без него скрипт запускается в пошаговом режиме.

.PARAMETER OutputIso
    Путь к итоговому ISO. По умолчанию рядом с исходным с суффиксом _Lunq.

.PARAMETER ProfilePath
    JSON-профиль. По умолчанию Profiles\default.json рядом со скриптом.

.PARAMETER SkipCategory
    Id категорий профиля, которые нужно пропустить, через запятую: -SkipCategory drivers,store.
    Список Id показывается в плане сборки и в пошаговом режиме.

.PARAMETER Index
    Индекс редакции в install.wim / install.esd.

.PARAMETER Edition
    Имя редакции, например "Windows 11 Pro". Если не указаны ни Index, ни Edition,
    скрипт покажет список с пояснениями и спросит.

.PARAMETER WorkDir
    Рабочая папка (нужно около 25 ГБ свободного места на NTFS-диске).

.PARAMETER OscdimgPath
    Путь к oscdimg.exe, если он не в стандартной папке Windows ADK.

.PARAMETER UpdatesPath
    Папка с обновлениями (.msu, .cab) из каталога Центра обновления Майкрософт.
    Они будут встроены в образ до удаления приложений и компонентов.
    В пошаговом режиме скрипт сам предложит обновления из папки Updates рядом с ним.

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
    .\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Edition "Windows 11 Pro" -UpdatesPath .\Updates -CleanupComponents
    Встраивает обновления из папки Updates и затем очищает хранилище компонентов.

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Index 6 -ProfilePath .\Profiles\my.json -SkipRegistry
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$OutputIso,
    [string]$ProfilePath,
    [string[]]$SkipCategory,
    [int]$Index = 0,
    [string]$Edition,
    [string]$WorkDir = (Join-Path $env:SystemDrive 'LunqWork'),
    [string]$OscdimgPath,
    [string]$UpdatesPath,
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
    if (Read-YesNo 'Перезапустить скрипт от имени администратора?') {
        $shell = (Get-Process -Id $PID).Path
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    }
    return
}

$mounted = $false
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
    $OutputIso = [IO.Path]::GetFullPath($OutputIso)

    if (-not $ProfilePath) {
        if ($interactive) {
            Write-Section 'Выбор профиля'
            $ProfilePath = Select-LunqProfile -ProfileDir (Join-Path $PSScriptRoot 'Profiles')
        }
        else {
            $ProfilePath = Join-Path $PSScriptRoot 'Profiles\default.json'
        }
    }
    $lunqProfile = Read-LunqProfile -Path $ProfilePath
    # При запуске через -File список приходит одной строкой, поэтому делим по запятым сами.
    $SkipCategory = @($SkipCategory | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($SkipCategory.Count -gt 0) { Disable-LunqCategories -LunqProfile $lunqProfile -Ids $SkipCategory }
    if ($interactive) {
        Write-Section 'Выбор категорий'
        Select-LunqCategories -LunqProfile $lunqProfile
    }
    if (-not ($lunqProfile.Categories | Where-Object { $_.Enabled })) {
        Write-Warning 'Все категории профиля выключены: образ будет собран без удалений и твиков.'
    }
    $config = Get-LunqEffectiveConfig -LunqProfile $lunqProfile

    $updates = @()
    if ($UpdatesPath) {
        if (-not (Test-Path -LiteralPath $UpdatesPath -PathType Container)) { throw "Папка с обновлениями не найдена: $UpdatesPath" }
        $updates = Get-LunqUpdateFiles -Path $UpdatesPath
        if ($updates.Count -eq 0) { throw "В папке $UpdatesPath нет файлов .msu или .cab." }
    }
    elseif ($interactive) {
        Write-Section 'Обновления'
        $defaultUpdates = Join-Path $PSScriptRoot 'Updates'
        $found = Get-LunqUpdateFiles -Path $defaultUpdates
        if ($found.Count -eq 0) {
            Write-Info 'Обновления не будут встроены: папка Updates рядом со скриптом пуста.'
            Write-Info 'Чтобы встроить их, скачайте .msu с catalog.update.microsoft.com, положите'
            Write-Info 'в папку Updates и запустите скрипт снова. Подробнее в README.'
        }
        else {
            Write-Info 'В папке Updates найдены обновления. Если встроить их в образ, после установки'
            Write-Info 'Windows сразу будет обновлённой, но сборка займёт заметно дольше.'
            Write-UpdateList -Files $found
            if (Read-YesNo 'Встроить эти обновления?') {
                $updates = $found
                if (-not $CleanupComponents) {
                    Write-Info ''
                    Write-Info 'После обновлений в образе остаются старые версии системных файлов.'
                    Write-Info 'Очистка уменьшит образ, но удалить встроенные обновления потом будет нельзя.'
                    $CleanupComponents = [switch](Read-YesNo 'Очистить хранилище компонентов после обновлений?')
                }
            }
        }
    }
    $updatesSize = [long]0
    foreach ($u in $updates) { $updatesSize += $u.Length }

    Write-Section 'Проверка системы'
    $check = Test-LunqPrerequisites -IsoPath $IsoPath -WorkDir $WorkDir -OutputIso $OutputIso -OscdimgPath $OscdimgPath -UpdatesSize $updatesSize
    if ($check.Errors -gt 0) { throw 'Исправьте ошибки, отмеченные [FAIL], и запустите скрипт снова.' }
    if ($check.Warnings -gt 0 -and $interactive -and -not (Read-YesNo 'Есть предупреждения. Всё равно продолжить?')) { return }

    if (Test-Path -LiteralPath $OutputIso) {
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
    if (-not ($req.Build -or $req.MinRevision -or $req.Architecture)) {
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
                    Write-Info '  2. Или положите последнее накопительное обновление в папку Updates (см. README).'
                }
                Write-Info 'Если вы сознательно собираете образ на другой сборке, запустите скрипт с -SkipVersionCheck.'
                throw 'Версия Windows в ISO не подходит профилю.'
            }
        }
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
    if (-not $SkipAppx) { $steps += 1 }
    if (-not $SkipComponents) { $steps += 2 }
    if (-not $SkipRegistry) { $steps += 1 }
    if ($CleanupComponents) { $steps += 1 }
    Initialize-LunqSteps -Total $steps
    $started = Get-Date
    $results = @()
    $registry = $null

    Write-Step 'Подготовка рабочей папки' "Очищаю следы прошлого запуска и создаю $WorkDir."
    if (Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir }) {
        Write-Info 'Найден оставшийся смонтированный образ, отключаю без сохранения.'
        Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
    }
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
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
        $mounted = [bool](Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir })
    }
    if ($transcript) { Write-Info "Подробности в логе: $OutputIso.log" }
    if (-not $interactive) { throw }
}
finally {
    if (-not $mounted -and -not $KeepWorkDir -and (Test-Path -LiteralPath $isoDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($transcript) { Stop-Transcript | Out-Null }
    if ($interactive) {
        Write-Host ''
        Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null
    }
}
