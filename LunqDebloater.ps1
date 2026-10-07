#Requires -Version 5.1
#Requires -RunAsAdministrator
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

.PARAMETER IsoPath
    Путь к исходному ISO Windows 11.

.PARAMETER OutputIso
    Путь к итоговому ISO. По умолчанию рядом с исходным с суффиксом _Lunq.

.PARAMETER ProfilePath
    JSON-профиль. По умолчанию Profiles\default.json рядом со скриптом.

.PARAMETER Index
    Индекс редакции в install.wim / install.esd.

.PARAMETER Edition
    Имя редакции, например "Windows 11 Pro". Если не указаны ни Index, ни Edition,
    скрипт покажет список и спросит.

.PARAMETER WorkDir
    Рабочая папка (нужно ~15 ГБ свободного места на NTFS-диске).

.PARAMETER OscdimgPath
    Путь к oscdimg.exe, если он не в стандартной папке Windows ADK.

.PARAMETER CleanupComponents
    Выполнить очистку хранилища компонентов (StartComponentCleanup /ResetBase).
    Образ станет меньше, но установленные в него обновления нельзя будет удалить.

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11_26H2.iso -Edition "Windows 11 Pro"

.EXAMPLE
    .\LunqDebloater.ps1 -IsoPath D:\Win11.iso -Index 6 -ProfilePath .\Profiles\my.json -SkipRegistry
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$OutputIso,
    [string]$ProfilePath = (Join-Path $PSScriptRoot 'Profiles\default.json'),
    [int]$Index = 0,
    [string]$Edition,
    [string]$WorkDir = (Join-Path $env:SystemDrive 'LunqWork'),
    [string]$OscdimgPath,
    [string]$Label = 'LUNQ_WIN11',
    [switch]$SkipAppx,
    [switch]$SkipComponents,
    [switch]$SkipRegistry,
    [switch]$CleanupComponents,
    [switch]$KeepWorkDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module Dism
Import-Module (Join-Path $PSScriptRoot 'Modules\LunqDebloater.psm1') -Force -DisableNameChecking

if ($env:OS -ne 'Windows_NT') { throw 'Скрипт работает только в Windows.' }
if (-not (Test-Administrator)) { throw 'Запустите PowerShell от имени администратора.' }

$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
if (-not $OutputIso) {
    $OutputIso = Join-Path (Split-Path $IsoPath -Parent) ('{0}_Lunq.iso' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath))
}
$OutputIso = [IO.Path]::GetFullPath($OutputIso)
if ((Test-Path -LiteralPath $OutputIso) -and -not $Force) {
    throw "Файл $OutputIso уже существует. Укажите другой -OutputIso или добавьте -Force."
}

$config = Read-LunqProfile -Path $ProfilePath
$oscdimg = Find-Oscdimg -Path $OscdimgPath

$isoDir = Join-Path $WorkDir 'iso'
$mountDir = Join-Path $WorkDir 'mount'
$wimPath = Join-Path $isoDir 'sources\install.wim'
$mounted = $false
$started = Get-Date

Start-Transcript -Path "$OutputIso.log" -Force | Out-Null
try {
    Write-Step 'Подготовка рабочей папки'
    if (Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir }) {
        Write-Info 'Найден оставшийся смонтированный образ, отключаю без сохранения.'
        Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
    }
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
    Write-Info "Рабочая папка: $WorkDir"

    Write-Step 'Копирование содержимого ISO'
    Copy-IsoContent -IsoPath $IsoPath -Destination $isoDir

    Write-Step 'Выбор редакции'
    $sourceImage = Get-InstallImagePath -IsoRoot $isoDir
    $selected = Resolve-EditionIndex -ImagePath $sourceImage -Index $Index -Edition $Edition
    $info = Get-WindowsImage -ImagePath $sourceImage -Index $selected
    Write-Info ("Выбрана редакция [{0}] {1}, версия {2}" -f $selected, $info.ImageName, $info.Version)
    Write-Info 'Экспортирую редакцию в отдельный install.wim...'
    Export-SingleEdition -SourceImage $sourceImage -SourceIndex $selected -DestinationImage $wimPath

    Write-Step 'Монтирование install.wim'
    Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir | Out-Null
    $mounted = $true

    if (-not $SkipAppx) {
        Write-Step 'Удаление Appx-приложений'
        Remove-LunqAppx -MountPath $mountDir -Config $config
    }

    if (-not $SkipComponents) {
        Write-Step 'Удаление компонентов Windows (Capabilities)'
        Remove-LunqCapabilities -MountPath $mountDir -Config $config
        Write-Step 'Отключение компонентов Windows (Optional Features)'
        Disable-LunqFeatures -MountPath $mountDir -Config $config
        Remove-LunqPackages -MountPath $mountDir -Config $config
    }

    if (-not $SkipRegistry) {
        Write-Step 'Внесение настроек реестра'
        Set-LunqRegistry -MountPath $mountDir -Config $config
    }

    if ($CleanupComponents) {
        Write-Step 'Очистка хранилища компонентов (может занять много времени)'
        Repair-WindowsImage -Path $mountDir -StartComponentCleanup -ResetBase | Out-Null
    }

    Write-Step 'Сохранение образа'
    Dismount-WindowsImage -Path $mountDir -Save | Out-Null
    $mounted = $false

    Write-Step 'Пересжатие install.wim'
    Export-SingleEdition -SourceImage $wimPath -SourceIndex 1 -DestinationImage $wimPath

    Write-Step 'Сборка ISO'
    New-BootableIso -IsoRoot $isoDir -OutputPath $OutputIso -Oscdimg $oscdimg -Label $Label

    Write-Step ('Готово за {0:hh\:mm\:ss}: {1}' -f ((Get-Date) - $started), $OutputIso)
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
    throw
}
finally {
    if (-not $mounted -and -not $KeepWorkDir -and (Test-Path -LiteralPath $WorkDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Stop-Transcript | Out-Null
}
