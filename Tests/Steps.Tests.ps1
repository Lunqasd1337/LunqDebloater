#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Шаги сборки по отдельности (Private\Build.ps1): какие шаги выполняются, что пишется в реестр
# образа и как шаги возвращают результаты. Сборка целиком проверяется в Build.Tests.ps1.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru

    function New-TestContext {
        # Контекст сборки со всеми ключами, как его собирает LunqDebloater.ps1: в модуле включён
        # StrictMode, и обращение к отсутствующему ключу было бы ошибкой.
        param([hashtable]$Values = @{})
        $context = @{
            State = @{ Mounted = $false; WorkDirOwned = $false; ImageInfo = $null; Iso = $null }
            WorkDir = 'work'; MountPaths = @(); MountDir = 'mount'; BootMountDir = 'bootmount'; ReMountDir = 'remount'
            IsoPath = 'C:\iso\Win11.iso'; IsoDir = 'iso'; WimPath = 'install.wim'; Index = 1; OutputIso = 'out.iso'; Oscdimg = 'oscdimg.exe'; Label = 'LUNQ_WIN11'
            Updates = @(); SafeOSUpdates = @(); SetupUpdates = @(); PEUpdates = @(); Drivers = @(); PEDrivers = @(); DriversPath = $null
            ServiceRecovery = $false; ServicePE = $false; FirstLogon = $null; SetupAnswers = $null; Architecture = 'amd64'; Config = $null
            SkipAppx = $false; SkipComponents = $false; SkipRegistry = $false; CleanupComponents = $false; BootCA2023 = $false; Restore = $null
            Profile = $null; ProfilePath = 'C:\Config\Profile.json'; EditionName = 'Windows 11 Pro'; BuildText = '26300.9457'
        }
        foreach ($key in $Values.Keys) { $context[$key] = $Values[$key] }
        return $context
    }
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Get-LunqInventorySteps' {
    It 'режим «Что в образе»: четыре шага, образ монтируется только для чтения' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $names = @(Get-LunqInventorySteps -Context @{ WorkDir = 'work'; DirectMount = $false } | Where-Object { $_.When } | ForEach-Object { $_.Name })
            $names | Should -Be @('Prepare', 'CopyEdition', 'OpenImage', 'Inventory')
            $context = @{
                State = @{ Mounted = $false; WorkDirOwned = $false; Iso = $null }; WorkDir = (Join-Path $Root 'inv'); MountPaths = @('mount')
                MountDir = (Join-Path $Root 'inv\mount'); WimPath = (Join-Path $Root 'inv\iso\sources\install.wim'); IsoPath = 'Win11.iso'; Index = 5
                DirectMount = $false
                Profile = [pscustomobject]@{ Name = 'p' }; ContentsPath = (Join-Path $Root 'contents.txt'); Header = @('header')
            }
            Mock Reset-LunqWorkDir { }
            Mock Mount-IsoImage { [pscustomobject]@{ Root = $Root } }
            Mock Dismount-IsoImage { }
            Mock Get-InstallImagePath { 'install.esd' }
            Mock Export-WindowsImage { }
            Mock Mount-WindowsImage { }
            Mock Dismount-WindowsImage { }
            Mock Write-LunqInventory { [pscustomobject]@{ Appx = 3 } }
            Mock Write-Step { }
            $null = Invoke-LunqBuild -Context $context -Inventory
            Should -Invoke Mount-WindowsImage -Times 1 -Exactly -ParameterFilter { $ReadOnly }
            Should -Invoke Export-WindowsImage -Times 1 -Exactly -ParameterFilter { $SourceIndex -eq 5 -and $CompressionType -eq 'Fast' }
            Should -Invoke Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $Discard }
            $context.State.Inventory.Appx | Should -Be 3
            $context.State.Mounted | Should -BeFalse
            $context.State.StepTimes.Count | Should -Be 4
            Should -Invoke Mount-IsoImage -Times 1 -Exactly
            Should -Invoke Dismount-IsoImage -Times 1 -Exactly
            $context.State.Iso | Should -BeNullOrEmpty
        }
    }

    It 'install.wim монтируется прямо с ISO: без копирования, ISO отключается после образа' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $names = @(Get-LunqInventorySteps -Context @{ WorkDir = 'work'; DirectMount = $true } | Where-Object { $_.When } | ForEach-Object { $_.Name })
            $names | Should -Be @('Prepare', 'OpenImage', 'Inventory')
            $context = @{
                State = @{ Mounted = $false; WorkDirOwned = $false; Iso = $null }; WorkDir = (Join-Path $Root 'direct'); MountPaths = @('mount')
                MountDir = (Join-Path $Root 'direct\mount'); WimPath = (Join-Path $Root 'direct\iso\sources\install.wim'); IsoPath = 'Win11.iso'; Index = 5
                DirectMount = $true; Profile = [pscustomobject]@{ Name = 'p' }; ContentsPath = (Join-Path $Root 'contents.txt'); Header = @('header')
            }
            $script:Order = New-Object System.Collections.Generic.List[string]
            Mock Reset-LunqWorkDir { }
            Mock Mount-IsoImage { [pscustomobject]@{ Root = $Root } }
            Mock Dismount-IsoImage { $script:Order.Add('iso') }
            Mock Get-InstallImagePath { 'Q:\sources\install.wim' }
            Mock Export-WindowsImage { }
            Mock Mount-WindowsImage { }
            Mock Dismount-WindowsImage { $script:Order.Add('image') }
            Mock Write-LunqInventory { [pscustomobject]@{ Appx = 3 } }
            Mock Write-Step { }
            $null = Invoke-LunqBuild -Context $context -Inventory
            Should -Invoke Export-WindowsImage -Times 0 -Exactly
            Should -Invoke Mount-WindowsImage -Times 1 -Exactly -ParameterFilter { $ReadOnly -and $ImagePath -eq 'Q:\sources\install.wim' -and $Index -eq 5 }
            @($script:Order) | Should -Be @('image', 'iso')
            $context.State.Mounted | Should -BeFalse
        }
    }

    It 'если install.wim не монтируется с ISO, редакция копируется, как install.esd' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $context = @{
                State = @{ Mounted = $false; WorkDirOwned = $false; Iso = $null }; WorkDir = (Join-Path $Root 'fallback'); MountPaths = @('mount')
                MountDir = (Join-Path $Root 'fallback\mount'); WimPath = (Join-Path $Root 'fallback\iso\sources\install.wim'); IsoPath = 'Win11.iso'; Index = 5
                DirectMount = $true; Profile = [pscustomobject]@{ Name = 'p' }; ContentsPath = (Join-Path $Root 'contents.txt'); Header = @('header')
            }
            Mock Reset-LunqWorkDir { }
            Mock Mount-IsoImage { [pscustomobject]@{ Root = $Root } }
            Mock Dismount-IsoImage { }
            Mock Get-InstallImagePath { 'Q:\sources\install.wim' }
            Mock Export-WindowsImage { }
            Mock Mount-WindowsImage { throw 'read-only media' } -ParameterFilter { $ImagePath -like 'Q:*' }
            Mock Mount-WindowsImage { }
            Mock Dismount-WindowsImage { }
            Mock Write-LunqInventory { [pscustomobject]@{ Appx = 3 } }
            Mock Write-Step { }
            Mock Write-Warning { }
            $null = Invoke-LunqBuild -Context $context -Inventory
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -match 'не смонтировался прямо с ISO' }
            Should -Invoke Export-WindowsImage -Times 1 -Exactly -ParameterFilter { $SourceImagePath -eq 'Q:\sources\install.wim' }
            Should -Invoke Mount-WindowsImage -Times 1 -Exactly -ParameterFilter { $ImagePath -eq $context.WimPath -and $ReadOnly }
            Should -Invoke Dismount-IsoImage -Times 1 -Exactly
            $context.State.Mounted | Should -BeFalse
        }
    }
}

