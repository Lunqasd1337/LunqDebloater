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
    [string]$Label = 'LUNQ_WIN11',
    [switch]$SkipAppx,
    [switch]$SkipComponents,
    [switch]$SkipRegistry,
    [switch]$CleanupComponents,
    [switch]$SkipVersionCheck,
    [switch]$KeepWorkDir,
    [switch]$Force,
    [ValidateSet('ru', 'en')][string]$Language
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
$pathParams = 'IsoPath', 'OutputIso', 'ConfigPath', 'ProfilePath', 'WorkDir', 'OscdimgPath', 'UpdatesPath', 'DriversPath'

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
            if (-not (Test-Path -LiteralPath $UpdatesPath -PathType Container)) { throw (Get-LunqText 'Main.UpdatesDirNotFound' $UpdatesPath) }
            $updatesDir = (Resolve-Path -LiteralPath $UpdatesPath).Path
        }
        $foundUpdates = Get-LunqUpdateFiles -Path $updatesDir
        if ($UpdatesPath -and $foundUpdates.Count -eq 0) { throw (Get-LunqText 'Main.UpdatesDirEmpty' $UpdatesPath) }

        if ($DriversPath) {
            if (-not (Test-Path -LiteralPath $DriversPath -PathType Container)) { throw (Get-LunqText 'Main.DriversDirNotFound' $DriversPath) }
            $driversDir = (Resolve-Path -LiteralPath $DriversPath).Path
        }
        $foundDrivers = Get-LunqDriverFiles -Path $driversDir
        if ($DriversPath -and $foundDrivers.Count -eq 0) {
            throw (Get-LunqText 'Main.DriversDirEmpty' $DriversPath)
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
        Write-Section (Get-LunqText 'Main.SectionContents')
        Write-Info (Get-LunqText 'Main.ContentsIntro' $ConfigPath)
        Write-Info (Get-LunqText 'Main.ContentsHowTo')
        $hasUpdates = $foundUpdates.Count -gt 0
        $hasDrivers = $foundDrivers.Count -gt 0
        $hasApps = $foundLogon.Apps.Count -gt 0
        $hasScripts = $foundLogon.Scripts.Count -gt 0

        if ($hasUpdates) {
            $sum = [long]0
            foreach ($u in $foundUpdates) { $sum += $u.Length }
            $updatesName = Get-LunqText 'Main.UpdatesFound' $foundUpdates.Count (Format-Size $sum)
            $updatesDetails = @($foundUpdates | ForEach-Object { $_.Name }) + (Get-LunqText 'Main.UpdatesFoundHint')
        }
        else {
            $updatesName = Get-LunqText 'Main.UpdatesNone'
            $updatesDetails = Get-LunqText 'Main.UpdatesNoneHint'
        }
        if ($hasDrivers) {
            $driversName = Get-LunqText 'Main.DriversFound' $foundDrivers.Count (Format-Size (Get-FolderSize $driversDir))
            $driversDetails = Get-LunqText 'Main.DriversFoundHint'
        }
        else {
            $driversName = Get-LunqText 'Main.DriversNone'
            $driversDetails = Get-LunqText 'Main.DriversNoneHint'
        }
        if ($hasApps) {
            $appsName = Get-LunqText 'Main.AppsFound' $foundLogon.Apps.Count
            $appsDetails = $foundLogon.Apps -join ', '
        }
        else {
            $appsName = Get-LunqText 'Main.AppsNone'
            $appsDetails = Get-LunqText 'Main.AppsNoneHint'
        }
        if ($hasScripts) {
            $scriptsName = Get-LunqText 'Main.ScriptsFound' $foundLogon.Scripts.Count
            $scriptsDetails = ($foundLogon.Scripts | ForEach-Object { $_.Name }) -join ', '
        }
        else {
            $scriptsName = Get-LunqText 'Main.ScriptsNone'
            $scriptsDetails = Get-LunqText 'Main.ScriptsNoneHint'
        }
        $regionDetails = Get-LunqText 'Main.RegionDetails' $hostRegion.Locale ($hostRegion.Keyboards -join ', ') $hostRegion.TimeZone
        $peDriversCount = (Select-LunqPEDrivers $foundDrivers).Count

        $options = @(
            (New-LunqOption -Key 'updates' -Enabled $useUpdates -Available $hasUpdates -Name $updatesName -Details $updatesDetails),
            (New-LunqOption -Key 'cleanup' -Parent 'updates' -Enabled ([bool]$CleanupComponents) -Available $hasUpdates `
                -Name (Get-LunqText 'Main.OptCleanup') `
                -Details (Get-LunqText 'Main.OptCleanupHint')),
            (New-LunqOption -Key 'updatesToSetup' -Parent 'updates' -Enabled ([bool]$UpdatesToSetup) -Available $hasUpdates `
                -Name (Get-LunqText 'Main.OptUpdatesToSetup') `
                -Details (Get-LunqText 'Main.OptUpdatesToSetupHint')),
            (New-LunqOption -Key 'drivers' -Enabled $useDrivers -Available $hasDrivers -Name $driversName -Details $driversDetails),
            (New-LunqOption -Key 'driversToSetup' -Parent 'drivers' -Enabled ([bool]$DriversToSetup) -Available $hasDrivers `
                -Name (Get-LunqText 'Main.OptDriversToSetup' $peDriversCount) `
                -Details (Get-LunqText 'Main.OptDriversToSetupHint')),
            (New-LunqOption -Key 'apps' -Enabled $useApps -Available $hasApps -Name $appsName -Details $appsDetails),
            (New-LunqOption -Key 'scripts' -Enabled $useScripts -Available $hasScripts -Name $scriptsName -Details $scriptsDetails),
            (New-LunqOption -Key 'unattend' -Enabled $useUnattend -Name (Get-LunqText 'Main.OptUnattend') `
                -Details (Get-LunqText 'Main.OptUnattendHint')),
            (New-LunqOption -Key 'oobe' -Parent 'unattend' -Enabled $useOobe -Name (Get-LunqText 'Main.OptOobe') `
                -Details (Get-LunqText 'Main.OptOobeHint')),
            (New-LunqOption -Key 'region' -Parent 'unattend' -Enabled $useRegion -Name (Get-LunqText 'Main.OptRegion') `
                -Details $regionDetails),
            (New-LunqOption -Key 'bypass' -Parent 'unattend' -Enabled $useBypass -Name (Get-LunqText 'Main.OptBypass') `
                -Details (Get-LunqText 'Main.OptBypassHint')),
            (New-LunqOption -Key 'localAccount' -Parent 'unattend' -Enabled $useLocalAccount -Name (Get-LunqText 'Main.OptLocalAccount') `
                -Details (Get-LunqText 'Main.OptLocalAccountHint'))
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
        if ($peDrivers.Count -eq 0) { Write-Warning (Get-LunqText 'Main.NoPEDrivers') }
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
        $contentsPath = Join-Path (Split-Path $IsoPath -Parent) ('{0}_{1}_contents.txt' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $selected)
        Initialize-LunqSteps -Total 4
        Write-Step (Get-LunqText 'Main.StepPrepare') (Get-LunqText 'Main.StepPrepareHint' $WorkDir)
        Reset-LunqWorkDir -WorkDir $WorkDir -MountPaths $allMountDirs
        New-Item -ItemType Directory -Path $mountDir, (Split-Path $wimPath -Parent) -Force | Out-Null

        Write-Step (Get-LunqText 'Main.StepCopyEdition') (Get-LunqText 'Main.StepCopyEditionHint')
        $iso = Mount-IsoImage -IsoPath $IsoPath
        try {
            Export-WindowsImage -SourceImagePath (Get-InstallImagePath -IsoRoot $iso.Root) -SourceIndex $selected `
                -DestinationImagePath $wimPath -CompressionType Fast | Out-Null
        }
        finally { Dismount-IsoImage -Iso $iso }

        Write-Step (Get-LunqText 'Main.StepOpenImage') (Get-LunqText 'Main.StepOpenImageHint')
        Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir -ReadOnly | Out-Null
        $mounted = $true

        Write-Step (Get-LunqText 'Main.StepReadInventory') (Get-LunqText 'Main.StepReadInventoryHint')
        $inventory = Write-LunqInventory -MountPath $mountDir -LunqProfile $lunqProfile -Path $contentsPath -Header @(
            (Get-LunqText 'Main.InventoryHeader' $selected $editionName $buildText),
            "ISO: $IsoPath",
            (Get-LunqText 'Main.InventoryCreated' (Get-LunqVersion) (Get-Date -Format 'yyyy-MM-dd HH:mm')),
            '')
        Dismount-WindowsImage -Path $mountDir -Discard | Out-Null
        $mounted = $false

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
        if ($peDrivers.Count -gt 0) { $what += Get-LunqText 'Main.PlanPEDrivers' $peDrivers.Count }
        Write-Info (Get-LunqText 'Main.PlanPE' ($what -join (Get-LunqText 'Main.PlanPEJoin')))
        if ($UpdatesToSetup -and $peUpdates.Count -lt $updates.Count) { Write-Info (Get-LunqText 'Main.PlanPESkipped') }
    }
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
    # Шаги описаны списком. When решает, выполняется ли шаг, и по нему же считается «Шаг N из M».
    # Run выполняется через точку, в области видимости скрипта: так шаги дописывают $results
    # и меняют $mounted (через $script:, чтобы это было видно и анализатору).
    $results = @()
    $buildSteps = @(
        @{
            Title = Get-LunqText 'Main.StepPrepare'; When = $true
            Hint  = Get-LunqText 'Main.StepPrepareHint' $WorkDir
            Run   = {
                Reset-LunqWorkDir -WorkDir $WorkDir -MountPaths $allMountDirs
                New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
            }
        },
        @{
            Title = Get-LunqText 'Main.StepCopyIso'; When = $true
            Hint  = Get-LunqText 'Main.StepCopyIsoHint'
            Run   = { Copy-IsoContent -IsoPath $IsoPath -Destination $isoDir }
        },
        @{
            Title = Get-LunqText 'Main.StepExport'; When = $true
            Hint  = Get-LunqText 'Main.StepExportHint'
            Run   = {
                Export-SingleEdition -SourceImage (Get-InstallImagePath -IsoRoot $isoDir) -SourceIndex $selected -DestinationImage $wimPath
                $info = Get-WindowsImage -ImagePath $wimPath -Index 1
                Write-Info (Get-LunqText 'Main.ExportedInfo' $info.ImageName $info.Version)
            }
        },
        @{
            Title = Get-LunqText 'Main.StepMount'; When = $true
            Hint  = Get-LunqText 'Main.StepMountHint'
            Run   = {
                Mount-WindowsImage -ImagePath $wimPath -Index 1 -Path $mountDir | Out-Null
                $script:mounted = $true
            }
        },
        @{
            Title = Get-LunqText 'Main.StepUpdates'; When = $updates.Count -gt 0
            Hint  = Get-LunqText 'Main.StepUpdatesHint'
            Run   = { $results += Add-LunqUpdates -MountPath $mountDir -Files $updates -ScratchDir (Join-Path $WorkDir 'scratch') }
        },
        @{
            Title = Get-LunqText 'Main.StepDrivers'; When = $drivers.Count -gt 0
            Hint  = Get-LunqText 'Main.StepDriversHint'
            Run   = { $results += Add-LunqDrivers -MountPath $mountDir -InfFiles $drivers -Root $DriversPath }
        },
        @{
            Title = Get-LunqText 'Main.StepRecovery'; When = $servicePE
            Hint  = Get-LunqText 'Main.StepRecoveryHint'
            Run   = { $results += Update-LunqRecovery -MountPath $mountDir -WorkDir $WorkDir -PEMountPath $reMountDir -Updates $peUpdates -Drivers $peDrivers -DriversRoot $DriversPath }
        },
        @{
            Title = Get-LunqText 'Main.StepFirstLogon'; When = [bool]$firstLogon
            Hint  = Get-LunqText 'Main.StepFirstLogonHint'
            Run   = { $results += Install-LunqFirstLogon -MountPath $mountDir -FirstLogon $firstLogon -Architecture $imageInfo.Architecture }
        },
        @{
            Title = Get-LunqText 'Main.StepUnattend'; When = [bool]$setupAnswers
            Hint  = Get-LunqText 'Main.StepUnattendHint'
            Run   = {
                $results += Install-LunqUnattend -IsoRoot $isoDir -Unattend $setupAnswers -Architecture $imageInfo.Architecture `
                    -ImageLanguage (Get-LunqImageLanguage -Image $info) -WithFirstLogon:([bool]$firstLogon)
            }
        },
        @{
            Title = Get-LunqText 'Main.StepAppx'; When = -not $SkipAppx
            Hint  = Get-LunqText 'Main.StepAppxHint'
            Run   = { $results += Remove-LunqAppx -MountPath $mountDir -Config $config }
        },
        @{
            Title = Get-LunqText 'Main.StepCapabilities'; When = -not $SkipComponents
            Hint  = Get-LunqText 'Main.StepCapabilitiesHint'
            Run   = { $results += Remove-LunqCapabilities -MountPath $mountDir -Config $config }
        },
        @{
            Title = Get-LunqText 'Main.StepFeatures'; When = -not $SkipComponents
            Hint  = Get-LunqText 'Main.StepFeaturesHint'
            Run   = {
                $results += Disable-LunqFeatures -MountPath $mountDir -Config $config
                $packages = Remove-LunqPackages -MountPath $mountDir -Config $config
                if ($packages) { $results += $packages }
            }
        },
        @{
            Title = Get-LunqText 'Main.StepRegistry'; When = -not $SkipRegistry
            Hint  = Get-LunqText 'Main.StepRegistryHint'
            Run   = { $results += Set-LunqRegistry -MountPath $mountDir -Config $config }
        },
        @{
            Title = Get-LunqText 'Main.StepCleanup'; When = [bool]$CleanupComponents
            Hint  = Get-LunqText 'Main.StepCleanupHint'
            Run   = {
                $cleanup = New-LunqResult (Get-LunqText 'Main.CleanupResult') 'Cleanup'
                if (Invoke-LunqComponentCleanup -MountPath $mountDir -ScratchDir (Join-Path $WorkDir 'scratch')) {
                    $cleanup.Summary = Get-LunqText 'Main.CleanupDone'
                }
                else {
                    $cleanup.Summary = Get-LunqText 'Main.CleanupFailed'
                    $cleanup.Failed.Add('StartComponentCleanup')
                }
                $results += $cleanup
            }
        },
        @{
            Title = Get-LunqText 'Main.StepSave'; When = $true
            Hint  = Get-LunqText 'Main.StepSaveHint'
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
                        SetupAndWinRE     = $(if ($servicePE) { Get-LunqText 'Main.StampYes' } else { Get-LunqText 'Main.StampNo' })
                        SetupAnswerFile   = $(if ($setupAnswers) { Format-LunqUnattendSummary -Unattend $setupAnswers } else { Get-LunqText 'Main.StampNo' })
                        CleanupComponents = $(if ($CleanupComponents) { Get-LunqText 'Main.StampYes' } else { Get-LunqText 'Main.StampNo' })
                        Apps              = $(if ($firstLogon) { $firstLogon.Apps -join ', ' } else { '' })
                        Scripts           = $(if ($firstLogon) { @($firstLogon.Scripts | ForEach-Object { $_.Name }) -join ', ' } else { '' })
                    })
                Dismount-WindowsImage -Path $mountDir -Save | Out-Null
                $script:mounted = $false
            }
        },
        @{
            Title = Get-LunqText 'Main.StepSetup'; When = $servicePE
            Hint  = Get-LunqText 'Main.StepSetupHint'
            Run   = { $results += Update-LunqSetup -IsoRoot $isoDir -WorkDir $WorkDir -PEMountPath $bootMountDir -Updates $peUpdates -Drivers $peDrivers -DriversRoot $DriversPath }
        },
        @{
            Title = Get-LunqText 'Main.StepRecompress'; When = $true
            Hint  = Get-LunqText 'Main.StepRecompressHint'
            Run   = { Export-SingleEdition -SourceImage $wimPath -SourceIndex 1 -DestinationImage $wimPath }
        },
        @{
            Title = Get-LunqText 'Main.StepIso'; When = $true
            Hint  = Get-LunqText 'Main.StepIsoHint'
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
    Write-Host (Get-LunqText 'Main.Error' $_.Exception.Message) -ForegroundColor Red
    Dismount-OfflineHives
    if ($mounted) {
        Write-Info (Get-LunqText 'Main.DiscardImage')
        Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
        $mounted = (Get-LunqMountedPaths -Paths $mountDir).Count -gt 0
    }
    if ($lunqLog) {
        Write-Info (Get-LunqText 'Main.LogDetails' $lunqLog.Path)
        if (Test-Path -LiteralPath $lunqLog.DismPath) { Write-Info (Get-LunqText 'Main.DismLog' $lunqLog.DismPath) }
    }
    if (-not $interactive) { throw }
}
finally {
    # Папку нельзя удалять, пока в ней смонтирован образ: DISM потеряет его, и понадобится dism /Cleanup-Wim.
    $stillMounted = $mounted -or ((Test-Path -LiteralPath $isoDir) -and (Get-LunqMountedPaths -Paths $allMountDirs).Count -gt 0)
    if ($stillMounted) { Write-Info (Get-LunqText 'Main.WorkDirKept' $WorkDir) }
    elseif (-not $KeepWorkDir -and (Test-Path -LiteralPath $isoDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lunqLog) { Stop-LunqLog }
    if ($interactive) {
        Write-Host ''
        Read-Host (Get-LunqText 'Main.PressEnter') | Out-Null
    }
}
