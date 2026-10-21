# Режимы LunqDebloater.ps1: рецепт, откат, -Online, сводка «Что войдёт в образ»,
# «Что в образе», план сборки и то, что пишется рядом с ISO. В скрипте остаются параметры,
# перезапуск, права, блокировка, лог и уборка в finally: они должны работать и после Ctrl+C.

function Split-LunqIdList {
    # При запуске через -File список приходит одной строкой, поэтому делим по запятым сами.
    param($Ids)
    return , @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-LunqRecipeParameters {
    # Параметры, не заданные в командной строке, берутся из рецепта: так сборку можно повторить,
    # например, с новым ISO или без обновлений. Возвращает Values (параметр и значение, скрипт
    # присваивает их сам) и CategoryFromRecipe: список категорий взят из рецепта.
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][Collections.IDictionary]$BoundParameters)
    $values = [ordered]@{}
    $categoryFromRecipe = $false
    $recipeValues = Get-LunqRecipeParameters -Recipe $Recipe
    foreach ($name in @($recipeValues.Keys)) {
        if ($BoundParameters.ContainsKey($name)) { continue }
        # Редакция по имени и выбранные вручную категории важнее записанных в рецепте.
        if ($name -eq 'Index' -and $BoundParameters.ContainsKey('Edition')) { continue }
        if ($name -eq 'Category' -and $BoundParameters.ContainsKey('SkipCategory')) { continue }
        # -OutputIso и -OutputName взаимоисключающие: заданное в командной строке заменяет оба из рецепта.
        if (@('OutputIso', 'OutputName') -contains $name -and ($BoundParameters.ContainsKey('OutputIso') -or $BoundParameters.ContainsKey('OutputName'))) { continue }
        if ($name -eq 'Category') { $categoryFromRecipe = $true }
        $values[$name] = $recipeValues[$name]
    }
    return [pscustomobject]@{ Values = $values; CategoryFromRecipe = $categoryFromRecipe }
}

function Invoke-LunqRestoreMode {
    # -Restore: откат того, что убрал LunqDebloater, по категориям из Restore.json.
    param([string[]]$Category, [string[]]$SkipCategory, [switch]$Interactive)
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
    $Category = Split-LunqIdList $Category
    if ($Category.Count -gt 0) { Set-LunqOnlyCategories -LunqProfile $restoreProfile -Ids $Category }
    $SkipCategory = Split-LunqIdList $SkipCategory
    if ($SkipCategory.Count -gt 0) { Disable-LunqCategories -LunqProfile $restoreProfile -Ids $SkipCategory }
    Write-Section (Get-LunqText 'Main.SectionRestore')
    Write-Info (Get-LunqText 'Main.RestoreFrom' $restorePath)
    $otherUser = Get-LunqOtherConsoleUser
    if ($otherUser) { Write-Warning (Get-LunqText 'Main.OtherUser' (Get-LunqProcessUser) $otherUser) }
    if ($Interactive) { Select-LunqCategories -LunqProfile $restoreProfile }
    else { Write-CategoryList -LunqProfile $restoreProfile }
    $restoreIds = @($restoreProfile.Categories | Where-Object { $_.Enabled } | ForEach-Object { $_.Id })
    if ($restoreIds.Count -eq 0) {
        Write-Warning (Get-LunqText 'Main.AllCategoriesOff')
        return
    }
    if ($Interactive -and -not (Read-YesNo (Get-LunqText 'Main.AskRestore'))) {
        Write-Info (Get-LunqText 'Main.Cancelled')
        return
    }
    $restoreResults = Invoke-LunqRestore -Restore $restoreData -Ids $restoreIds -Path $restorePath
    Write-LunqRestoreReport -Results $restoreResults
}

