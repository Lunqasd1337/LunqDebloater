<#
.SYNOPSIS
    Преднастройка ISO-образа Windows 11: удаление приложений, компонентов и настройки реестра.
    Offline preconfiguration of a Windows 11 ISO: removes apps and components, applies registry settings.

.DESCRIPTION
    Запуск без параметров открывает пошаговый режим: скрипт сам спросит всё, что нужно.
    Описание всех параметров: README.md рядом со скриптом или Get-Help .\LunqDebloater.ps1 -Online.

    Run it without parameters for the step-by-step mode: the script asks for everything it needs.
    All parameters are described in README.en.md next to the script and online:
    https://github.com/Lunqasd1337/LunqDebloater/blob/main/README.en.md

.LINK
    https://github.com/Lunqasd1337/LunqDebloater#readme

.LINK
    https://github.com/Lunqasd1337/LunqDebloater/blob/main/README.en.md
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
    [string[]]$IncludeCategory,
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
    [ValidatePattern('^[A-Za-z0-9_-]{1,32}$')][string]$Label = 'LUNQ_WIN11',
    [switch]$SkipAppx,
    [switch]$SkipComponents,
    [switch]$SkipRegistry,
    [switch]$CleanupComponents,
    [switch]$SkipVersionCheck,
    [switch]$KeepWorkDir,
    [switch]$Force,
    [ValidateSet('ru', 'en')][string]$Language,
    [string]$EventsPath,
    [switch]$ListEditions
)

$ErrorActionPreference = 'Stop'
$interactive = -not $IsoPath

if ($env:OS -ne 'Windows_NT') {
    # Модуль с таблицами строк ещё не загружен, поэтому язык выбирается здесь же.
    $osLanguage = $Language
    if (-not $osLanguage) { try { $osLanguage = (Get-UICulture).TwoLetterISOLanguageName } catch { $osLanguage = 'en' } }
    if ($osLanguage -eq 'ru') { throw 'Скрипт работает только в Windows.' }
    throw 'This script only works on Windows.'
}

Import-Module (Join-Path $PSScriptRoot 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
if (-not $Language) { $Language = Get-LunqDefaultLanguage }
Set-LunqLanguage -Language $Language
# Параметры с путями: при перезапуске они передаются полными, ведь новое окно может открыться в другой папке.
$pathParams = 'IsoPath', 'OutputIso', 'ConfigPath', 'ProfilePath', 'WorkDir', 'OscdimgPath', 'UpdatesPath', 'DriversPath', 'EventsPath'

# В PowerShell 7 часть командлетов модуля DISM (например, Get-AppxProvisionedPackage)
# падает с ошибкой «Класс не зарегистрирован». Поэтому скрипт всегда работает
# в Windows PowerShell 5.1 и при запуске из PowerShell 7 перезапускает себя в нём.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPowerShell)) {
        throw (Get-LunqText 'Main.NoWindowsPowerShell')
    }
    Write-Host (Get-LunqText 'Main.Relaunch51') -ForegroundColor Yellow
    $forward = ConvertTo-LunqArgumentList -BoundParameters $PSBoundParameters -PathParameters $pathParams
    & $winPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forward
    exit $LASTEXITCODE
}
Import-Module Dism
if ($ListEditions -and $interactive) { throw (Get-LunqText 'Main.ListEditionsNeedIso') }

# События для своих программ: окно с прогрессом читает их из файла, пока идёт сборка.
# Файл открывается только здесь, в Windows PowerShell 5.1: запуск из PowerShell 7 выше
# передал путь дальше и сам в файл не пишет.
if ($EventsPath) {
    # Вопрос в консоли повесил бы программу, которая ждёт событий, поэтому без -IsoPath нельзя.
    if ($interactive) { throw (Get-LunqText 'Main.EventsNeedIso') }
    $EventsPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EventsPath)
    Start-LunqEvents -Path $EventsPath
    Send-LunqEvent 'start' @{ version = (Get-LunqVersion); language = $Language; mode = $(if ($ListEditions) { 'editions' } elseif ($ListContents) { 'list' } else { 'build' }); pid = $PID }
}

