#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Сводка «Что войдёт в образ» (Private\Options.ps1): зависимость пунктов от родителя и переключение по номерам.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Test-LunqOption' {
    It 'пункт включён, только если включены и доступны он сам и его родитель' {
        InModuleScope LunqDebloater {
            $options = @(
                (New-LunqOption -Key 'updates' -Name 'u'),
                (New-LunqOption -Key 'cleanup' -Name 'c' -Parent 'updates'),
                (New-LunqOption -Key 'drivers' -Name 'd' -Available $false),
                (New-LunqOption -Key 'driversToSetup' -Name 'ds' -Parent 'drivers'))
            Test-LunqOption -Options $options -Key 'cleanup' | Should -BeTrue
            Test-LunqOption -Options $options -Key 'driversToSetup' | Should -BeFalse
            Test-LunqOption -Options $options -Key 'missing' | Should -BeFalse
            $options[0].Enabled = $false
            Test-LunqOption -Options $options -Key 'cleanup' | Should -BeFalse
        }
    }

    It 'пункту с несколькими родителями хватает любого включённого' {
        InModuleScope LunqDebloater {
            $options = @(
                (New-LunqOption -Key 'updates' -Name 'u' -Available $false),
                (New-LunqOption -Key 'download' -Name 'd' -Enabled $false),
                (New-LunqOption -Key 'cleanup' -Name 'c' -Parent 'updates', 'download'))
            Test-LunqOption -Options $options -Key 'cleanup' | Should -BeFalse
            $options[1].Enabled = $true
            Test-LunqOption -Options $options -Key 'cleanup' | Should -BeTrue
            $options[0].Available = $true
            $options[1].Enabled = $false
            Test-LunqOption -Options $options -Key 'cleanup' | Should -BeTrue
        }
    }
}

Describe 'Select-LunqBuildOptions' {
    BeforeEach {
        $global:LunqOptionAnswers = New-Object System.Collections.Generic.Queue[string]
    }

    AfterEach {
        Remove-Variable -Name LunqOptionAnswers -Scope Global -ErrorAction SilentlyContinue
    }

    It 'номера переключают пункты, а действие возвращается после остальных номеров ответа' {
        InModuleScope LunqDebloater {
            Mock Write-Host { }
            Mock Write-Info { }
            Mock Read-Host { $global:LunqOptionAnswers.Dequeue() }
            $options = @(
                (New-LunqOption -Key 'updates' -Name 'u'),
                (New-LunqOption -Key 'cleanup' -Name 'c' -Parent 'updates' -Enabled $false),
                (New-LunqOption -Key 'pick' -Name 'p' -Action),
                (New-LunqOption -Key 'drivers' -Name 'd' -Available $false))
            # Недоступный пункт без номера: 1 updates, 2 cleanup, 3 pick.
            $global:LunqOptionAnswers.Enqueue('3, 2')
            Select-LunqBuildOptions -Options $options | Should -Be 'pick'
            $options[1].Enabled | Should -BeTrue
        }
    }

    It 'пункт с выключенным родителем не переключается, неверный номер предупреждает, Enter завершает' {
        InModuleScope LunqDebloater {
            Mock Write-Host { }
            Mock Write-Info { }
            Mock Write-Warning { }
            Mock Read-Host { $global:LunqOptionAnswers.Dequeue() }
            $options = @(
                (New-LunqOption -Key 'updates' -Name 'u' -Enabled $false),
                (New-LunqOption -Key 'cleanup' -Name 'c' -Parent 'updates' -Enabled $false))
            $global:LunqOptionAnswers.Enqueue('2 9')
            $global:LunqOptionAnswers.Enqueue('')
            Select-LunqBuildOptions -Options $options | Should -BeNullOrEmpty
            $options[1].Enabled | Should -BeFalse
            Should -Invoke Write-Warning -Times 2 -Exactly
        }
    }

    It 'пункт с несколькими выключенными родителями называет их номера' {
        InModuleScope LunqDebloater {
            Mock Write-Host { }
            Mock Write-Info { }
            Mock Write-Warning { }
            Mock Read-Host { $global:LunqOptionAnswers.Dequeue() }
            $options = @(
                (New-LunqOption -Key 'updates' -Name 'u' -Enabled $false),
                (New-LunqOption -Key 'download' -Name 'd' -Enabled $false),
                (New-LunqOption -Key 'cleanup' -Name 'c' -Parent 'updates', 'download' -Enabled $false))
            $global:LunqOptionAnswers.Enqueue('3')
            $global:LunqOptionAnswers.Enqueue('2 3')
            $global:LunqOptionAnswers.Enqueue('')
            Select-LunqBuildOptions -Options $options | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -eq 'Пункт 3 работает только вместе с одним из пунктов 1, 2. Сначала включите какой-нибудь из них.' }
            Test-LunqOption -Options $options -Key 'cleanup' | Should -BeTrue
        }
    }
}