function Invoke-LunqOnlineMode {
    # -Online: те же шаги удаления и реестра, что и в образе, но сразу на этом компьютере. Перед
    # каждым изменением запоминается, как было, и -Restore потом возвращает это по категориям.
    param(
        [Parameter(Mandatory)]$LunqProfile,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$SkipAppx,
        [switch]$SkipComponents,
        [switch]$SkipRegistry,
        [switch]$Interactive
    )
    $restorePath = Get-LunqRestorePath
    $skipped = Get-LunqText 'Main.PlanSkipped'
    Write-Section (Get-LunqText 'Main.SectionPlan')
    Write-Info (Get-LunqText 'Main.PlanProfile' $LunqProfile.Name $ProfilePath)
    Write-Info (Get-LunqText 'Main.PlanCategories' @($LunqProfile.Categories | Where-Object { $_.Enabled }).Count $LunqProfile.Categories.Count)
    Write-CategoryList -LunqProfile $LunqProfile
    if ($SkipAppx) { Write-Info (Get-LunqText 'Main.PlanAppx' $skipped) }
    if ($SkipComponents) { Write-Info (Get-LunqText 'Main.PlanComponents' $skipped) }
    elseif ($Config.Packages.Remove.Count -gt 0) { Write-Warning (Get-LunqText 'Main.PackagesWarning') }
    if ($SkipRegistry) { Write-Info (Get-LunqText 'Main.PlanRegistry' $skipped) }
    Write-Info (Get-LunqText 'Main.PlanRestore' $restorePath)
    Write-Info (Get-LunqText 'Main.PlanLog' $LogPath)
    $otherUser = Get-LunqOtherConsoleUser
    if ($otherUser) { Write-Warning (Get-LunqText 'Main.OtherUser' (Get-LunqProcessUser) $otherUser) }
    if ($Interactive) {
        Write-Info ''
        Write-Host (Get-LunqText 'Main.OnlineDisclaimer') -ForegroundColor Yellow
        if (-not (Read-YesNo (Get-LunqText 'Main.AskApplyOnline'))) {
            Write-Info (Get-LunqText 'Main.Cancelled')
            return
        }
    }
    $context = @{
        State          = $State
        Config         = $Config
        SkipAppx       = [bool]$SkipAppx
        SkipComponents = [bool]$SkipComponents
        SkipRegistry   = [bool]$SkipRegistry
        Restore        = New-LunqRestoreData -LunqProfile $LunqProfile -Source Online
        RestorePath    = $restorePath
    }
    $started = Get-Date
    # Данные для отката записываются после каждого шага, в том числе упавшего.
    $results = Invoke-LunqBuild -Context $context -Online
    Write-LunqReport -Results $results -LunqProfile $LunqProfile -Elapsed ((Get-Date) - $started) -LogPath $LogPath -StepTimes $State['StepTimes'] -RestorePath $restorePath
}