if (-not (Test-Administrator)) {
    if (-not $interactive) {
        Send-LunqFailure (Get-LunqText 'Main.NeedAdminThrow')
        throw (Get-LunqText 'Main.NeedAdminThrow')
    }
    Write-Host ''
    Write-Host (Get-LunqText 'Main.NeedAdmin') -ForegroundColor Yellow
    $elevated = $false
    if (Read-YesNo (Get-LunqText 'Main.AskElevate')) {
        $shell = (Get-Process -Id $PID).Path
        # Новое окно открывается в System32, поэтому пути передаются полными. Start-Process
        # склеивает аргументы через пробел, поэтому каждый берётся в кавычки.
        $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") +
            (ConvertTo-LunqArgumentList -BoundParameters $PSBoundParameters -PathParameters $pathParams -Quote)
        try {
            Start-Process -FilePath $shell -Verb RunAs -ArgumentList ($relaunch -join ' ')
            $elevated = $true
        }
        catch { Write-LunqWarning (Get-LunqText 'Main.ElevateDenied') }
    }
    if (-not $elevated) {
        Write-Info (Get-LunqText 'Main.NoAdminExit')
        Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    }
    return
}

# Только список редакций ISO: окно показывает его до сборки. Ничего не проверяется и не меняется,
# поэтому нет ни лога, ни блокировки второго запуска.
if ($ListEditions) {
    try {
        $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
        $iso = Mount-IsoImage -IsoPath $IsoPath
        try { $images = Get-IsoEditions -IsoRoot $iso.Root }
        finally { Dismount-IsoImage -Iso $iso }
    }
    catch {
        Send-LunqFailure $_.Exception.Message
        throw
    }
    Write-EditionList -Images $images
    Send-LunqEditionsEvent -Images $images
    Send-LunqEvent 'done' @{ ok = $true; warnings = 0 }
    Stop-LunqEvents
    return
}