Describe 'Get-LunqBuildSteps' {
    It 'без обновлений, драйверов и первого входа: обязательные шаги и профиль' {
        InModuleScope LunqDebloater -Parameters @{ Context = (New-TestContext) } {
            param($Context)
            $names = @(Get-LunqBuildSteps -Context $Context | Where-Object { $_.When } | ForEach-Object { $_.Name })
            $names | Should -Be @('Prepare', 'CopyIso', 'Export', 'Mount', 'Appx', 'Capabilities', 'Features', 'Registry', 'Save', 'Recompress', 'Iso')
        }
    }

    It 'пропуски профиля убирают его шаги' {
        InModuleScope LunqDebloater -Parameters @{ Context = (New-TestContext @{ SkipAppx = $true; SkipComponents = $true; SkipRegistry = $true }) } {
            param($Context)
            $names = @(Get-LunqBuildSteps -Context $Context | Where-Object { $_.When } | ForEach-Object { $_.Name })
            $names | Should -Be @('Prepare', 'CopyIso', 'Export', 'Mount', 'Save', 'Recompress', 'Iso')
        }
    }

    It 'всё включено: 18 шагов по порядку' {
        $all = New-TestContext @{
            Updates = @('u'); Drivers = @('d'); ServiceRecovery = $true; ServicePE = $true
            FirstLogon = [pscustomobject]@{ Apps = @('a'); Scripts = @() }; SetupAnswers = [pscustomobject]@{ Oobe = $true }; CleanupComponents = $true
        }
        InModuleScope LunqDebloater -Parameters @{ Context = $all } {
            param($Context)
            $names = @(Get-LunqBuildSteps -Context $Context | Where-Object { $_.When } | ForEach-Object { $_.Name })
            $names | Should -Be @('Prepare', 'CopyIso', 'Export', 'Mount', 'Updates', 'Drivers', 'Recovery', 'FirstLogon', 'Unattend',
                'Appx', 'Capabilities', 'Features', 'Registry', 'Cleanup', 'Save', 'Setup', 'Recompress', 'Iso')
        }
    }

    It 'шаг очистки сам по себе: неудача попадает в результат' {
        InModuleScope LunqDebloater -Parameters @{ Context = (New-TestContext @{ CleanupComponents = $true }) } {
            param($Context)
            Mock Invoke-LunqComponentCleanup { $false }
            $step = Get-LunqBuildSteps -Context $Context | Where-Object { $_.Name -eq 'Cleanup' }
            $result = & $step.Run $Context
            $result.Kind | Should -Be 'Cleanup'
            $result.Failed | Should -Contain 'StartComponentCleanup'
            $result.Summary | Should -BeLike '*не удалась*'
        }
    }

    It 'шаг монтирования отмечает образ в общем состоянии' {
        InModuleScope LunqDebloater -Parameters @{ Context = (New-TestContext) } {
            param($Context)
            Mock Mount-WindowsImage { }
            $step = Get-LunqBuildSteps -Context $Context | Where-Object { $_.Name -eq 'Mount' }
            & $step.Run $Context
            $Context.State.Mounted | Should -BeTrue
        }
    }
}

