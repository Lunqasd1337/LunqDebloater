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
    [switch]$IgnoreSpace,
    [switch]$KeepWorkDir,
    [switch]$Force,
    [ValidateSet('ru', 'en')][string]$Language,
    [string]$Recipe,
    [switch]$DownloadUpdates,
    [ValidateSet('Monthly', 'Off')][string]$Schedule,
    [switch]$Online,
    [switch]$Restore,
    [string[]]$Category,
    [switch]$HostDrivers,
    [switch]$HostApps,
    [switch]$HostWifi
)

$ErrorActionPreference = 'Stop'
# Любой из этих параметров значит запуск без вопросов: из командной строки или по расписанию.
$interactive = -not ($IsoPath -or $Recipe -or $Online -or $Restore -or $Schedule)

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
$pathParams = 'IsoPath', 'OutputIso', 'ConfigPath', 'ProfilePath', 'WorkDir', 'OscdimgPath', 'UpdatesPath', 'DriversPath', 'Recipe'

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

if (-not (Test-Administrator)) {
    if (-not $interactive) { throw (Get-LunqText 'Main.NeedAdminThrow') }
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
        catch { Write-Warning (Get-LunqText 'Main.ElevateDenied') }
    }
    if (-not $elevated) {
        Write-Info (Get-LunqText 'Main.NoAdminExit')
        Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    }
    return
}