function Select-LunqBuildContents {
    # Что войдёт в образ: обновления и драйверы из папок, программы и скрипты первого входа,
    # файл ответов и пункты сборки. В пошаговом режиме сводка показывается, пока пользователь не
    # начнёт сборку: пункт-действие меняет папку обновлений или драйверов, и сводка строится заново.
    # Switches: значения параметров скрипта (SkipUpdates, CleanupComponents, UpdatesToSetup,
    # DownloadUpdates, SkipDrivers, DriversToSetup, SkipApps, HostApps, SkipScripts, HostWifi,
    # Unattend, BypassRequirements, LocalAccount, BootCA2023, DefenderExclusion,
    # HostDrivers). Возвращает найденное (Found, FoundDU), выбор (Use), параметры после сводки
    # (Switches) и пути -UpdatesPath и -DriversPath. PEDriverCache и SizeCache заполняются для шагов после сводки.
    param(
        [Parameter(Mandatory)][hashtable]$Switches,
        [Parameter(Mandatory)]$FirstLogon,
        $HostRegion,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$UpdatesPath,
        [string]$DriversPath,
        [Parameter(Mandatory)][string]$CabCheckDir,
        [Parameter(Mandatory)][string]$HostDriversDir,
        [Parameter(Mandatory)][hashtable]$PEDriverCache,
        [Parameter(Mandatory)][hashtable]$SizeCache,
        [switch]$Interactive,
        [switch]$ListMode
    )
    $s = $Switches.Clone()
    # Обновления, драйверы, программы и скрипты берутся из Config. -UpdatesPath и -DriversPath
    # заменяют свои подпапки и должны указывать на непустую папку.
    $updatesDir = Join-Path $ConfigPath 'Updates'
    $driversDir = Join-Path $ConfigPath 'Drivers'
    if (-not $ListMode) {
        if ($UpdatesPath) {
            if (-not (Test-Path -LiteralPath $UpdatesPath -PathType Container)) { throw (Get-LunqText 'Main.UpdatesDirNotFound' $UpdatesPath) }
            $updatesDir = (Resolve-Path -LiteralPath $UpdatesPath).Path
        }
        if ($DriversPath) {
            if (-not (Test-Path -LiteralPath $DriversPath -PathType Container)) { throw (Get-LunqText 'Main.DriversDirNotFound' $DriversPath) }
            $driversDir = (Resolve-Path -LiteralPath $DriversPath).Path
        }
        # Драйверы этого компьютера вместо папки: в пошаговом режиме это пункт сводки.
        if ($s.HostDrivers -and -not $s.SkipDrivers) {
            $picked = Invoke-LunqContentAction -Action 'hostDrivers' -HostDriversDir $HostDriversDir
            if ($picked) { $driversDir = $picked.Path }
        }
    }
    # Что пользователь включил и выключил в сводке (Key пункта и Enabled). Когда сводка
    # показывается снова после выбора папки, его выбор сохраняется.
    $choices = @{}
    # Какого вида .cab в корне папки обновлений: распознаётся один раз, а не при каждом показе сводки.
    $cabKinds = @{}

    while ($true) {
        $found = [pscustomobject]@{ Updates = @(); SafeOS = @(); SetupDU = @(); DUNames = @(); Drivers = @() }
        if (-not $ListMode) {
            $found = Find-LunqBuildInputs -UpdatesDir $updatesDir -DriversDir $driversDir -CabCheckDir $CabCheckDir -CabCache $cabKinds
            if ($UpdatesPath -and ($found.Updates.Count + $found.SafeOS.Count + $found.SetupDU.Count) -eq 0) { throw (Get-LunqText 'Main.UpdatesDirEmpty' $UpdatesPath) }
            if ($DriversPath -and $found.Drivers.Count -eq 0) { throw (Get-LunqText 'Main.DriversDirEmpty' $DriversPath) }
        }
        $foundDU = @($found.SafeOS) + @($found.SetupDU)

        # Файл ответов: в пошаговом режиме включён по умолчанию, с параметрами только по ключам.
        $withUnattend = $Interactive -or $s.Unattend -or $s.BypassRequirements -or $s.LocalAccount
        $use = @{
            updates        = ($found.Updates.Count + $foundDU.Count) -gt 0 -and -not $s.SkipUpdates
            cleanup        = [bool]$s.CleanupComponents
            updatesToSetup = [bool]$s.UpdatesToSetup
            download       = [bool]$s.DownloadUpdates
            drivers        = $found.Drivers.Count -gt 0 -and -not $s.SkipDrivers
            driversToSetup = [bool]$s.DriversToSetup
            apps           = $FirstLogon.Apps.Count -gt 0 -and -not $s.SkipApps
            hostApps       = [bool]$s.HostApps
            scripts        = $FirstLogon.Scripts.Count -gt 0 -and -not $s.SkipScripts
            wifi           = [bool]$s.HostWifi
            unattend       = [bool]$withUnattend
            oobe           = [bool]$withUnattend
            region         = [bool]$withUnattend
            bypass         = [bool]$s.BypassRequirements
            localAccount   = [bool]$s.LocalAccount
            bootCA2023     = [bool]$s.BootCA2023
            defender       = [bool]$s.DefenderExclusion
        }
        $action = $null
        if ($Interactive -and -not $ListMode) {
            Write-Section (Get-LunqText 'Main.SectionContents')
            Write-Info (Get-LunqText 'Main.ContentsIntro' $ConfigPath)
            Write-Info (Get-LunqText 'Main.ContentsHowTo')
            $options = New-LunqContentOptions -Found $found -FirstLogon $FirstLogon -Use $use -HostRegion $HostRegion `
                -UpdatesDir $updatesDir -DriversDir $driversDir -PEDriverCache $PEDriverCache -SizeCache $SizeCache
            foreach ($option in $options) {
                if ($choices.ContainsKey($option.Key)) { $option.Enabled = $choices[$option.Key] }
            }
            $action = Select-LunqBuildOptions -Options $options
            foreach ($option in $options) {
                if (-not $option.Action) { $choices[$option.Key] = $option.Enabled }
            }
            foreach ($key in @($use.Keys)) { $use[$key] = Test-LunqOption -Options $options -Key $key }
            $s.UpdatesToSetup = $use.updatesToSetup
            $s.DriversToSetup = $use.driversToSetup
            $s.DownloadUpdates = $use.download
            $s.HostApps = $use.hostApps
            $s.HostWifi = $use.wifi
            # Скачанные Safe OS и Setup Dynamic Update нужны только вместе с обновлением установщика.
            if ($s.DownloadUpdates) { $s.UpdatesToSetup = $true }
            $s.CleanupComponents = $use.cleanup
            $s.BootCA2023 = $use.bootCA2023
            $s.DefenderExclusion = $use.defender
        }
        if (-not $action) { break }

        # Новая папка заменяет прежнюю, а пункты обновлений или драйверов снова получают
        # значения по умолчанию: выбрав папку, пользователь хочет её содержимое в образе.
        $picked = Invoke-LunqContentAction -Action $action -HostDriversDir $HostDriversDir
        if ($picked -and $picked.Kind -eq 'Updates') {
            $updatesDir = $picked.Path
            $UpdatesPath = $picked.Path
            foreach ($key in 'updates', 'updatesToSetup') { $choices.Remove($key) }
        }
        elseif ($picked) {
            # Драйверы этого компьютера каждый раз выгружаются в ту же папку: прежний размер не годится.
            $s.HostDrivers = $picked.Path -eq $HostDriversDir
            $SizeCache.Remove($picked.Path)
            $driversDir = $picked.Path
            $DriversPath = $picked.Path
            foreach ($key in 'drivers', 'driversToSetup') { $choices.Remove($key) }
        }
    }
    if ($found.Drivers.Count -gt 0) { $DriversPath = (Resolve-Path -LiteralPath $driversDir).Path }
    $s.HostDrivers = $use.drivers -and $found.Drivers.Count -gt 0 -and $driversDir -eq $HostDriversDir
    return [pscustomobject]@{
        Found       = $found
        FoundDU     = $foundDU
        Use         = $use
        Switches    = $s
        UpdatesPath = $UpdatesPath
        DriversPath = $DriversPath
    }
}

function Get-LunqBuildInputs {
    # Что именно пойдёт в образ по выбору из сводки: обновления (с Safe OS и Setup Dynamic Update
    # только вместе с установщиком), драйверы, что получат установщик и WinRE, первый вход и файл
    # ответов. Use: выбор из сводки (Select-LunqBuildContents), FirstLogon: найденное в Config.
    param(
        [Parameter(Mandatory)]$Found,
        [Parameter(Mandatory)][hashtable]$Use,
        [Parameter(Mandatory)]$FirstLogon,
        [Parameter(Mandatory)]$Config,
        [string]$DriversPath,
        [switch]$UpdatesToSetup,
        [switch]$DriversToSetup,
        [string[]]$WifiNames = @(),
        [Parameter(Mandatory)][string]$WifiPath,
        [string]$AccountName,
        $HostRegion,
        [Parameter(Mandatory)][hashtable]$PEDriverCache,
        [Parameter(Mandatory)][hashtable]$SizeCache,
        [switch]$ListMode
    )
    $updates = @()
    $safeOSUpdates = @()
    $setupDU = @()
    if ($Use.updates) {
        $updates = $Found.Updates
        if ($UpdatesToSetup) {
            $safeOSUpdates = $Found.SafeOS
            $setupDU = $Found.SetupDU
        }
    }
    $drivers = @()
    if ($Use.drivers) { $drivers = $Found.Drivers }
    $driversSize = [long]0
    if ($drivers.Count -gt 0) { $driversSize = Get-FolderSize $DriversPath -Cache $SizeCache }
    if ($drivers.Count -eq 0) { $DriversToSetup = [switch]$false }

    # Установщик и WinRE получают только обновления самой Windows.
    $peUpdates = @()
    if ($UpdatesToSetup) { $peUpdates = Select-LunqPEUpdates $updates }
    $peDrivers = @()
    if ($DriversToSetup) {
        $peDrivers = Select-LunqPEDrivers $drivers -Cache $PEDriverCache
        if ($peDrivers.Count -eq 0) { Write-Warning (Get-LunqText 'Main.NoPEDrivers') }
    }

    $firstLogonPlan = $null
    # Программы из поля Uninstall включённых категорий: их удаляет первый вход.
    $uninstall = Get-ConfigList $Config 'Uninstall'
    # Учётной записи без пароля первый вход предложит его задать, даже если программ и скриптов нет.
    if (-not $ListMode -and ($Use.apps -or $Use.scripts -or $WifiNames.Count -gt 0 -or $uninstall.Count -gt 0 -or $AccountName)) {
        $logonApps = @()
        if ($Use.apps) { $logonApps = $FirstLogon.Apps }
        $logonScripts = @()
        if ($Use.scripts) { $logonScripts = $FirstLogon.Scripts }
        $firstLogonPlan = [pscustomobject]@{
            AppsPath     = $FirstLogon.AppsPath
            Apps         = $logonApps
            ScriptsPath  = $FirstLogon.ScriptsPath
            Scripts      = $logonScripts
            Wifi         = $WifiNames
            WifiPath     = $WifiPath
            Uninstall    = $uninstall
            LocalAccount = $AccountName
        }
    }

    $setupAnswers = $null
    if (-not $ListMode -and $Use.unattend -and ($Use.oobe -or $Use.region -or $Use.bypass -or $Use.localAccount)) {
        $setupAnswers = [pscustomobject]@{
            Oobe         = [bool]$Use.oobe
            Region       = $(if ($Use.region) { $HostRegion } else { $null })
            Bypass       = [bool]$Use.bypass
            LocalAccount = [bool]$Use.localAccount
            AccountName  = $AccountName
        }
    }
    return [pscustomobject]@{
        Updates        = $updates
        SafeOSUpdates  = $safeOSUpdates
        SetupUpdates   = $setupDU
        Drivers        = $drivers
        DriversSize    = $driversSize
        DriversToSetup = [bool]$DriversToSetup
        PEUpdates      = $peUpdates
        PEDrivers      = $peDrivers
        FirstLogon     = $firstLogonPlan
        SetupAnswers   = $setupAnswers
    }
}

function Invoke-LunqInventoryMode {
    # Режим «Что в образе»: список приложений, компонентов и пакетов редакции в текстовый файл
    # рядом с ISO (или в папке логов). Образ монтируется только для чтения.
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string[]]$MountPaths,
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$EditionName,
        [Parameter(Mandatory)][string]$BuildText,
        [switch]$DirectMount,
        [Parameter(Mandatory)]$LunqProfile,
        [Parameter(Mandatory)][string]$ContentsDir,
        [switch]$Interactive
    )
    $contentsPath = Join-Path $ContentsDir ('{0}_{1}_contents.txt' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath), $Index)
    $context = @{
        State        = $State
        WorkDir      = $WorkDir
        MountPaths   = $MountPaths
        MountDir     = $MountDir
        WimPath      = $WimPath
        IsoPath      = $IsoPath
        Index        = $Index
        DirectMount  = [bool]$DirectMount
        Profile      = $LunqProfile
        ContentsPath = $contentsPath
        Header       = @(
            (Get-LunqText 'Main.InventoryHeader' $Index $EditionName $BuildText),
            "ISO: $IsoPath",
            (Get-LunqText 'Main.InventoryCreated' (Get-LunqVersion) (Get-Date -Format 'yyyy-MM-dd HH:mm')),
            '')
    }
    $null = Invoke-LunqBuild -Context $context -Inventory
    $inventory = $State.Inventory

    Write-Section (Get-LunqText 'Main.SectionSummary')
    Write-Info (Get-LunqText 'Main.InventoryCounts' $inventory.Appx $inventory.Capabilities $inventory.Enabled $inventory.Disabled)
    if ($inventory.Missing -gt 0) { Write-Info (Get-LunqText 'Main.InventoryMissing' $inventory.Missing) }
    Write-Info (Get-LunqText 'Main.InventorySaved' $contentsPath)
    if ($Interactive) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$contentsPath`"" -ErrorAction SilentlyContinue }
}

function Write-LunqBuildPlan {
    # План сборки перед подтверждением: что войдёт в образ и куда ляжет результат.
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$EditionName,
        [Parameter(Mandatory)][string]$BuildText,
        [Parameter(Mandatory)]$LunqProfile,
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)]$Config,
        $Updates = @(),
        [long]$UpdatesSize = 0,
        $SafeOSUpdates = @(),
        $SetupUpdates = @(),
        $PEUpdates = @(),
        $Drivers = @(),
        [long]$DriversSize = 0,
        [string]$DriversPath,
        $PEDrivers = @(),
        [switch]$ServicePE,
        [switch]$UpdatesToSetup,
        [switch]$DynamicUpdatesSkipped,
        $FirstLogon,
        $SetupAnswers,
        [string]$AccountName,
        [switch]$SkipAppx,
        [switch]$SkipComponents,
        [switch]$SkipRegistry,
        [switch]$CleanupComponents,
        [switch]$DefenderExclusion,
        [switch]$BootCA2023,
        [Parameter(Mandatory)][string]$OutputIso,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$LogPath
    )
    $skipped = Get-LunqText 'Main.PlanSkipped'
    Write-Section (Get-LunqText 'Main.SectionPlan')
    Write-Info (Get-LunqText 'Main.PlanSourceIso' $IsoPath)
    Write-Info (Get-LunqText 'Main.PlanEdition' $Index $EditionName)
    Write-Info (Get-LunqText 'Main.PlanBuild' $BuildText)
    Write-Info (Get-LunqText 'Main.PlanProfile' $LunqProfile.Name $ProfilePath)
    if (@($Updates).Count -gt 0) {
        Write-Info (Get-LunqText 'Main.PlanUpdates' @($Updates).Count (Format-Size $UpdatesSize))
        Write-UpdateList -Files $Updates
    }
    else { Write-Info (Get-LunqText 'Main.PlanUpdatesNone') }
    if (@($Drivers).Count -gt 0) {
        Write-Info (Get-LunqText 'Main.PlanDrivers' @($Drivers).Count (Format-Size $DriversSize) $DriversPath)
    }
    else { Write-Info (Get-LunqText 'Main.PlanDriversNone') }
    if ($ServicePE) {
        $what = @()
        if (@($PEUpdates).Count -gt 0) { $what += Get-LunqText 'Main.PlanPEUpdates' @($PEUpdates).Count }
        if (@($SafeOSUpdates).Count -gt 0) { $what += Get-LunqText 'Main.PlanPESafeOS' @($SafeOSUpdates).Count }
        if (@($SetupUpdates).Count -gt 0) { $what += Get-LunqText 'Main.PlanPESetupDU' @($SetupUpdates).Count }
        if (@($PEDrivers).Count -gt 0) { $what += Get-LunqText 'Main.PlanPEDrivers' @($PEDrivers).Count }
        $whatText = $what[-1]
        if ($what.Count -gt 1) { $whatText = ($what[0..($what.Count - 2)] -join ', ') + (Get-LunqText 'Main.PlanPEJoin') + $what[-1] }
        Write-Info (Get-LunqText 'Main.PlanPE' $whatText)
        if ($UpdatesToSetup -and @($PEUpdates).Count -lt @($Updates).Count) { Write-Info (Get-LunqText 'Main.PlanPESkipped') }
    }
    if ($DynamicUpdatesSkipped) { Write-Info (Get-LunqText 'Main.PlanDUSkipped') }
    if ($FirstLogon) {
        Write-Info (Get-LunqText 'Main.PlanFirstLogon' (Format-FirstLogonSummary -FirstLogon $FirstLogon))
    }
    else { Write-Info (Get-LunqText 'Main.PlanFirstLogonNone') }
    if ($SetupAnswers) {
        Write-Info (Get-LunqText 'Main.PlanUnattend' (Format-LunqUnattendSummary -Unattend $SetupAnswers))
        if ($AccountName) { Write-Warning (Get-LunqText 'Main.AccountNoPassword' $AccountName) }
    }
    else { Write-Info (Get-LunqText 'Main.PlanUnattendNone') }
    $enabledCount = @($LunqProfile.Categories | Where-Object { $_.Enabled }).Count
    Write-Info (Get-LunqText 'Main.PlanCategories' $enabledCount $LunqProfile.Categories.Count)
    Write-CategoryList -LunqProfile $LunqProfile
    if ($SkipAppx) { Write-Info (Get-LunqText 'Main.PlanAppx' $skipped) }
    if ($SkipComponents) { Write-Info (Get-LunqText 'Main.PlanComponents' $skipped) }
    elseif ($Config.Packages.Remove.Count -gt 0) { Write-Warning (Get-LunqText 'Main.PackagesWarning') }
    if ($SkipRegistry) { Write-Info (Get-LunqText 'Main.PlanRegistry' $skipped) }
    if ($CleanupComponents) { Write-Info (Get-LunqText 'Main.PlanCleanup') }
    if ($DefenderExclusion) { Write-Info (Get-LunqText 'Main.PlanDefender') }
    if ($BootCA2023) {
        Write-Info (Get-LunqText 'Main.PlanBootCA2023')
        Write-Warning (Get-LunqText 'Main.BootCA2023Warning')
    }
    Write-Info (Get-LunqText 'Main.PlanOutputIso' $OutputIso)
    Write-Info (Get-LunqText 'Main.PlanWorkDir' $WorkDir)
    Write-Info (Get-LunqText 'Main.PlanLog' $LogPath)
}