Describe 'Get-LunqOnlineSteps' {
    It '-Online: шаги профиля для этой Windows и запись данных для отката последней' {
        InModuleScope LunqDebloater {
            $names = { param($c) @(Get-LunqOnlineSteps -Context $c | Where-Object { $_.When } | ForEach-Object { $_.Name }) }
            & $names @{ SkipAppx = $false; SkipComponents = $false; SkipRegistry = $false; Config = $null; RestorePath = 'r.json' } | Should -Be @('Appx', 'Capabilities', 'Features', 'Registry', 'SaveRestore')
            & $names @{ SkipAppx = $true; SkipComponents = $true; SkipRegistry = $false; Config = $null; RestorePath = 'r.json' } | Should -Be @('Registry', 'SaveRestore')
            # Программы из Uninstall удаляются после реестра, до записи данных для отката.
            & $names @{ SkipAppx = $true; SkipComponents = $true; SkipRegistry = $true; Config = [pscustomobject]@{ Uninstall = @('MicrosoftEdge') }; RestorePath = 'r.json' } |
                Should -Be @('Uninstall', 'SaveRestore')
        }
    }

    It 'каждый шаг работает с этой Windows (-Online), а не с образом, и передаёт данные для отката' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Mock Write-Step { }
            Mock Remove-LunqAppx { }
            Mock Remove-LunqCapabilities { }
            Mock Disable-LunqFeatures { }
            Mock Remove-LunqPackages { }
            Mock Set-LunqRegistry { }
            Mock Save-LunqRestoreData { }
            $restore = New-LunqRestoreData -Source Online
            $context = @{ State = @{}; SkipAppx = $false; SkipComponents = $false; SkipRegistry = $false; Config = [pscustomobject]@{ Name = 'c' }; Restore = $restore; RestorePath = (Join-Path $Root 'Restore.json') }
            $null = Invoke-LunqBuild -Context $context -Online
            foreach ($name in 'Remove-LunqAppx', 'Remove-LunqCapabilities', 'Disable-LunqFeatures', 'Remove-LunqPackages', 'Set-LunqRegistry') {
                Should -Invoke $name -Times 1 -Exactly -ParameterFilter { $Online -and -not $MountPath -and $null -ne $Restore }
            }
            # Данные записываются после каждого из четырёх шагов и ещё раз в конце. Запись всегда
            # дописывает к файлу, а не заменяет то, что было до первого запуска.
            Should -Invoke Save-LunqRestoreData -Times 5 -Exactly -ParameterFilter { $Merge -and $Path -like '*Restore.json' }
            Should -Invoke Save-LunqRestoreData -Times 0 -Exactly -ParameterFilter { -not $Merge }
            $context.State.StepTimes.Count | Should -Be 5
        }
    }
}