# Относительные пути считаются от текущей папки PowerShell. [IO.Path]::GetFullPath
# для этого не годится: он берёт рабочую папку процесса, а она не меняется после cd.
$defaultWorkDir = Join-Path $env:SystemDrive 'LunqWork'
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir).TrimEnd('\')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'Config' }
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath).TrimEnd('\')

# Что нужно знать при ошибке. Mounted: смонтирован ли образ. WorkDirOwned: рабочую папку можно
# удалить в конце, только если этот запуск сам её пересоздал, иначе проверка могла её отвергнуть
# и в ней лежат чужие файлы. Шаги сборки меняют эту же таблицу через контекст.
$state = @{ Mounted = $false; WorkDirOwned = $false; ImageInfo = $null }
$bootMountDir = Join-Path $WorkDir 'bootmount'
$reMountDir = Join-Path $WorkDir 'remount'
$allMountDirs = @((Join-Path $WorkDir 'mount'), $bootMountDir, $reMountDir)
$listMode = [bool]$ListContents
$lunqLog = $null
$failed = $false
$isoDir = Join-Path $WorkDir 'iso'
$mountDir = Join-Path $WorkDir 'mount'
$wimPath = Join-Path $isoDir 'sources\install.wim'
# Драйверы этого компьютера выгружаются во временную папку: в Config они остались бы и для следующих сборок.
# Обе папки удаляются в конце запуска: драйверы видеокарты занимают на системном диске 1-3 ГБ.
$hostDriversDir = Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater\HostDrivers'
$cabCheckDir = Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater\CabCheck'
# Что попадает в событие done в конце запуска.
$contentsPath = $null
$bugReport = $null
$dismLog = $null
$runStarted = Get-Date

# Заголовок окна не меняется в некоторых консолях (например, при перенаправленном выводе), это не ошибка.
try { $Host.UI.RawUI.WindowTitle = "LunqDebloater $(Get-LunqVersion)" } catch { }

$runLock = Enter-LunqRunLock
if (-not $runLock) {
    Write-Host (Get-LunqText 'Main.AlreadyRunning') -ForegroundColor Red
    if (-not $interactive) {
        Send-LunqFailure (Get-LunqText 'Main.AlreadyRunning')
        throw (Get-LunqText 'Main.AlreadyRunning')
    }
    Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    return
}

try {
    # Лог ведётся с самого начала: так в него попадают и ошибки при выборе ISO и проверке системы.
    $lunqLog = Start-LunqLog -Dir (Join-Path $PSScriptRoot 'Logs')
    Write-LunqRunInfo -BoundParameters $PSBoundParameters -DismLog $lunqLog.DismPath
    Send-LunqEvent 'log' @{ path = $lunqLog.Path; dismLog = $lunqLog.DismPath }

    # ---------- Подготовка: всё, что можно проверить до долгой работы ----------
    if ($interactive) {
        Write-Host ''
        Write-Host (Get-LunqText 'Main.Banner' (Get-LunqVersion)) -ForegroundColor Cyan
        Write-Info (Get-LunqText 'Main.Intro1')
        Write-Info (Get-LunqText 'Main.Intro2')
        Write-Info (Get-LunqText 'Main.Intro3')

        Write-Section (Get-LunqText 'Main.SectionAction')
        Write-Host '    [1] ' -ForegroundColor Cyan -NoNewline; Write-Host (Get-LunqText 'Main.ActionBuild')
        Write-Host '    [2] ' -ForegroundColor Cyan -NoNewline; Write-Host (Get-LunqText 'Main.ActionList')
        $listMode = ((Read-Host (Get-LunqText 'Main.ActionPrompt')).Trim() -eq '2')

        Write-Section (Get-LunqText 'Main.SectionIso')
        Write-Info (Get-LunqText 'Main.ChooseIso')
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

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Container)) { throw (Get-LunqText 'Main.ConfigNotFound' $ConfigPath) }
    if (-not $ProfilePath) {
        if ($interactive) {
            Write-Section (Get-LunqText 'Main.SectionProfile')
            $ProfilePath = Select-LunqProfile -ProfileDir $ConfigPath
        }
        else {
            $ProfilePath = Join-Path $ConfigPath 'Profile.json'
        }
    }
    $lunqProfile = Read-LunqProfile -Path $ProfilePath
    # При запуске через -File список приходит одной строкой, поэтому делим по запятым сами.
    # Сначала включаем, потом выключаем: если Id есть в обоих списках, побеждает пропуск.
    $IncludeCategory = @($IncludeCategory | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($IncludeCategory.Count -gt 0) { Enable-LunqCategories -LunqProfile $lunqProfile -Ids $IncludeCategory }
    $SkipCategory = @($SkipCategory | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($SkipCategory.Count -gt 0) { Disable-LunqCategories -LunqProfile $lunqProfile -Ids $SkipCategory }
    if ($interactive -and -not $listMode) {
        Write-Section (Get-LunqText 'Main.SectionCategories')
        Select-LunqCategories -LunqProfile $lunqProfile
    }
    if (-not $listMode -and -not ($lunqProfile.Categories | Where-Object { $_.Enabled })) {
        Write-LunqWarning (Get-LunqText 'Main.AllCategoriesOff')
    }
    $config = Get-LunqEffectiveConfig -LunqProfile $lunqProfile

    # ---------- Что лежит в Config ----------
    # Обновления, драйверы, программы и скрипты берутся из Config. -UpdatesPath и -DriversPath
    # заменяют свои подпапки и должны указывать на непустую папку. В пошаговом режиме папку
    # с обновлениями и драйверами можно выбрать прямо в сводке, а драйверы взять с этого компьютера.
    $updatesDir = Join-Path $ConfigPath 'Updates'
    $driversDir = Join-Path $ConfigPath 'Drivers'
    if (-not $listMode) {
        if ($UpdatesPath) {
            if (-not (Test-Path -LiteralPath $UpdatesPath -PathType Container)) { throw (Get-LunqText 'Main.UpdatesDirNotFound' $UpdatesPath) }
            $updatesDir = (Resolve-Path -LiteralPath $UpdatesPath).Path
        }
        if ($DriversPath) {
            if (-not (Test-Path -LiteralPath $DriversPath -PathType Container)) { throw (Get-LunqText 'Main.DriversDirNotFound' $DriversPath) }
            $driversDir = (Resolve-Path -LiteralPath $DriversPath).Path
        }
    }
    $foundLogon = Get-LunqFirstLogon -AppsPath (Join-Path $ConfigPath 'Apps.txt') -ScriptsPath (Join-Path $ConfigPath 'Scripts')
    $hostRegion = $null
    if (-not $listMode) { $hostRegion = Get-LunqHostRegion }
    # Что пользователь включил и выключил в сводке (Key пункта и Enabled). Когда сводка
    # показывается снова после выбора папки, его выбор сохраняется.
    $choices = @{}
    # Какого вида .cab в корне папки обновлений: распознаётся один раз, а не при каждом показе сводки.
    $cabKinds = @{}
    $peDriverKinds = @{}

    while ($true) {
        $found = [pscustomobject]@{ Updates = @(); SafeOS = @(); SetupDU = @(); DUNames = @(); Drivers = @() }
        if (-not $listMode) {
            $found = Find-LunqBuildInputs -UpdatesDir $updatesDir -DriversDir $driversDir -CabCheckDir $cabCheckDir -CabCache $cabKinds
            if ($UpdatesPath -and ($found.Updates.Count + $found.SafeOS.Count + $found.SetupDU.Count) -eq 0) { throw (Get-LunqText 'Main.UpdatesDirEmpty' $UpdatesPath) }
            if ($DriversPath -and $found.Drivers.Count -eq 0) { throw (Get-LunqText 'Main.DriversDirEmpty' $DriversPath) }
        }
        $foundUpdates = $found.Updates
        $foundSafeOS = $found.SafeOS
        $foundSetupDU = $found.SetupDU
        $foundDrivers = $found.Drivers
        $foundDU = @($foundSafeOS) + @($foundSetupDU)

        # Файл ответов: в пошаговом режиме включён по умолчанию, с параметрами только по ключам.
        $withUnattend = $interactive -or $Unattend -or $BypassRequirements -or $LocalAccount
        $use = @{
            updates        = ($foundUpdates.Count + $foundDU.Count) -gt 0 -and -not $SkipUpdates
            cleanup        = [bool]$CleanupComponents
            updatesToSetup = [bool]$UpdatesToSetup
            drivers        = $foundDrivers.Count -gt 0 -and -not $SkipDrivers
            driversToSetup = [bool]$DriversToSetup
            apps           = $foundLogon.Apps.Count -gt 0 -and -not $SkipApps
            scripts        = $foundLogon.Scripts.Count -gt 0 -and -not $SkipScripts
            unattend       = [bool]$withUnattend
            oobe           = [bool]$withUnattend
            region         = [bool]$withUnattend
            bypass         = [bool]$BypassRequirements
            localAccount   = [bool]$LocalAccount
        }
        $action = $null
        if ($interactive -and -not $listMode) {
            Write-Section (Get-LunqText 'Main.SectionContents')
            Write-Info (Get-LunqText 'Main.ContentsIntro' $ConfigPath)
            Write-Info (Get-LunqText 'Main.ContentsHowTo')
            $options = New-LunqContentOptions -Found $found -FirstLogon $foundLogon -Use $use -HostRegion $hostRegion `
                -UpdatesDir $updatesDir -DriversDir $driversDir -PEDriverCache $peDriverKinds
            foreach ($option in $options) {
                if ($choices.ContainsKey($option.Key)) { $option.Enabled = $choices[$option.Key] }
            }
            $action = Select-LunqBuildOptions -Options $options
            foreach ($option in $options) {
                if (-not $option.Action) { $choices[$option.Key] = $option.Enabled }
            }
            foreach ($key in @($use.Keys)) { $use[$key] = Test-LunqOption -Options $options -Key $key }
            $UpdatesToSetup = [switch]$use.updatesToSetup
            $DriversToSetup = [switch]$use.driversToSetup
            if (@($options | Where-Object { $_.Key -eq 'cleanup' -and $_.Available }).Count -gt 0) { $CleanupComponents = [switch]$use.cleanup }
        }
        $useUpdates = $use.updates
        $useDrivers = $use.drivers
        $useApps = $use.apps
        $useScripts = $use.scripts
        $useUnattend = $use.unattend
        $useOobe = $use.oobe
        $useRegion = $use.region
        $useBypass = $use.bypass
        $useLocalAccount = $use.localAccount
        if (-not $action) { break }

        # Новая папка заменяет прежнюю, а пункты обновлений или драйверов снова получают
        # значения по умолчанию: выбрав папку, пользователь хочет её содержимое в образе.
        $picked = Invoke-LunqContentAction -Action $action -HostDriversDir $hostDriversDir
        if ($picked -and $picked.Kind -eq 'Updates') {
            $updatesDir = $picked.Path
            $UpdatesPath = $picked.Path
            foreach ($key in 'updates', 'updatesToSetup') { $choices.Remove($key) }
        }
        elseif ($picked) {
            $driversDir = $picked.Path
            $DriversPath = $picked.Path
            foreach ($key in 'drivers', 'driversToSetup') { $choices.Remove($key) }
        }
    }
    if ($foundDrivers.Count -gt 0) { $DriversPath = (Resolve-Path -LiteralPath $driversDir).Path }

    $updates = @()
    $safeOSUpdates = @()
    $setupDU = @()
    if ($useUpdates) {
        $updates = $foundUpdates
        if ($UpdatesToSetup) {
            $safeOSUpdates = $foundSafeOS
            $setupDU = $foundSetupDU
        }
    }
    $updatesSize = Get-LunqFilesSize (@($updates) + $safeOSUpdates + $setupDU)

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
        $peDrivers = Select-LunqPEDrivers $drivers -Cache $peDriverKinds
        if ($peDrivers.Count -eq 0) { Write-LunqWarning (Get-LunqText 'Main.NoPEDrivers') }
    }
    $serviceRecovery = ($peUpdates.Count + $safeOSUpdates.Count + $peDrivers.Count) -gt 0
    $servicePE = $serviceRecovery -or $setupDU.Count -gt 0

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

    Write-Section (Get-LunqText 'Main.SectionSystem')
    $extraSize = [long]0
    if ($servicePE) { $extraSize = [long](3GB) }
    $protected = @($IsoPath, $OutputIso, $PSScriptRoot, $ConfigPath, $UpdatesPath, $DriversPath, $ProfilePath) | Where-Object { $_ } |
        ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) }
    $check = Test-LunqPrerequisites -IsoPath $IsoPath -WorkDir $WorkDir -OutputIso $OutputIso -OscdimgPath $OscdimgPath `
        -UpdatesSize $updatesSize -DriversSize $driversSize -ProtectedPaths $protected -DefaultWorkDir:($WorkDir -eq $defaultWorkDir) `
        -ExtraSize $extraSize -SkipOscdimg:$listMode -SkipOutputCheck:$listMode -OwnMountPaths $allMountDirs
    if ($check.Errors -gt 0) { throw (Get-LunqText 'Main.FixErrors') }
    if ($check.Warnings -gt 0 -and $interactive -and -not (Read-YesNo (Get-LunqText 'Main.AskContinueWarnings'))) { return }

    if (-not $listMode -and (Test-Path -LiteralPath $OutputIso)) {
        if ($interactive -and -not $Force) {
            Write-LunqWarning (Get-LunqText 'Main.OutputExists' $OutputIso)
            if (-not (Read-YesNo (Get-LunqText 'Main.AskOverwrite'))) { return }
        }
        elseif (-not $Force) {
            throw (Get-LunqText 'Main.OutputExistsThrow' $OutputIso)
        }
    }

    Write-Section (Get-LunqText 'Main.SectionEdition')
    Write-Info (Get-LunqText 'Main.ReadingEditions')
    # ISO подключается один раз и для списка редакций, и для версии выбранной.
    $iso = Mount-IsoImage -IsoPath $IsoPath
    try {
        $images = Get-IsoEditions -IsoRoot $iso.Root
        Send-LunqEditionsEvent -Images $images
        if ($EventsPath -and $Index -le 0 -and -not $Edition -and @($images).Count -gt 1) { throw (Get-LunqText 'Main.EventsNeedEdition') }
        $selected = Select-LunqEdition -Images $images -Index $Index -Edition $Edition
        $editionName = ($images | Where-Object ImageIndex -eq $selected).ImageName
        $imageInfo = Get-IsoImageInfo -IsoRoot $iso.Root -Index $selected
        # Чужой autounattend.xml в ISO иначе обнаружился бы только на шаге файла ответов,
        # после обновлений и драйверов.
        if ($setupAnswers -and (Test-Path -LiteralPath (Join-Path $iso.Root 'autounattend.xml'))) { throw (Get-LunqText 'Unattend.Exists') }
    }
    finally { Dismount-IsoImage -Iso $iso }

    Write-Section (Get-LunqText 'Main.SectionVersion')
    $buildText = '{0}.{1}' -f $imageInfo.Build, $imageInfo.Revision
    $release = Get-WindowsReleaseName -Build $imageInfo.Build
    if ($release) { $buildText = "$buildText ($release)" }
    $buildText = "$buildText, $($imageInfo.Architecture)"
    $req = $lunqProfile.Requirements
    if ($listMode) {
        Write-Check Ok (Get-LunqText 'Main.ImageBuild' $buildText)
    }
    elseif (-not ($req.Build -or $req.MinRevision -or $req.Architecture)) {
        Write-Check Ok (Get-LunqText 'Main.ImageBuildNoReq' $buildText)
    }
    else {
        $versionCheck = Test-LunqImageRequirements -Info $imageInfo -Requirements $req -HasCumulativeUpdate:(Test-CumulativeUpdate $updates)
        foreach ($w in $versionCheck.Warnings) { Write-Check Warn $w }
        if ($versionCheck.Errors.Count -eq 0) {
            if ($versionCheck.Warnings.Count -eq 0) { Write-Check Ok (Get-LunqText 'Main.ImageBuildOk' $buildText) }
        }
        else {
            foreach ($e in $versionCheck.Errors) { Write-Check Fail $e }
            if ($SkipVersionCheck) {
                Write-LunqWarning (Get-LunqText 'Main.SkipVersionCheckWarn')
            }
            else {
                Write-Info ''
                Write-Info (Get-LunqText 'Main.WhatToDo')
                Write-Info (Get-LunqText 'Main.WhatToDoIso')
                if ($req.Build -and $imageInfo.Build -eq $req.Build) {
                    Write-Info (Get-LunqText 'Main.WhatToDoUpdate')
                }
                Write-Info (Get-LunqText 'Main.WhatToDoSkip')
                throw (Get-LunqText 'Main.VersionMismatch')
            }
        }
    }
    $hostWarning = Get-LunqHostWarning -ImageBuild $imageInfo.Build
    if ($hostWarning) { Write-Check Warn $hostWarning (Get-LunqText 'Main.HostWarningHint') }

    # ---------- Режим «Что в образе» ----------
    if ($listMode) {
        $contentsPath = Join-Path (Split-Path $IsoPath -Parent) ('{0}_{1}_contents.txt' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $selected)
        $inventoryContext = @{
            State        = $state
            WorkDir      = $WorkDir
            MountPaths   = $allMountDirs
            MountDir     = $mountDir
            WimPath      = $wimPath
            IsoPath      = $IsoPath
            Index        = $selected
            Profile      = $lunqProfile
            ContentsPath = $contentsPath
            Header       = @(
                (Get-LunqText 'Main.InventoryHeader' $selected $editionName $buildText),
                "ISO: $IsoPath",
                (Get-LunqText 'Main.InventoryCreated' (Get-LunqVersion) (Get-Date -Format 'yyyy-MM-dd HH:mm')),
                '')
        }
        $null = Invoke-LunqBuild -Context $inventoryContext -Inventory
        $inventory = $state.Inventory

        Write-Section (Get-LunqText 'Main.SectionSummary')
        Write-Info (Get-LunqText 'Main.InventoryCounts' $inventory.Appx $inventory.Capabilities $inventory.Enabled $inventory.Disabled)
        if ($inventory.Missing -gt 0) { Write-Info (Get-LunqText 'Main.InventoryMissing' $inventory.Missing) }
        Write-Info (Get-LunqText 'Main.InventorySaved' $contentsPath)
        if ($interactive) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$contentsPath`"" -ErrorAction SilentlyContinue }
        return
    }

    # ---------- План и подтверждение ----------
    $skipped = Get-LunqText 'Main.PlanSkipped'

    Write-Section (Get-LunqText 'Main.SectionPlan')
    Write-Info (Get-LunqText 'Main.PlanSourceIso' $IsoPath)
    Write-Info (Get-LunqText 'Main.PlanEdition' $selected $editionName)
    Write-Info (Get-LunqText 'Main.PlanBuild' $buildText)
    Write-Info (Get-LunqText 'Main.PlanProfile' $lunqProfile.Name $ProfilePath)
    if ($updates.Count -gt 0) {
        Write-Info (Get-LunqText 'Main.PlanUpdates' $updates.Count (Format-Size $updatesSize))
        Write-UpdateList -Files $updates
    }
    else { Write-Info (Get-LunqText 'Main.PlanUpdatesNone') }
    if ($drivers.Count -gt 0) {
        Write-Info (Get-LunqText 'Main.PlanDrivers' $drivers.Count (Format-Size $driversSize) $DriversPath)
    }
    else { Write-Info (Get-LunqText 'Main.PlanDriversNone') }
    if ($servicePE) {
        $what = @()
        if ($peUpdates.Count -gt 0) { $what += Get-LunqText 'Main.PlanPEUpdates' $peUpdates.Count }
        if ($safeOSUpdates.Count -gt 0) { $what += Get-LunqText 'Main.PlanPESafeOS' $safeOSUpdates.Count }
        if ($setupDU.Count -gt 0) { $what += Get-LunqText 'Main.PlanPESetupDU' $setupDU.Count }
        if ($peDrivers.Count -gt 0) { $what += Get-LunqText 'Main.PlanPEDrivers' $peDrivers.Count }
        $whatText = $what[-1]
        if ($what.Count -gt 1) { $whatText = ($what[0..($what.Count - 2)] -join ', ') + (Get-LunqText 'Main.PlanPEJoin') + $what[-1] }
        Write-Info (Get-LunqText 'Main.PlanPE' $whatText)
        if ($UpdatesToSetup -and $peUpdates.Count -lt $updates.Count) { Write-Info (Get-LunqText 'Main.PlanPESkipped') }
    }
    if ($useUpdates -and -not $UpdatesToSetup -and $foundDU.Count -gt 0) { Write-Info (Get-LunqText 'Main.PlanDUSkipped') }
    if ($firstLogon) {
        Write-Info (Get-LunqText 'Main.PlanFirstLogon' (Format-FirstLogonSummary -FirstLogon $firstLogon))
    }
    else { Write-Info (Get-LunqText 'Main.PlanFirstLogonNone') }
    if ($setupAnswers) { Write-Info (Get-LunqText 'Main.PlanUnattend' (Format-LunqUnattendSummary -Unattend $setupAnswers)) }
    else { Write-Info (Get-LunqText 'Main.PlanUnattendNone') }
    $enabledCount = @($lunqProfile.Categories | Where-Object { $_.Enabled }).Count
    Write-Info (Get-LunqText 'Main.PlanCategories' $enabledCount $lunqProfile.Categories.Count)
    Write-CategoryList -LunqProfile $lunqProfile
    if ($SkipAppx) { Write-Info (Get-LunqText 'Main.PlanAppx' $skipped) }
    if ($SkipComponents) { Write-Info (Get-LunqText 'Main.PlanComponents' $skipped) }
    elseif ($config.Packages.Remove.Count -gt 0) { Write-LunqWarning (Get-LunqText 'Main.PackagesWarning') }
    if ($SkipRegistry) { Write-Info (Get-LunqText 'Main.PlanRegistry' $skipped) }
    if ($CleanupComponents) { Write-Info (Get-LunqText 'Main.PlanCleanup') }
    Write-Info (Get-LunqText 'Main.PlanOutputIso' $OutputIso)
    Write-Info (Get-LunqText 'Main.PlanWorkDir' $WorkDir)
    Write-Info (Get-LunqText 'Main.PlanLog' $lunqLog.Path)

    if ($interactive) {
        Write-Info ''
        Write-Host (Get-LunqText 'Main.Disclaimer1') -ForegroundColor Yellow
        Write-Host (Get-LunqText 'Main.Disclaimer2') -ForegroundColor Yellow
        Write-Info (Get-LunqText 'Main.DontClose')
        if (-not (Read-YesNo (Get-LunqText 'Main.AskStart'))) {
            Write-Info (Get-LunqText 'Main.Cancelled')
            return
        }
    }

    # ---------- Сборка ----------
    # Шаги описаны в модуле (Private\Build.ps1) и получают всё, что им нужно, через этот контекст.
    $build = @{
        State             = $state
        WorkDir           = $WorkDir
        MountPaths        = $allMountDirs
        MountDir          = $mountDir
        BootMountDir      = $bootMountDir
        ReMountDir        = $reMountDir
        IsoPath           = $IsoPath
        IsoDir            = $isoDir
        WimPath           = $wimPath
        Index             = $selected
        OutputIso         = $OutputIso
        Oscdimg           = $check.Oscdimg
        Label             = $Label
        Updates           = $updates
        SafeOSUpdates     = $safeOSUpdates
        SetupUpdates      = $setupDU
        PEUpdates         = $peUpdates
        Drivers           = $drivers
        PEDrivers         = $peDrivers
        DriversPath       = $DriversPath
        ServiceRecovery   = $serviceRecovery
        ServicePE         = $servicePE
        FirstLogon        = $firstLogon
        SetupAnswers      = $setupAnswers
        Architecture      = $imageInfo.Architecture
        Config            = $config
        SkipAppx          = [bool]$SkipAppx
        SkipComponents    = [bool]$SkipComponents
        SkipRegistry      = [bool]$SkipRegistry
        CleanupComponents = [bool]$CleanupComponents
        Profile           = $lunqProfile
        ProfilePath       = $ProfilePath
        EditionName       = $editionName
        BuildText         = $buildText
    }
    $started = Get-Date
    $results = Invoke-LunqBuild -Context $build
    Send-LunqResultEvents -Results $results

    Write-LunqReport -Results $results -LunqProfile $lunqProfile -OutputIso $OutputIso -Elapsed ((Get-Date) - $started) -LogPath $lunqLog.Path -StepTimes $state['StepTimes'] -HasFirstLogon:([bool]$firstLogon) -HasUnattend:([bool]$setupAnswers)
}
catch {
    $failed = $true
    Write-Host ''
    Write-Host (Get-LunqText 'Main.Error' $_.Exception.Message) -ForegroundColor Red
    $where = @()
    if ($_.ScriptStackTrace) { $where = @($_.ScriptStackTrace -split '\r?\n') }
    Send-LunqEvent 'error' @{ text = $_.Exception.Message; where = $where }
    # Где именно случилась ошибка: по присланному логу сразу видно, какую функцию смотреть.
    if ($_.ScriptStackTrace) {
        Write-Host ('    ' + (Get-LunqText 'Main.ErrorWhere')) -ForegroundColor DarkGray
        foreach ($line in ($_.ScriptStackTrace -split '\r?\n')) { Write-Host "      $line" -ForegroundColor DarkGray }
    }
    Dismount-OfflineHives
    if ($state.Mounted) {
        Write-Info (Get-LunqText 'Main.DiscardImage')
        Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
        $state.Mounted = Test-LunqAnyMounted -Paths $mountDir
    }
    if ($lunqLog) { Write-Info (Get-LunqText 'Main.LogDetails' $lunqLog.Path) }
    if (-not $interactive) { throw }
}
finally {
    # Папку нельзя удалять, пока в ней смонтирован образ: DISM потеряет его, и понадобится dism /Cleanup-Wim.
    $stillMounted = $state.Mounted -or ((Test-Path -LiteralPath $isoDir) -and (Test-LunqAnyMounted -Paths $allMountDirs))
    if ($stillMounted) { Write-Info (Get-LunqText 'Main.WorkDirKept' $WorkDir) }
    elseif ($state.WorkDirOwned -and -not $KeepWorkDir -and (Test-Path -LiteralPath $isoDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Сборка уже встроила драйверы в образ, а следующий запуск выгрузит их заново.
    foreach ($tempDir in @($hostDriversDir, $cabCheckDir)) {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($lunqLog) {
        Stop-LunqLog
        # Архив собирается после остановки лога: пока идёт транскрипт, лог ещё не дописан.
        if ($failed) {
            try {
                $bugReport = New-LunqBugReport -Log $lunqLog -ProfilePath $ProfilePath
                if ($bugReport) { Write-Info (Get-LunqText 'Main.BugReport' $bugReport) }
            }
            catch { Write-LunqWarning $_.Exception.Message }
        }
        # Лог DISM сжимается последним: из полного лога собирается архив для отчёта.
        $dismLog = Compress-LunqDismLog -Path $lunqLog.DismPath
        if ($failed -and $dismLog) { Write-Info (Get-LunqText 'Main.DismLog' $dismLog) }
    }
    $doneIso = $null
    if (-not $failed -and -not $listMode -and $OutputIso -and (Test-Path -LiteralPath $OutputIso)) { $doneIso = $OutputIso }
    $logPath = $null
    if ($lunqLog) { $logPath = $lunqLog.Path }
    Send-LunqEvent 'done' @{
        ok = -not $failed; iso = $doneIso; contents = $contentsPath; log = $logPath; dismLog = $dismLog; bugReport = $bugReport
        warnings = (Get-LunqEventWarnings); seconds = [Math]::Round(((Get-Date) - $runStarted).TotalSeconds, 1)
    }
    Stop-LunqEvents
    # До вопроса «нажмите Enter»: пока окно ждёт, новый запуск уже можно начать.
    Exit-LunqRunLock -Lock $runLock
    if ($interactive) {
        Write-Host ''
        Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    }
}
