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
            State = @{ Mounted = $false; WorkDirOwned = $false; ImageInfo = $null }
            WorkDir = 'work'; MountPaths = @(); MountDir = 'mount'; BootMountDir = 'bootmount'; ReMountDir = 'remount'
            IsoPath = 'C:\iso\Win11.iso'; IsoDir = 'iso'; WimPath = 'install.wim'; Index = 1; OutputIso = 'out.iso'; Oscdimg = 'oscdimg.exe'; Label = 'LUNQ_WIN11'
            Updates = @(); SafeOSUpdates = @(); SetupUpdates = @(); PEUpdates = @(); Drivers = @(); PEDrivers = @(); DriversPath = $null
            ServiceRecovery = $false; ServicePE = $false; FirstLogon = $null; SetupAnswers = $null; Architecture = 'amd64'; Config = $null
            SkipAppx = $false; SkipComponents = $false; SkipRegistry = $false; CleanupComponents = $false
            Profile = $null; ProfilePath = 'C:\Config\Profile.json'; EditionName = 'Windows 11 Pro'; BuildText = '26300.9457'
        }
        foreach ($key in $Values.Keys) { $context[$key] = $Values[$key] }
        return $context
    }
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
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
        }
    }
}