Describe 'Get-LunqBuildStampValues' {
    It 'пропущенные шаги, установщик и программы первого входа' {
        $stamp = New-TestContext @{
            Profile = [pscustomobject]@{ Name = 'Default'; Categories = @([pscustomobject]@{ Id = 'apps'; Enabled = $true }, [pscustomobject]@{ Id = 'drivers'; Enabled = $false }) }
            SkipAppx = $true; SkipRegistry = $true; ServicePE = $true; Drivers = @('a.inf', 'b.inf')
            FirstLogon = [pscustomobject]@{ Apps = @('7zip.7zip', 'Mozilla.Firefox'); Scripts = @([pscustomobject]@{ Name = '10-hello.ps1' }) }
        }
        InModuleScope LunqDebloater -Parameters @{ Context = $stamp } {
            param($Context)
            $values = Get-LunqBuildStampValues -Context $Context
            $values.SourceIso | Should -Be 'Win11.iso'
            $values.Profile | Should -Be 'Default (Profile.json)'
            $values.Categories | Should -Be 'apps'
            $values.SkippedCategories | Should -Be 'drivers'
            $values.SkippedSteps | Should -Be 'Appx, Registry'
            $values.Drivers | Should -Be '2'
            $values.SetupAndWinRE | Should -Be 'да'
            $values.BootCA2023 | Should -Be 'нет'
            $values.SetupAnswerFile | Should -Be 'нет'
            $values.Apps | Should -Be '7zip.7zip, Mozilla.Firefox'
            $values.Scripts | Should -Be '10-hello.ps1'
        }
    }
}

