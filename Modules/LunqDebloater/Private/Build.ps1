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
            Run = { param($c) Copy-IsoContent -IsoPath $c.IsoPath -Destination $c.IsoDir }
        },
        @{
            Name = 'Export'; When = $true
            Title = Get-LunqText 'Main.StepExport'; Hint = Get-LunqText 'Main.StepExportHint'
            Run = {
                param($c)
                Export-SingleEdition -SourceImage (Get-InstallImagePath -IsoRoot $c.IsoDir) -SourceIndex $c.Index -DestinationImage $c.WimPath
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
            Run = { param($c) Install-LunqFirstLogon -MountPath $c.MountDir -FirstLogon $c.FirstLogon -Architecture $c.Architecture }
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
            Run = { param($c) Remove-LunqAppx -MountPath $c.MountDir -Config $c.Config }
        },
        @{
            Name = 'Capabilities'; When = -not $c.SkipComponents
            Title = Get-LunqText 'Main.StepCapabilities'; Hint = Get-LunqText 'Main.StepCapabilitiesHint'
            Run = { param($c) Remove-LunqCapabilities -MountPath $c.MountDir -Config $c.Config }
        },
        @{
            Name = 'Features'; When = -not $c.SkipComponents
            Title = Get-LunqText 'Main.StepFeatures'; Hint = Get-LunqText 'Main.StepFeaturesHint'
            Run = {
                param($c)
                Disable-LunqFeatures -MountPath $c.MountDir -Config $c.Config
                Remove-LunqPackages -MountPath $c.MountDir -Config $c.Config
            }
        },
        @{
            Name = 'Registry'; When = -not $c.SkipRegistry
            Title = Get-LunqText 'Main.StepRegistry'; Hint = Get-LunqText 'Main.StepRegistryHint'
            Run = { param($c) Set-LunqRegistry -MountPath $c.MountDir -Config $c.Config }
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
                Set-LunqBuildStamp -MountPath $c.MountDir -Values (Get-LunqBuildStampValues -Context $c)
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
            Run = { param($c) New-BootableIso -IsoRoot $c.IsoDir -OutputPath $c.OutputIso -Oscdimg $c.Oscdimg -Label $c.Label }
        }
    )
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
        Apps              = $(if ($c.FirstLogon) { $c.FirstLogon.Apps -join ', ' } else { '' })
        Scripts           = $(if ($c.FirstLogon) { @($c.FirstLogon.Scripts | ForEach-Object { $_.Name }) -join ', ' } else { '' })
    }
}

function Invoke-LunqBuild {
    # Выполняет нужные шаги по порядку и возвращает их результаты для итога.
    param([Parameter(Mandatory)][hashtable]$Context)
    $steps = @(Get-LunqBuildSteps -Context $Context | Where-Object { $_.When })
    Initialize-LunqSteps -Total $steps.Count
    $results = @()
    foreach ($step in $steps) {
        Write-Step $step.Title $step.Hint
        # В итог идут только результаты шагов: всё прочее, что вернули команды, отбрасывается.
        $results += @(& $step.Run $Context | Where-Object { $_ -and $_.PSObject.Properties['Kind'] })
    }
    return , $results
}
