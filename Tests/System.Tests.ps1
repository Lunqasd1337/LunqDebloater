#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Исключение рабочей папки из проверки Microsoft Defender (Private\System.ps1, -DefenderExclusion).

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

Describe 'Исключение Microsoft Defender' {
    BeforeEach {
        $script:Record = Join-Path $TestDrive ('defender\' + [guid]::NewGuid().ToString('N') + '.txt')
    }

    It 'добавляет исключение и запись о нём, а в конце убирает и то и другое' {
        InModuleScope LunqDebloater -Parameters @{ Record = $script:Record } {
            Mock Get-LunqDefenderExclusions { , @('C:\Other') }
            Mock Set-LunqDefenderExclusion { }
            Mock Write-Info { }
            Add-LunqDefenderExclusion -Path 'C:\LunqWork' -RecordPath $Record | Should -BeTrue
            Should -Invoke Set-LunqDefenderExclusion -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\LunqWork' -and -not $Remove }
            (Get-Content -LiteralPath $Record -Encoding UTF8) | Should -Be 'C:\LunqWork'
            Remove-LunqDefenderExclusion -RecordPath $Record
            Should -Invoke Set-LunqDefenderExclusion -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\LunqWork' -and $Remove }
            Test-Path -LiteralPath $Record | Should -BeFalse
        }
    }

    It 'папку, исключённую до запуска, не трогает и в конце не возвращает' {
        InModuleScope LunqDebloater -Parameters @{ Record = $script:Record } {
            Mock Get-LunqDefenderExclusions { , @('c:\lunqwork\') }
            Mock Set-LunqDefenderExclusion { }
            Add-LunqDefenderExclusion -Path 'C:\LunqWork' -RecordPath $Record | Should -BeFalse
            Should -Invoke Set-LunqDefenderExclusion -Times 0
            Test-Path -LiteralPath $Record | Should -BeFalse
        }
    }

    It 'исключение не добавилось: предупреждение, записи нет, сборка идёт дальше' {
        InModuleScope LunqDebloater -Parameters @{ Record = $script:Record } {
            Mock Get-LunqDefenderExclusions { , @() }
            Mock Set-LunqDefenderExclusion { throw 'Отказано в доступе' }
            Mock Write-Warning { }
            Add-LunqDefenderExclusion -Path 'C:\LunqWork' -RecordPath $Record | Should -BeFalse
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*сборка пойдёт медленнее: Отказано в доступе' }
            Test-Path -LiteralPath $Record | Should -BeFalse
        }
    }

    It 'исключение не убралось: предупреждение с командой, запись остаётся для следующего запуска' {
        InModuleScope LunqDebloater -Parameters @{ Record = $script:Record } {
            New-Item -ItemType Directory -Path (Split-Path $Record -Parent) -Force | Out-Null
            Set-Content -LiteralPath $Record -Value 'C:\LunqWork' -Encoding UTF8
            Mock Set-LunqDefenderExclusion { throw 'Отказано в доступе' }
            Mock Write-Warning { }
            Remove-LunqDefenderExclusion -RecordPath $Record
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like "*Remove-MpPreference -ExclusionPath 'C:\LunqWork'*" }
            Test-Path -LiteralPath $Record | Should -BeTrue
        }
    }
}
