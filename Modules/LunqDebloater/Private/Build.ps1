# Шаги сборки образа. Каждый шаг получает один и тот же контекст сборки (хэш-таблицу из
# LunqDebloater.ps1) и возвращает результаты для итога. В Context.State шаги отмечают то, что
# нужно знать при ошибке: смонтирован ли образ и создал ли этот запуск рабочую папку.

function Get-LunqBuildSteps {
    # Список шагов по порядку. When решает, выполняется ли шаг, и по нему же считается «Шаг N из M».
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    return @(
        @{
            Name = 'Prepare'; When = $true
            Title = Get-LunqText 'Main.StepPrepare'; Hint = Get-LunqText 'Main.StepPrepareHint' $c.WorkDir
            Run = {
                param($c)
                Reset-LunqWorkDir -WorkDir $c.WorkDir -MountPaths $c.MountPaths
                $c.State.WorkDirOwned = $true
                New-Item -ItemType Directory -Path $c.MountDir -Force | Out-Null
            }
        },
        @{
            Name = 'CopyIso'; When = $true
            Title = Get-LunqText 'Main.StepCopyIso'; Hint = Get-LunqText 'Main.StepCopyIsoHint'
            Run = {
                param($c)
                # ISO остаётся подключённым до конца шага Export: подключать его второй раз незачем.
                # Отключает его Export, а при ошибке LunqDebloater.ps1 через State.Iso.
                $c.State.Iso = Mount-IsoImage -IsoPath $c.IsoPath
                Copy-IsoContent -IsoRoot $c.State.Iso.Root -Destination $c.IsoDir
            }
        },
        @{
            Name = 'Export'; When = $true
            Title = Get-LunqText 'Main.StepExport'; Hint = Get-LunqText 'Main.StepExportHint'
            Run = {
                param($c)
                # Редакция берётся прямо с подключённого ISO: install.esd не копируется в рабочую папку.
                if (-not $c.State.Iso) { $c.State.Iso = Mount-IsoImage -IsoPath $c.IsoPath }
                try {
                    Export-SingleEdition -SourceImage (Get-InstallImagePath -IsoRoot $c.State.Iso.Root) -SourceIndex $c.Index -DestinationImage $c.WimPath `
                        -CompressionType Fast -KeepSource
                }
                finally { Dismount-LunqStateIso -State $c.State }
                # Сведения об образе нужны позже: язык для файла ответов.
                $c.State.ImageInfo = Get-WindowsImage -ImagePath $c.WimPath -Index 1
                Write-Info (Get-LunqText 'Main.ExportedInfo' $c.State.ImageInfo.ImageName $c.State.ImageInfo.Version)
            }
        },
        @{
            Name = 'Mount'; When = $true
            Title = Get-LunqText 'Main.StepMount'; Hint = Get-LunqText 'Main.StepMountHint'
            Run = {
                param($c)
                Mount-WindowsImage -ImagePath $c.WimPath -Index 1 -Path $c.MountDir | Out-Null
                $c.State.Mounted = $true
                # Sysprep\unattend.xml в образе помешал бы первому входу: лучше узнать об этом сразу,
                # а не после обновлений, драйверов и WinRE.
                if ($c.FirstLogon -and (Test-Path -LiteralPath (Join-Path $c.MountDir 'Windows\System32\Sysprep\unattend.xml'))) {
                    throw (Get-LunqText 'PostInstall.UnattendExists')
                }
            }
        },
        @{
            Name = 'Updates'; When = @($c.Updates).Count -gt 0
            Title = Get-LunqText 'Main.StepUpdates'; Hint = Get-LunqText 'Main.StepUpdatesHint'
            Run = { param($c) Add-LunqUpdates -MountPath $c.MountDir -Files $c.Updates -ScratchDir (Join-Path $c.WorkDir 'scratch') }
        },
        @{
            Name = 'Drivers'; When = @($c.Drivers).Count -gt 0
            Title = Get-LunqText 'Main.StepDrivers'; Hint = Get-LunqText 'Main.StepDriversHint'
            Run = { param($c) Add-LunqDrivers -MountPath $c.MountDir -InfFiles $c.Drivers -Root $c.DriversPath }
        },
        @{
            Name = 'Recovery'; When = [bool]$c.ServiceRecovery
            Title = Get-LunqText 'Main.StepRecovery'; Hint = Get-LunqText 'Main.StepRecoveryHint'
            Run = {
                param($c)
                Update-LunqRecovery -MountPath $c.MountDir -WorkDir $c.WorkDir -PEMountPath $c.ReMountDir -Updates $c.PEUpdates -SafeOS $c.SafeOSUpdates `
                    -Drivers $c.PEDrivers -DriversRoot $c.DriversPath
            }
        },
        @{
            Name = 'FirstLogon'; When = [bool]$c.FirstLogon
            Title = Get-LunqText 'Main.StepFirstLogon'; Hint = Get-LunqText 'Main.StepFirstLogonHint'
            Run = { param($c) Install-LunqFirstLogon -MountPath $c.MountDir -FirstLogon $c.FirstLogon -Architecture $c.Architecture -Restore $c.Restore }
        },
        @{
            Name = 'Unattend'; When = [bool]$c.SetupAnswers
            Title = Get-LunqText 'Main.StepUnattend'; Hint = Get-LunqText 'Main.StepUnattendHint'
            Run = {
                param($c)
                Install-LunqUnattend -IsoRoot $c.IsoDir -Unattend $c.SetupAnswers -Architecture $c.Architecture `
                    -ImageLanguage (Get-LunqImageLanguage -Image $c.State.ImageInfo) -WithFirstLogon:([bool]$c.FirstLogon)
            }
        },
        @{
            Name = 'Appx'; When = -not $c.SkipAppx
            Title = Get-LunqText 'Main.StepAppx'; Hint = Get-LunqText 'Main.StepAppxHint'
            Run = { param($c) Remove-LunqAppx -MountPath $c.MountDir -Config $c.Config -Restore $c.Restore }
        },
        @{
            Name = 'Capabilities'; When = -not $c.SkipComponents
            Title = Get-LunqText 'Main.StepCapabilities'; Hint = Get-LunqText 'Main.StepCapabilitiesHint'
            Run = { param($c) Remove-LunqCapabilities -MountPath $c.MountDir -Config $c.Config -Restore $c.Restore }
        },
        @{
            Name = 'Features'; When = -not $c.SkipComponents
            Title = Get-LunqText 'Main.StepFeatures'; Hint = Get-LunqText 'Main.StepFeaturesHint'
            Run = {
                param($c)
                Disable-LunqFeatures -MountPath $c.MountDir -Config $c.Config -Restore $c.Restore
                Remove-LunqPackages -MountPath $c.MountDir -Config $c.Config -Restore $c.Restore
            }
        },
        @{
            Name = 'Registry'; When = -not $c.SkipRegistry
            Title = Get-LunqText 'Main.StepRegistry'; Hint = Get-LunqText 'Main.StepRegistryHint'
            Run = { param($c) Set-LunqRegistry -MountPath $c.MountDir -Config $c.Config -Restore $c.Restore }
        },
        @{
            Name = 'Cleanup'; When = [bool]$c.CleanupComponents
            Title = Get-LunqText 'Main.StepCleanup'; Hint = Get-LunqText 'Main.StepCleanupHint'
            Run = {
                param($c)
                $cleanup = New-LunqResult (Get-LunqText 'Main.CleanupResult') 'Cleanup'
                if (Invoke-LunqComponentCleanup -MountPath $c.MountDir -ScratchDir (Join-Path $c.WorkDir 'scratch')) {
                    $cleanup.Summary = Get-LunqText 'Main.CleanupDone'
                }
                else {
                    $cleanup.Summary = Get-LunqText 'Main.CleanupFailed'
                    $cleanup.Failed.Add('StartComponentCleanup')
                }
                $cleanup
            }
        },
        @{
            Name = 'Save'; When = $true
            Title = Get-LunqText 'Main.StepSave'; Hint = Get-LunqText 'Main.StepSaveHint'
            Run = {
                param($c)
                # Файлы загрузчика 2023 берутся до отметки в реестре: в ней записано, нашлись ли они.
                if ($c.BootCA2023) {
                    $c.State.BootCA2023 = Export-LunqBootCA2023 -MountPath $c.MountDir -Destination (Join-Path $c.WorkDir 'bootex')
                }
                Set-LunqBuildStamp -MountPath $c.MountDir -Values (Get-LunqBuildStampValues -Context $c)
                # Что удалено и какие значения реестра были до профиля: по ним -Restore на
                # установленной системе вернёт выбранное.
                if ($c.Restore) {
                    try { Save-LunqRestoreData -Restore $c.Restore -Path (Join-Path $c.MountDir 'Windows\LunqDebloater\Restore.json') }
                    catch { Write-Warning (Get-LunqText 'Restore.SaveFailed' $_.Exception.Message) }
                }
                Dismount-WindowsImage -Path $c.MountDir -Save | Out-Null
                $c.State.Mounted = $false
            }
        },
        @{
            Name = 'Setup'; When = [bool]$c.ServicePE
            Title = Get-LunqText 'Main.StepSetup'; Hint = Get-LunqText 'Main.StepSetupHint'
            Run = {
                param($c)
                Update-LunqSetup -IsoRoot $c.IsoDir -WorkDir $c.WorkDir -PEMountPath $c.BootMountDir -Updates $c.PEUpdates -SetupUpdates $c.SetupUpdates `
                    -Drivers $c.PEDrivers -DriversRoot $c.DriversPath
            }
        },
        @{
            Name = 'Recompress'; When = $true
            Title = Get-LunqText 'Main.StepRecompress'; Hint = Get-LunqText 'Main.StepRecompressHint'
            Run = { param($c) Export-SingleEdition -SourceImage $c.WimPath -SourceIndex 1 -DestinationImage $c.WimPath }
        },
        @{
            Name = 'Iso'; When = $true
            Title = Get-LunqText 'Main.StepIso'; Hint = Get-LunqText 'Main.StepIsoHint'
            Run = {
                param($c)
                if ($c.BootCA2023) { Install-LunqBootCA2023 -IsoRoot $c.IsoDir -From (Join-Path $c.WorkDir 'bootex') }
                New-BootableIso -IsoRoot $c.IsoDir -OutputPath $c.OutputIso -Oscdimg $c.Oscdimg -Label $c.Label
            }
        }
    )
}

function Get-LunqInventorySteps {
    # Шаги режима «Что в образе»: редакция монтируется только для чтения (install.esd сначала
    # копируется в рабочую папку), а опись сохраняется в ContentsPath. Идут через Invoke-LunqBuild,
    # как и сборка: время шагов и метки в логе DISM у них те же. Опись шаг кладёт в State.Inventory.
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    return @(
        @{
            Name = 'Prepare'; When = $true
            Title = Get-LunqText 'Main.StepPrepare'; Hint = Get-LunqText 'Main.StepPrepareHint' $c.WorkDir
            Run = {
                param($c)
                Reset-LunqWorkDir -WorkDir $c.WorkDir -MountPaths $c.MountPaths
                $c.State.WorkDirOwned = $true
                New-Item -ItemType Directory -Path $c.MountDir, (Split-Path $c.WimPath -Parent) -Force | Out-Null
            }
        },
        @{
            # install.wim монтируется прямо с ISO (шаг OpenImage), копировать нужно только install.esd.
            Name = 'CopyEdition'; When = -not $c.DirectMount
            Title = Get-LunqText 'Main.StepCopyEdition'; Hint = Get-LunqText 'Main.StepCopyEditionHint'
            Run = { param($c) Copy-LunqInventoryEdition -Context $c }
        },
        @{
            Name = 'OpenImage'; When = $true
            Title = Get-LunqText 'Main.StepOpenImage'; Hint = Get-LunqText 'Main.StepOpenImageHint'
            Run = { param($c) Mount-LunqInventoryImage -Context $c }
        },
        @{
            Name = 'Inventory'; When = $true
            Title = Get-LunqText 'Main.StepReadInventory'; Hint = Get-LunqText 'Main.StepReadInventoryHint'
            Run = {
                param($c)
                $c.State.Inventory = Write-LunqInventory -MountPath $c.MountDir -LunqProfile $c.Profile -Path $c.ContentsPath -Header $c.Header
                Dismount-WindowsImage -Path $c.MountDir -Discard | Out-Null
                $c.State.Mounted = $false
                # ISO можно отключить только после образа, смонтированного прямо с него.
                Dismount-LunqStateIso -State $c.State
            }
        }
    )
}

function Get-LunqOnlineSteps {
    # Шаги -Online: профиль применяется к этой Windows. Перед каждым изменением запоминается,
    # что было, а последний шаг дописывает это в файл для отката (Get-LunqRestorePath).
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    return @(
        @{
            Name = 'Appx'; When = -not $c.SkipAppx
            Title = Get-LunqText 'Main.StepAppx'; Hint = Get-LunqText 'Main.StepOnlineAppxHint'
            Run = { param($c) Remove-LunqAppx -Online -Config $c.Config -Restore $c.Restore }
        },
        @{
            Name = 'Capabilities'; When = -not $c.SkipComponents
            Title = Get-LunqText 'Main.StepCapabilities'; Hint = Get-LunqText 'Main.StepCapabilitiesHint'
            Run = { param($c) Remove-LunqCapabilities -Online -Config $c.Config -Restore $c.Restore }
        },
        @{
            Name = 'Features'; When = -not $c.SkipComponents
            Title = Get-LunqText 'Main.StepFeatures'; Hint = Get-LunqText 'Main.StepFeaturesHint'
            Run = {
                param($c)
                Disable-LunqFeatures -Online -Config $c.Config -Restore $c.Restore
                Remove-LunqPackages -Online -Config $c.Config -Restore $c.Restore
            }
        },
        @{
            Name = 'Registry'; When = -not $c.SkipRegistry
            Title = Get-LunqText 'Main.StepRegistry'; Hint = Get-LunqText 'Main.StepOnlineRegistryHint'
            Run = { param($c) Set-LunqRegistry -Online -Config $c.Config -Restore $c.Restore }
        },
        @{
            # В образе эти программы удаляет первый вход (шаг FirstLogon), здесь их можно удалить сразу.
            Name = 'Uninstall'; When = (Get-ConfigList $c.Config 'Uninstall').Count -gt 0
            Title = Get-LunqText 'Main.StepUninstall'; Hint = Get-LunqText 'Main.StepUninstallHint'
            Run = { param($c) Remove-LunqPrograms -Config $c.Config -Restore $c.Restore }
        },
        @{
            Name = 'SaveRestore'; When = $true
            Title = Get-LunqText 'Main.StepSaveRestore'; Hint = Get-LunqText 'Main.StepSaveRestoreHint' $c.RestorePath
            Run = { param($c) Save-LunqRestoreData -Restore $c.Restore -Path $c.RestorePath -Merge }
        }
    )
}

function Copy-LunqInventoryEdition {
    # Экспорт редакции в рабочую папку для режима «Что в образе»: install.esd нельзя смонтировать.
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    if (-not $c.State.Iso) { $c.State.Iso = Mount-IsoImage -IsoPath $c.IsoPath }
    try {
        Export-WindowsImage -SourceImagePath (Get-InstallImagePath -IsoRoot $c.State.Iso.Root) -SourceIndex $c.Index `
            -DestinationImagePath $c.WimPath -CompressionType Fast | Out-Null
    }
    finally { Dismount-LunqStateIso -State $c.State }
}

function Mount-LunqInventoryImage {
    # Монтирует редакцию только для чтения. install.wim монтируется прямо с подключённого ISO:
    # экспорт 4-7 ГБ в рабочую папку для одной описи не нужен, а ISO остаётся подключённым до
    # шага Inventory. Если DISM не смонтирует WIM с ISO, редакция экспортируется, как install.esd.
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    if ($c.DirectMount) {
        $c.State.Iso = Mount-IsoImage -IsoPath $c.IsoPath
        try {
            Mount-WindowsImage -ImagePath (Get-InstallImagePath -IsoRoot $c.State.Iso.Root) -Index $c.Index -Path $c.MountDir -ReadOnly | Out-Null
            $c.State.Mounted = $true
            return
        }
        catch {
            Write-Warning (Get-LunqText 'Main.DirectMountFailed' $_.Exception.Message)
            Dismount-WindowsImage -Path $c.MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
        }
        Copy-LunqInventoryEdition -Context $c
    }
    Mount-WindowsImage -ImagePath $c.WimPath -Index 1 -Path $c.MountDir -ReadOnly | Out-Null
    $c.State.Mounted = $true
}

function Get-LunqBuildStampValues {
    # Что записывается в HKLM\SOFTWARE\LunqDebloater собранного образа: чем и как он собран.
    param([Parameter(Mandatory)][hashtable]$Context)
    $c = $Context
    $yes = Get-LunqText 'Main.StampYes'
    $no = Get-LunqText 'Main.StampNo'
    $skippedSteps = @()
    if ($c.SkipAppx) { $skippedSteps += 'Appx' }
    if ($c.SkipComponents) { $skippedSteps += 'Components' }
    if ($c.SkipRegistry) { $skippedSteps += 'Registry' }
    $lunqProfile = $c.Profile
    return [ordered]@{
        Version           = Get-LunqVersion
        BuildDate         = Get-Date -Format 'yyyy-MM-dd HH:mm'
        SourceIso         = Split-Path $c.IsoPath -Leaf
        Edition           = $c.EditionName
        SourceBuild       = $c.BuildText
        Profile           = "$($lunqProfile.Name) ($(Split-Path $c.ProfilePath -Leaf))"
        Categories        = (@($lunqProfile.Categories | Where-Object { $_.Enabled } | ForEach-Object { $_.Id }) -join ', ')
        SkippedCategories = (@($lunqProfile.Categories | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Id }) -join ', ')
        SkippedSteps      = ($skippedSteps -join ', ')
        Updates           = (@($c.Updates | ForEach-Object { $_.Name }) -join ', ')
        SafeOSUpdates     = (@($c.SafeOSUpdates | ForEach-Object { $_.Name }) -join ', ')
        SetupUpdates      = (@($c.SetupUpdates | ForEach-Object { $_.Name }) -join ', ')
        Drivers           = [string]@($c.Drivers).Count
        SetupAndWinRE     = $(if ($c.ServicePE) { $yes } else { $no })
        SetupAnswerFile   = $(if ($c.SetupAnswers) { Format-LunqUnattendSummary -Unattend $c.SetupAnswers } else { $no })
        CleanupComponents = $(if ($c.CleanupComponents) { $yes } else { $no })
        BootCA2023        = $(if ($c.BootCA2023 -and $c.State['BootCA2023']) { $yes } else { $no })
        Apps              = $(if ($c.FirstLogon) { $c.FirstLogon.Apps -join ', ' } else { '' })
        Scripts           = $(if ($c.FirstLogon) { @($c.FirstLogon.Scripts | ForEach-Object { $_.Name }) -join ', ' } else { '' })
    }
}

function Invoke-LunqBuild {
    # Выполняет нужные шаги по порядку и возвращает их результаты для итога.
    # -Inventory: шаги режима «Что в образе» вместо сборки, -Online: шаги для этой Windows.
    param([Parameter(Mandatory)][hashtable]$Context, [switch]$Inventory, [switch]$Online)
    if ($Inventory) { $steps = @(Get-LunqInventorySteps -Context $Context | Where-Object { $_.When }) }
    elseif ($Online) { $steps = @(Get-LunqOnlineSteps -Context $Context | Where-Object { $_.When }) }
    else { $steps = @(Get-LunqBuildSteps -Context $Context | Where-Object { $_.When }) }
    Initialize-LunqSteps -Total $steps.Count
    $results = @()
    # Сколько шёл каждый шаг: итог показывает самые долгие.
    $Context.State.StepTimes = New-Object System.Collections.Generic.List[object]
    $number = 0
    foreach ($step in $steps) {
        $number++
        Write-Step $step.Title $step.Hint
        Write-LunqDismMarker ('step {0}/{1}: {2}' -f $number, $steps.Count, $step.Name)
        $started = Get-Date
        try {
            # В итог идут только результаты шагов: всё прочее, что вернули команды, отбрасывается.
            $results += @(& $step.Run $Context | Where-Object { $_ -and $_.PSObject.Properties['Kind'] })
        }
        finally {
            $Context.State.StepTimes.Add([pscustomobject]@{ Title = $step.Title; Elapsed = (Get-Date) - $started })
            # -Online меняет эту Windows сразу, поэтому то, что было до шага, записывается после каждого
            # шага, а не только в конце: после ошибки, Ctrl+C или закрытого окна -Restore вернёт уже
            # удалённое. Записанное раньше при этом не заменяется, поэтому запись можно повторять.
            if ($Online -and $step.Name -ne 'SaveRestore') {
                try { Save-LunqRestoreData -Restore $Context.Restore -Path $Context.RestorePath -Merge }
                catch { Write-Warning (Get-LunqText 'Restore.SaveFailed' $_.Exception.Message) }
            }
        }
    }
    return , $results
}