Describe 'Invoke-LunqBuild' {
    It 'в итог попадают только результаты шагов, по порядку' {
        InModuleScope LunqDebloater {
            Mock Write-Host { }
            Mock Get-LunqBuildSteps {
                @(
                    @{ Name = 'A'; When = $true; Title = 'A'; Hint = ''; Run = { param($c) 'шум'; New-LunqResult 'Первый' 'Test' } },
                    @{ Name = 'B'; When = $false; Title = 'B'; Hint = ''; Run = { param($c) throw 'не должен выполняться' } },
                    @{ Name = 'C'; When = $true; Title = 'C'; Hint = ''; Run = { param($c) $c.State.Seen = $true; $null; New-LunqResult 'Второй' 'Test' } }
                )
            }
            $context = @{ State = @{} }
            $results = Invoke-LunqBuild -Context $context
            @($results | ForEach-Object { $_.Title }) | Should -Be @('Первый', 'Второй')
            $context.State.Seen | Should -BeTrue
            # Время записывается для выполненных шагов, чтобы итог показал самые долгие.
            @($context.State.StepTimes | ForEach-Object { $_.Title }) | Should -Be @('A', 'C')
            $context.State.StepTimes[0].Elapsed | Should -BeOfType [TimeSpan]
        }
    }

    It 'перед каждым шагом в лог DISM пишется метка' {
        InModuleScope LunqDebloater {
            Mock Write-Host { }
            Mock Get-LunqBuildSteps {
                @(
                    @{ Name = 'Updates'; When = $true; Title = 'A'; Hint = ''; Run = { param($c) } },
                    @{ Name = 'Iso'; When = $true; Title = 'B'; Hint = ''; Run = { param($c) } }
                )
            }
            $old = $script:DismLogPath
            $script:DismLogPath = Join-Path $TestDrive 'dism.log'
            try { Invoke-LunqBuild -Context @{ State = @{} } | Out-Null }
            finally { $log = $script:DismLogPath; $script:DismLogPath = $old }
            $text = Get-Content -LiteralPath $log -Raw
            $text | Should -Match '===== LunqDebloater \d{4}-\d\d-\d\d \d\d:\d\d:\d\d: step 1/2: Updates ====='
            $text | Should -Match 'step 2/2: Iso'
        }
    }
}

Describe 'Invoke-LunqBuild -Online' {
    It 'данные для отката записываются после каждого шага, и после упавшего тоже' {
        $path = Join-Path $TestDrive 'online\Restore.json'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; Context = (New-TestContext -Values @{ RestorePath = $path }) } {
            param($Path, $Context)
            Mock Write-Step { }
            $Context.Restore = New-LunqRestoreData -LunqProfile ([pscustomobject]@{ Name = 'Test'; Categories = @() }) -Source Online
            Mock Get-LunqOnlineSteps {
                @(
                    @{ Name = 'Appx'; When = $true; Title = 'Appx'; Hint = ''; Run = { param($c) Add-LunqRestoreItem -Restore $c.Restore -Kind Appx -Name 'Microsoft.BingNews' } },
                    @{ Name = 'Features'; When = $true; Title = 'Features'; Hint = ''; Run = { param($c) Add-LunqRestoreItem -Restore $c.Restore -Kind Features -Name 'Recall'; throw 'step failed' } },
                    @{ Name = 'SaveRestore'; When = $true; Title = 'Save'; Hint = ''; Run = { throw 'не должен выполняться' } })
            }
            { Invoke-LunqBuild -Context $Context -Online } | Should -Throw '*step failed*'
            # Удалённое до ошибки и на упавшем шаге можно вернуть через -Restore.
            $saved = Read-LunqRestoreData -Path $Path
            @($saved.Categories[0].Appx | ForEach-Object { $_.Name }) | Should -Be @('Microsoft.BingNews')
            @($saved.Categories[0].Features | ForEach-Object { $_.Name }) | Should -Be @('Recall')
        }
    }
}