function Save-LunqBuildOutputs {
    # Рецепт и HTML-отчёт рядом с ISO. Не шаг сборки: ISO уже готов, и сбой здесь его не портит.
    # RecipeValues: значения для New-LunqRecipe, кроме списков программ и скриптов, которые
    # берутся из FirstLogon.
    param(
        [Parameter(Mandatory)][hashtable]$RecipeValues,
        [Parameter(Mandatory)][hashtable]$HashCache,
        $FirstLogon,
        [Parameter(Mandatory)]$Results,
        [Parameter(Mandatory)]$LunqProfile,
        $StepTimes,
        [Parameter(Mandatory)][timespan]$Elapsed
    )
    $outputIso = $RecipeValues.OutputIso
    $recipePath = Get-LunqRecipePath -OutputIso $outputIso
    $htmlPath = Get-LunqRecipePath -OutputIso $outputIso -Extension '.lunq.html'
    try {
        Write-Info (Get-LunqText 'Main.RecipeWriting')
        $values = $RecipeValues.Clone()
        $values.Apps = @()
        if ($FirstLogon -and $FirstLogon.Apps.Count -gt 0) {
            $values.Apps = @(Get-Content -LiteralPath $FirstLogon.AppsPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        }
        $values.Scripts = @()
        if ($FirstLogon) { $values.Scripts = $FirstLogon.Scripts }
        $recipe = New-LunqRecipe -HashCache $HashCache -Values $values
        Save-LunqRecipe -Recipe $recipe -Path $recipePath
        Write-LunqHtmlReport -Path $htmlPath -Results $Results -LunqProfile $LunqProfile -StepTimes $StepTimes -Info @{
            IsoPath = $values.IsoPath; IsoSize = [long]$recipe.Iso.Size; OutputIso = $outputIso; OutputSize = [long](Get-Item -LiteralPath $outputIso).Length
            ProfilePath = $values.ProfilePath; Elapsed = $Elapsed; RecipePath = $recipePath; EditionName = $values.EditionName; BuildText = $values.BuildText
        }
        Write-Info (Get-LunqText 'Main.RecipeSaved' $recipePath)
        Write-Info (Get-LunqText 'Main.HtmlSaved' $htmlPath)
    }
    catch { Write-Warning (Get-LunqText 'Main.RecipeFailed' $_.Exception.Message) }
}