# Относительные пути считаются от текущей папки PowerShell. [IO.Path]::GetFullPath
# для этого не годится: он берёт рабочую папку процесса, а она не меняется после cd.
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir).TrimEnd('\')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'Config' }
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath).TrimEnd('\')

# Что нужно знать при ошибке. Mounted: смонтирован ли образ. WorkDirOwned: рабочую папку можно
# удалить в конце, только если этот запуск сам её пересоздал, иначе проверка могла её отвергнуть
# и в ней лежат чужие файлы. Iso: ISO, который шаги держат подключённым между шагами.
# Шаги сборки меняют эту же таблицу через контекст.
$state = @{ Mounted = $false; WorkDirOwned = $false; ImageInfo = $null; Iso = $null }
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
$lunqTempDir = Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater'
$hostDriversDir = Join-Path $lunqTempDir 'HostDrivers'
$cabCheckDir = Join-Path $lunqTempDir 'CabCheck'
# Сети Wi-Fi с паролями открытым текстом, программы этого компьютера и профиль из рецепта:
# всё это нужно только на время сборки.
$hostWifiDir = Join-Path $lunqTempDir 'HostWifi'
$hostAppsDir = Join-Path $lunqTempDir 'HostApps'
$recipeTempDir = Join-Path $lunqTempDir 'Recipe'

# Заголовок окна не меняется в некоторых консолях (например, при перенаправленном выводе), это не ошибка.
try { $Host.UI.RawUI.WindowTitle = "LunqDebloater $(Get-LunqVersion)" } catch { }

$runLock = Enter-LunqRunLock
if (-not $runLock) {
    Write-Host (Get-LunqText 'Main.AlreadyRunning') -ForegroundColor Red
    if (-not $interactive) { throw (Get-LunqText 'Main.AlreadyRunning') }
    Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    return
}

try {
    # Лог ведётся с самого начала: так в него попадают и ошибки при выборе ISO и проверке системы.
    $lunqLog = Start-LunqLog -Dir (Join-Path $PSScriptRoot 'Logs')
    Write-LunqRunInfo -BoundParameters $PSBoundParameters -DismLog $lunqLog.DismPath

    if ($Online -and $Restore) { throw (Get-LunqText 'Main.OnlineAndRestore') }
    if ($Recipe) { $Recipe = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Recipe) }

    # ---------- Расписание: только создать или удалить задание, без сборки ----------
    if ($Schedule) {
        if (-not $Recipe) { throw (Get-LunqText 'Main.ScheduleNeedsRecipe') }
        if ($Schedule -eq 'Off') { Unregister-LunqSchedule -RecipePath $Recipe }
        else {
            $scheduleRecipe = Read-LunqRecipe -Path $Recipe
            # Настройки те же, что при повторе рецепта: из командной строки, иначе из рецепта.
            $scheduleConfig = $ConfigPath
            $recipeConfig = [string](Get-ConfigValue $scheduleRecipe 'ConfigPath')
            if (-not $PSBoundParameters.ContainsKey('ConfigPath') -and $recipeConfig -and (Test-Path -LiteralPath $recipeConfig -PathType Container)) { $scheduleConfig = $recipeConfig }
            $null = Register-LunqSchedule -SourceRoot $PSScriptRoot -ConfigPath $scheduleConfig -RecipePath $Recipe
        }
        return
    }

    # ---------- Рецепт прошлой сборки ----------
    # Параметры, не заданные в командной строке, берутся из рецепта: так сборку можно повторить,
    # например, с новым ISO или без обновлений.
    $recipeData = $null
    $recipeProfile = $null
    $categoryFromRecipe = $false
    if ($Recipe) {
        $recipeData = Read-LunqRecipe -Path $Recipe
        Write-Info (Get-LunqText 'Main.RecipeUsing' $Recipe)
        $recipeValues = Get-LunqRecipeParameters -Recipe $recipeData
        foreach ($name in @($recipeValues.Keys)) {
            if ($PSBoundParameters.ContainsKey($name)) { continue }
            # Редакция по имени и выбранные вручную категории важнее записанных в рецепте.
            if ($name -eq 'Index' -and $PSBoundParameters.ContainsKey('Edition')) { continue }
            if ($name -eq 'Category' -and $PSBoundParameters.ContainsKey('SkipCategory')) { continue }
            if ($name -eq 'Category') { $categoryFromRecipe = $true }
            Set-Variable -Name $name -Value $recipeValues[$name]
        }
        if (-not $PSBoundParameters.ContainsKey('ProfilePath')) {
            $recipeProfile = Get-LunqRecipeProfile -Recipe $recipeData -TempDir $recipeTempDir
            $ProfilePath = $recipeProfile.Path
            if ($recipeProfile.FromRecipe) { Write-Warning (Get-LunqText 'Main.RecipeProfileCopy') }
        }
        if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw (Get-LunqText 'Main.RecipeIsoMissing' $IsoPath) }
        if ((Get-Item -LiteralPath $IsoPath).Length -ne [long]$recipeData.Iso.Size) { Write-Warning (Get-LunqText 'Main.RecipeIsoChanged' $IsoPath) }
    }

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
        Write-Host '    [3] ' -ForegroundColor Cyan -NoNewline; Write-Host (Get-LunqText 'Main.ActionOnline')
        Write-Host '    [4] ' -ForegroundColor Cyan -NoNewline; Write-Host (Get-LunqText 'Main.ActionRestore')
        $actionAnswer = ([string](Read-Host (Get-LunqText 'Main.ActionPrompt'))).Trim()
        $listMode = $actionAnswer -eq '2'
        if ($actionAnswer -eq '3') { $Online = [switch]$true }
        elseif ($actionAnswer -eq '4') { $Restore = [switch]$true }
    }

    # ---------- Откат того, что убрал LunqDebloater ----------
    if ($Restore) {
        $restorePath = Get-LunqRestorePath
        $restoreData = Read-LunqRestoreData -Path $restorePath
        $restoreProfile = $null
        if ($restoreData) {
            # Категории, где всё уже возвращено, в списке не нужны.
            $withItems = @($restoreData.Categories | Where-Object { Test-LunqRestoreCategoryHasItems $_ } | ForEach-Object { $_.Id })
            if ($withItems.Count -gt 0) {
                $restoreProfile = ConvertTo-LunqRestoreProfile -Restore $restoreData
                $restoreProfile.Categories = @($restoreProfile.Categories | Where-Object { $withItems -contains $_.Id })
            }
        }
        if (-not $restoreProfile) {
            Write-Info (Get-LunqText 'Main.RestoreNothing' $restorePath)
            return
        }
        $Category = @($Category | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($Category.Count -gt 0) { Set-LunqOnlyCategories -LunqProfile $restoreProfile -Ids $Category }
        $SkipCategory = @($SkipCategory | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($SkipCategory.Count -gt 0) { Disable-LunqCategories -LunqProfile $restoreProfile -Ids $SkipCategory }
        Write-Section (Get-LunqText 'Main.SectionRestore')
        Write-Info (Get-LunqText 'Main.RestoreFrom' $restorePath)
        if ($interactive) { Select-LunqCategories -LunqProfile $restoreProfile }
        else { Write-CategoryList -LunqProfile $restoreProfile }
        $restoreIds = @($restoreProfile.Categories | Where-Object { $_.Enabled } | ForEach-Object { $_.Id })
        if ($restoreIds.Count -eq 0) {
            Write-Warning (Get-LunqText 'Main.AllCategoriesOff')
            return
        }
        if ($interactive -and -not (Read-YesNo (Get-LunqText 'Main.AskRestore'))) {
            Write-Info (Get-LunqText 'Main.Cancelled')
            return
        }
        $restoreResults = Invoke-LunqRestore -Restore $restoreData -Ids $restoreIds -Path $restorePath
        Write-LunqRestoreReport -Results $restoreResults
        return
    }

    if (-not $Online) {
        if ($interactive) {
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
    }

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
    $Category = @($Category | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # Пустой список из рецепта значит «все категории выключены» (сборка только с обновлениями и
    # драйверами), а не умолчания профиля.
    if ($Category.Count -gt 0 -or $categoryFromRecipe) { Set-LunqOnlyCategories -LunqProfile $lunqProfile -Ids $Category }
    $SkipCategory = @($SkipCategory | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($SkipCategory.Count -gt 0) { Disable-LunqCategories -LunqProfile $lunqProfile -Ids $SkipCategory }
    if ($interactive -and -not $listMode) {
        Write-Section (Get-LunqText 'Main.SectionCategories')
        Select-LunqCategories -LunqProfile $lunqProfile
    }
    if (-not $listMode -and -not ($lunqProfile.Categories | Where-Object { $_.Enabled })) {
        Write-Warning (Get-LunqText 'Main.AllCategoriesOff')
    }
    $config = Get-LunqEffectiveConfig -LunqProfile $lunqProfile
    $skipped = Get-LunqText 'Main.PlanSkipped'

    # ---------- Профиль для этой Windows ----------
    # Те же шаги удаления и реестра, что и в образе, но сразу на этом компьютере. Перед каждым
    # изменением запоминается, как было, и -Restore потом возвращает это по категориям.
    if ($Online) {
        $restorePath = Get-LunqRestorePath
        Write-Section (Get-LunqText 'Main.SectionPlan')
        Write-Info (Get-LunqText 'Main.PlanProfile' $lunqProfile.Name $ProfilePath)
        Write-Info (Get-LunqText 'Main.PlanCategories' @($lunqProfile.Categories | Where-Object { $_.Enabled }).Count $lunqProfile.Categories.Count)
        Write-CategoryList -LunqProfile $lunqProfile
        if ($SkipAppx) { Write-Info (Get-LunqText 'Main.PlanAppx' $skipped) }
        if ($SkipComponents) { Write-Info (Get-LunqText 'Main.PlanComponents' $skipped) }
        elseif ($config.Packages.Remove.Count -gt 0) { Write-Warning (Get-LunqText 'Main.PackagesWarning') }
        if ($SkipRegistry) { Write-Info (Get-LunqText 'Main.PlanRegistry' $skipped) }
        Write-Info (Get-LunqText 'Main.PlanRestore' $restorePath)
        Write-Info (Get-LunqText 'Main.PlanLog' $lunqLog.Path)
        if ($interactive) {
            Write-Info ''
            Write-Host (Get-LunqText 'Main.OnlineDisclaimer') -ForegroundColor Yellow
            if (-not (Read-YesNo (Get-LunqText 'Main.AskApplyOnline'))) {
                Write-Info (Get-LunqText 'Main.Cancelled')
                return
            }
        }
        $onlineContext = @{
            State          = $state
            Config         = $config
            SkipAppx       = [bool]$SkipAppx
            SkipComponents = [bool]$SkipComponents
            SkipRegistry   = [bool]$SkipRegistry
            Restore        = New-LunqRestoreData -LunqProfile $lunqProfile -Source Online
            RestorePath    = $restorePath
        }
        $started = Get-Date
        # Данные для отката записываются после каждого шага, в том числе упавшего.
        $results = Invoke-LunqBuild -Context $onlineContext -Online
        Write-LunqReport -Results $results -LunqProfile $lunqProfile -Elapsed ((Get-Date) - $started) -LogPath $lunqLog.Path -StepTimes $state['StepTimes'] -RestorePath $restorePath
        return
    }

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
        # Драйверы этого компьютера вместо папки: в пошаговом режиме это пункт сводки.
        if ($HostDrivers -and -not $SkipDrivers) {
            $picked = Invoke-LunqContentAction -Action 'hostDrivers' -HostDriversDir $hostDriversDir
            if ($picked) { $driversDir = $picked.Path }
        }
    }
    $appsPath = Join-Path $ConfigPath 'Apps.txt'
    if ($recipeData -and -not $SkipApps -and (Get-ConfigList $recipeData.FirstLogon 'Apps').Count -gt 0) {
        # Список программ из рецепта: в нём уже есть и программы компьютера, где собирался образ.
        $appsPath = Join-Path $recipeTempDir 'Apps.txt'
        New-Item -ItemType Directory -Path $recipeTempDir -Force | Out-Null
        [IO.File]::WriteAllLines($appsPath, [string[]](Get-ConfigList $recipeData.FirstLogon 'Apps'), (New-Object Text.UTF8Encoding($false)))
    }
    $foundLogon = Get-LunqFirstLogon -AppsPath $appsPath -ScriptsPath (Join-Path $ConfigPath 'Scripts')
    $hostRegion = $null
    if (-not $listMode) { $hostRegion = Get-LunqHostRegion }
    # Что пользователь включил и выключил в сводке (Key пункта и Enabled). Когда сводка
    # показывается снова после выбора папки, его выбор сохраняется.
    $choices = @{}
    # Какого вида .cab в корне папки обновлений: распознаётся один раз, а не при каждом показе сводки.
    $cabKinds = @{}
    $peDriverKinds = @{}
    $folderSizes = @{}

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
            download       = [bool]$DownloadUpdates
            drivers        = $foundDrivers.Count -gt 0 -and -not $SkipDrivers
            driversToSetup = [bool]$DriversToSetup
            apps           = $foundLogon.Apps.Count -gt 0 -and -not $SkipApps
            hostApps       = [bool]$HostApps
            scripts        = $foundLogon.Scripts.Count -gt 0 -and -not $SkipScripts
            wifi           = [bool]$HostWifi
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
                -UpdatesDir $updatesDir -DriversDir $driversDir -PEDriverCache $peDriverKinds -SizeCache $folderSizes
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
            $DownloadUpdates = [switch]$use.download
            $HostApps = [switch]$use.hostApps
            $HostWifi = [switch]$use.wifi
            # Скачанные Safe OS и Setup Dynamic Update нужны только вместе с обновлением установщика.
            if ($DownloadUpdates) { $UpdatesToSetup = [switch]$true }
            $CleanupComponents = [switch]$use.cleanup
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
            # Драйверы этого компьютера каждый раз выгружаются в ту же папку: прежний размер не годится.
            $HostDrivers = [switch]($picked.Path -eq $hostDriversDir)
            $folderSizes.Remove($picked.Path)
            $driversDir = $picked.Path
            $DriversPath = $picked.Path
            foreach ($key in 'drivers', 'driversToSetup') { $choices.Remove($key) }
        }
    }
    if ($foundDrivers.Count -gt 0) { $DriversPath = (Resolve-Path -LiteralPath $driversDir).Path }
    $HostDrivers = [switch]($useDrivers -and $foundDrivers.Count -gt 0 -and $driversDir -eq $hostDriversDir)

    # ---------- Копия этого компьютера: программы и сети Wi-Fi ----------
    if (-not $listMode -and $HostApps) {
        Write-Info (Get-LunqText 'Main.HostAppsExporting')
        try {
            $hostAppLines = Export-LunqHostApps -TempDir $hostAppsDir
            $baseApps = $null
            if ($useApps) { $baseApps = $foundLogon.AppsPath }
            $merged = Merge-LunqAppsList -AppsPath $baseApps -Extra $hostAppLines -Destination (Join-Path $hostAppsDir 'Apps.txt')
            Write-Info (Get-LunqText 'Main.HostAppsAdded' $merged.Added)
            $foundLogon = Get-LunqFirstLogon -AppsPath $merged.Path -ScriptsPath $foundLogon.ScriptsPath
            $useApps = $foundLogon.Apps.Count -gt 0
        }
        catch { Write-Warning (Get-LunqText 'Main.HostAppsFailed' $_.Exception.Message) }
    }
    $wifiNames = @()
    if (-not $listMode -and $HostWifi) {
        Write-Info (Get-LunqText 'Main.HostWifiExporting')
        try { $wifiNames = Export-LunqHostWifi -Destination $hostWifiDir }
        catch { Write-Warning (Get-LunqText 'Main.HostWifiFailed' $_.Exception.Message) }
        if ($wifiNames.Count -eq 0) { Write-Warning (Get-LunqText 'Main.HostWifiNone') }
        else { Write-Warning (Get-LunqText 'Main.HostWifiWarning' $wifiNames.Count) }
    }

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
    if ($drivers.Count -gt 0) { $driversSize = Get-FolderSize $DriversPath -Cache $folderSizes }
    if ($drivers.Count -eq 0) { $DriversToSetup = [switch]$false }

    # Установщик и WinRE получают только обновления самой Windows.
    $peUpdates = @()
    if ($UpdatesToSetup) { $peUpdates = Select-LunqPEUpdates $updates }
    $peDrivers = @()
    if ($DriversToSetup) {
        $peDrivers = Select-LunqPEDrivers $drivers -Cache $peDriverKinds
        if ($peDrivers.Count -eq 0) { Write-Warning (Get-LunqText 'Main.NoPEDrivers') }
    }
    $serviceRecovery = ($peUpdates.Count + $safeOSUpdates.Count + $peDrivers.Count) -gt 0
    $servicePE = $serviceRecovery -or $setupDU.Count -gt 0

    $firstLogon = $null
    # Программы из поля Uninstall включённых категорий: их удаляет первый вход.
    $uninstall = Get-ConfigList $config 'Uninstall'
    if (-not $listMode -and ($useApps -or $useScripts -or $wifiNames.Count -gt 0 -or $uninstall.Count -gt 0)) {
        $logonApps = @()
        if ($useApps) { $logonApps = $foundLogon.Apps }
        $logonScripts = @()
        if ($useScripts) { $logonScripts = $foundLogon.Scripts }
        $firstLogon = [pscustomobject]@{
            AppsPath    = $foundLogon.AppsPath
            Apps        = $logonApps
            ScriptsPath = $foundLogon.ScriptsPath
            Scripts     = $logonScripts
            Wifi        = $wifiNames
            WifiPath    = $hostWifiDir
            Uninstall   = $uninstall
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
    if ($servicePE -or ($DownloadUpdates -and $UpdatesToSetup)) { $extraSize = [long](3GB) }
    # Накопительное обновление из каталога весит 3-4 ГБ и ещё столько же занимает в образе при установке.
    if ($DownloadUpdates) { $updatesSize += [long](4GB) }
    $protected = @($IsoPath, $OutputIso, $PSScriptRoot, $ConfigPath, $UpdatesPath, $DriversPath, $ProfilePath) | Where-Object { $_ } |
        ForEach-Object { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) }
    $check = Test-LunqPrerequisites -IsoPath $IsoPath -WorkDir $WorkDir -OutputIso $OutputIso -OscdimgPath $OscdimgPath `
        -UpdatesSize $updatesSize -DriversSize $driversSize -ProtectedPaths $protected -DefaultWorkDir:(-not $PSBoundParameters.ContainsKey('WorkDir')) `
        -ExtraSize $extraSize -SkipOscdimg:$listMode -SkipOutputCheck:$listMode -OwnMountPaths $allMountDirs
    if ($check.Errors -gt 0) { throw (Get-LunqText 'Main.FixErrors') }
    # Без вопросов (рецепт, расписание) никто не ответит на предупреждение, а многочасовая сборка на
    # почти полном диске упадёт посередине. Поэтому нехватка места там останавливает запуск.
    if ($check.SpaceLow -and -not $interactive -and -not $listMode -and -not $IgnoreSpace) { throw (Get-LunqText 'Main.SpaceLowStop') }
    if ($check.Warnings -gt 0 -and $interactive -and -not (Read-YesNo (Get-LunqText 'Main.AskContinueWarnings'))) { return }
    $contentsDir = $null
    if ($listMode) { $contentsDir = Get-LunqContentsDir -IsoPath $IsoPath -FallbackDir (Split-Path $lunqLog.Path -Parent) }

    if (-not $listMode -and (Test-Path -LiteralPath $OutputIso)) {
        if ($interactive -and -not $Force) {
            Write-Warning (Get-LunqText 'Main.OutputExists' $OutputIso)
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
        $selected = Select-LunqEdition -Images $images -Index $Index -Edition $Edition
        $editionName = ($images | Where-Object ImageIndex -eq $selected).ImageName
        $imageInfo = Get-IsoImageInfo -IsoRoot $iso.Root -Index $selected
        $sourceIsWim = (Get-InstallImagePath -IsoRoot $iso.Root) -like '*.wim'
        # Чужой autounattend.xml в ISO иначе обнаружился бы только на шаге файла ответов,
        # после обновлений и драйверов.
        if ($setupAnswers -and (Test-Path -LiteralPath (Join-Path $iso.Root 'autounattend.xml'))) { throw (Get-LunqText 'Unattend.Exists') }
    }
    finally { Dismount-IsoImage -Iso $iso }

    # ---------- Свежие обновления из каталога Microsoft ----------
    # Выпуск и архитектура известны только теперь, после чтения редакции. Скачанное хранится
    # в Config\Updates\Catalog и не скачивается снова, пока в каталоге не выйдет новое.
    $downloaded = @()
    if (-not $listMode -and $DownloadUpdates) {
        Write-Section (Get-LunqText 'Main.SectionDownload')
        $catalogRelease = Get-LunqCatalogRelease -Build $imageInfo.Build
        if (-not $catalogRelease) { throw (Get-LunqText 'Main.DownloadUnknownBuild' $imageInfo.Build) }
        $catalogDir = Join-Path $ConfigPath ('Updates\Catalog\{0}-{1}' -f $catalogRelease, $imageInfo.Architecture)
        $downloaded = (Save-LunqCatalogUpdates -Release $catalogRelease -Architecture $imageInfo.Architecture -Destination $catalogDir -WithDynamic:$UpdatesToSetup)
        # Get-LunqUpdateFiles отдаёт список одним объектом, поэтому он сначала кладётся в переменную.
        $catalogUpdates = Get-LunqUpdateFiles -Path $catalogDir
        $updates = Get-LunqSortedUpdates (@($updates) + $catalogUpdates)
        if ($UpdatesToSetup) {
            $catalogSafeOS = Get-LunqUpdateFiles -Path (Join-Path $catalogDir 'SafeOS')
            $safeOSUpdates = @($safeOSUpdates) + $catalogSafeOS
            $catalogSetup = Get-LunqUpdateFiles -Path (Join-Path $catalogDir 'Setup')
            $setupDU = @($setupDU) + @($catalogSetup | Where-Object { $_.Extension -eq '.cab' })
            $peUpdates = Select-LunqPEUpdates $updates
        }
        $updatesSize = Get-LunqFilesSize (@($updates) + $safeOSUpdates + $setupDU)
        $serviceRecovery = ($peUpdates.Count + $safeOSUpdates.Count + $peDrivers.Count) -gt 0
        $servicePE = $serviceRecovery -or $setupDU.Count -gt 0
        Write-Check Ok (Get-LunqText 'Main.Downloaded' $downloaded.Count (Format-Size $updatesSize))
    }

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
                Write-Warning (Get-LunqText 'Main.SkipVersionCheckWarn')
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
        $contentsPath = Join-Path $contentsDir ('{0}_{1}_contents.txt' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $selected)
        $inventoryContext = @{
            State        = $state
            WorkDir      = $WorkDir
            MountPaths   = $allMountDirs
            MountDir     = $mountDir
            WimPath      = $wimPath
            IsoPath      = $IsoPath
            Index        = $selected
            DirectMount  = $sourceIsWim
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

    # Контрольные суммы считаются один раз: и для сверки с рецептом, и для нового рецепта.
    $hashCache = @{}
    if ($recipeData -and -not $DownloadUpdates) {
        # Без скачивания сборка по рецепту должна получить те же обновления, что и в прошлый раз.
        $actualFiles = @(Get-LunqRecipeFiles (@($updates) + $safeOSUpdates + $setupDU) 'Update' $hashCache)
        foreach ($line in (Compare-LunqRecipeFiles -Expected (Get-ConfigList $recipeData.Updates 'Files') -Actual $actualFiles)) { Write-Warning $line }
    }

    # ---------- План и подтверждение ----------

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
    elseif ($config.Packages.Remove.Count -gt 0) { Write-Warning (Get-LunqText 'Main.PackagesWarning') }
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
        # Что удалено и как было в реестре: в образ, чтобы на установленной Windows работал -Restore.
        Restore           = New-LunqRestoreData -LunqProfile $lunqProfile -Source Image
    }
    $started = Get-Date
    $results = Invoke-LunqBuild -Context $build
    $elapsed = (Get-Date) - $started

    Write-LunqReport -Results $results -LunqProfile $lunqProfile -OutputIso $OutputIso -Elapsed $elapsed -LogPath $lunqLog.Path -StepTimes $state['StepTimes'] -HasFirstLogon:([bool]$firstLogon) -HasUnattend:([bool]$setupAnswers)

    # ---------- Рецепт и отчёт рядом с ISO ----------
    # Не шаг сборки: ISO уже готов, и сбой здесь его не портит.
    $recipePath = Get-LunqRecipePath -OutputIso $OutputIso
    $htmlPath = Get-LunqRecipePath -OutputIso $OutputIso -Extension '.lunq.html'
    try {
        Write-Info (Get-LunqText 'Main.RecipeWriting')
        $recipeApps = @()
        if ($firstLogon -and $firstLogon.Apps.Count -gt 0) {
            $recipeApps = @(Get-Content -LiteralPath $firstLogon.AppsPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        }
        $profileOriginal = $null
        if ($recipeProfile -and $recipeProfile.FromRecipe) { $profileOriginal = [string]$recipeData.Profile.Path }
        $newRecipe = New-LunqRecipe -HashCache $hashCache -Values @{
            ProfilePath = $ProfilePath; ProfileOriginalPath = $profileOriginal; Profile = $lunqProfile
            IsoPath = $IsoPath; Index = $selected; EditionName = $editionName; BuildText = $buildText
            OutputIso = $OutputIso; Label = $Label; ConfigPath = $ConfigPath
            SkipAppx = $SkipAppx; SkipComponents = $SkipComponents; SkipRegistry = $SkipRegistry; CleanupComponents = $CleanupComponents
            DownloadUpdates = $DownloadUpdates; UpdatesPath = $UpdatesPath; UpdatesToSetup = $UpdatesToSetup
            Updates = $updates; SafeOS = $safeOSUpdates; SetupDU = $setupDU
            DriversPath = $DriversPath; HostDrivers = $HostDrivers; DriversToSetup = $DriversToSetup; Drivers = $drivers
            Apps = $recipeApps; HostApps = $HostApps; Scripts = $(if ($firstLogon) { $firstLogon.Scripts } else { @() }); HostWifi = ($wifiNames.Count -gt 0)
            SetupAnswers = [bool]$setupAnswers; BypassRequirements = $useBypass -and [bool]$setupAnswers; LocalAccount = $useLocalAccount -and [bool]$setupAnswers
        }
        Save-LunqRecipe -Recipe $newRecipe -Path $recipePath
        Write-LunqHtmlReport -Path $htmlPath -Results $results -LunqProfile $lunqProfile -StepTimes $state['StepTimes'] -Info @{
            IsoPath = $IsoPath; IsoSize = [long]$newRecipe.Iso.Size; OutputIso = $OutputIso; OutputSize = [long](Get-Item -LiteralPath $OutputIso).Length
            ProfilePath = $ProfilePath; Elapsed = $elapsed; RecipePath = $recipePath; EditionName = $editionName; BuildText = $buildText
        }
        Write-Info (Get-LunqText 'Main.RecipeSaved' $recipePath)
        Write-Info (Get-LunqText 'Main.HtmlSaved' $htmlPath)
    }
    catch { Write-Warning (Get-LunqText 'Main.RecipeFailed' $_.Exception.Message) }

    # Со свежими обновлениями из каталога ту же сборку есть смысл повторять каждый месяц.
    if ($interactive -and $DownloadUpdates -and (Test-Path -LiteralPath $recipePath)) {
        Write-Info ''
        Write-Info (Get-LunqText 'Main.ScheduleOffer')
        if (Read-YesNo (Get-LunqText 'Main.AskSchedule')) {
            try { $null = Register-LunqSchedule -SourceRoot $PSScriptRoot -ConfigPath $ConfigPath -RecipePath $recipePath }
            catch { Write-Warning $_.Exception.Message }
        }
    }
}
catch {
    $failed = $true
    Write-Host ''
    Write-Host (Get-LunqText 'Main.Error' $_.Exception.Message) -ForegroundColor Red
    # Где именно случилась ошибка: по присланному логу сразу видно, какую функцию смотреть.
    if ($_.ScriptStackTrace) {
        Write-Host ('    ' + (Get-LunqText 'Main.ErrorWhere')) -ForegroundColor DarkGray
        foreach ($line in ($_.ScriptStackTrace -split '\r?\n')) { Write-Host "      $line" -ForegroundColor DarkGray }
    }
    if ($lunqLog) { Write-Info (Get-LunqText 'Main.LogDetails' $lunqLog.Path) }
    if (-not $interactive) { throw }
}
finally {
    # Образы, оставшиеся смонтированными после ошибки или Ctrl+C, отбрасываются здесь, а не в catch:
    # при Ctrl+C catch не выполняется. Проверяются все папки сборки, а не только основная: WinRE и
    # boot.wim тоже могли остаться смонтированными. После удачной сборки смонтированного нет.
    $leftMounted = @()
    if ($state.Mounted -or (Test-Path -LiteralPath $isoDir)) {
        $leftMounted = Get-LunqMountedPaths -Paths $allMountDirs
        if ($null -eq $leftMounted) { $leftMounted = @() }
        # Основной образ, который этот запуск смонтировал, отбрасывается и тогда, когда DISM не ответил.
        if ($state.Mounted -and $leftMounted -notcontains $mountDir) { $leftMounted = @($mountDir) + $leftMounted }
    }
    # С подключённым кустом DISM не отключит образ.
    if ($failed -or $leftMounted.Count -gt 0) { Dismount-OfflineHives }
    if ($leftMounted.Count -gt 0) {
        Write-Info (Get-LunqText 'Main.DiscardImage')
        foreach ($path in $leftMounted) {
            try { Dismount-WindowsImage -Path $path -Discard -ErrorAction Stop | Out-Null }
            catch { Write-Warning $_.Exception.Message }
        }
        $state.Mounted = Test-LunqAnyMounted -Paths $allMountDirs
    }
    # Папку нельзя удалять, пока в ней смонтирован образ: DISM потеряет его, и понадобится dism /Cleanup-Wim.
    $stillMounted = $state.Mounted -or ((Test-Path -LiteralPath $isoDir) -and (Test-LunqAnyMounted -Paths $allMountDirs))
    # ISO, оставшийся подключённым после ошибки или Ctrl+C между шагами. Пока смонтирован образ,
    # который может быть взят прямо с ISO («Что в образе»), ISO не отключается.
    if (-not $stillMounted) {
        try { Dismount-LunqStateIso -State $state }
        catch { Write-Warning $_.Exception.Message }
    }
    if ($stillMounted) { Write-Info (Get-LunqText 'Main.WorkDirKept' $WorkDir) }
    elseif ($state.WorkDirOwned -and -not $KeepWorkDir -and (Test-Path -LiteralPath $isoDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Сборка уже встроила драйверы в образ, а следующий запуск выгрузит их заново.
    foreach ($tempDir in @($hostDriversDir, $cabCheckDir, $hostWifiDir, $hostAppsDir, $recipeTempDir)) {
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
            catch { Write-Warning $_.Exception.Message }
        }
        # Лог DISM сжимается последним: из полного лога собирается архив для отчёта.
        $dismLog = Compress-LunqDismLog -Path $lunqLog.DismPath
        if ($failed -and $dismLog) { Write-Info (Get-LunqText 'Main.DismLog' $dismLog) }
    }
    # До вопроса «нажмите Enter»: пока окно ждёт, новый запуск уже можно начать.
    Exit-LunqRunLock -Lock $runLock
    if ($interactive) {
        Write-Host ''
        Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    }
}
