#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Уборка заданий и копий ежемесячной пересборки прошлых версий (Private\Schedule.ps1).

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

Describe 'Remove-LunqScheduleLeftovers' {
    BeforeEach {
        InModuleScope LunqDebloater {
            $script:InfoLines = New-Object System.Collections.Generic.List[string]
            Mock Write-Info { $script:InfoLines.Add($Message) }
            Mock Write-Warning { }
            Mock Remove-LunqScheduleTaskFolder { }
            Mock Get-LunqScheduleRoot { Join-Path $TestDrive 'ProgramFiles\LunqDebloater-Schedule' }
            Mock Get-LunqScheduleTasks { return , @() }
            $script:SchtasksCalls = New-Object System.Collections.Generic.List[object]
            $script:SchtasksCode = 0
            Mock Invoke-Native {
                $script:SchtasksCalls.Add(@($Arguments))
                return $script:SchtasksCode
            } -ParameterFilter { $FilePath -eq 'schtasks.exe' }
        }
    }

    It 'без заданий и копий ничего не пишет и не вызывает schtasks' {
        InModuleScope LunqDebloater {
            Remove-LunqScheduleLeftovers
            $script:InfoLines.Count | Should -Be 0
            $script:SchtasksCalls.Count | Should -Be 0
            Should -Invoke Remove-LunqScheduleTaskFolder -Times 0
        }
    }

    It 'удаляет каждое задание, папку в планировщике и копии программы' {
        InModuleScope LunqDebloater {
            $root = Get-LunqScheduleRoot
            New-Item -ItemType Directory -Path (Join-Path $root 'Win11_Lunq-1a2b3c4d') -Force | Out-Null
            Mock Get-LunqScheduleTasks { return , @('LunqDebloater\Win11_Lunq-1a2b3c4d', 'LunqDebloater\Win11_Lunq') }
            Remove-LunqScheduleLeftovers
            $script:SchtasksCalls.Count | Should -Be 2
            ($script:SchtasksCalls[0] -join ' ') | Should -Be '/Delete /TN LunqDebloater\Win11_Lunq-1a2b3c4d /F'
            ($script:SchtasksCalls[1] -join ' ') | Should -Be '/Delete /TN LunqDebloater\Win11_Lunq /F'
            Should -Invoke Remove-LunqScheduleTaskFolder -Times 1 -Exactly
            Test-Path -LiteralPath $root | Should -BeFalse
            $script:InfoLines[0] | Should -Match 'Ежемесячная пересборка убрана'
            ($script:InfoLines -join "`n") | Should -Match 'Задание LunqDebloater\\Win11_Lunq удалено'
            ($script:InfoLines -join "`n") | Should -Match 'Копии программы для заданий удалены'
            Should -Invoke Write-Warning -Times 0
        }
    }

    It 'одни копии без заданий удаляются без вызова schtasks' {
        InModuleScope LunqDebloater {
            $root = Get-LunqScheduleRoot
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Remove-LunqScheduleLeftovers
            $script:SchtasksCalls.Count | Should -Be 0
            Should -Invoke Remove-LunqScheduleTaskFolder -Times 0
            Test-Path -LiteralPath $root | Should -BeFalse
        }
    }

    It 'неудача schtasks только предупреждает, и уборка идёт дальше' {
        InModuleScope LunqDebloater {
            $root = Get-LunqScheduleRoot
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Mock Get-LunqScheduleTasks { return , @('LunqDebloater\A-00000000', 'LunqDebloater\B-11111111') }
            $script:SchtasksCode = 1
            { Remove-LunqScheduleLeftovers } | Should -Not -Throw
            $script:SchtasksCalls.Count | Should -Be 2
            Should -Invoke Write-Warning -Times 2 -Exactly -ParameterFilter { $Message -match 'код 1' -and $Message -match 'планировщике заданий' }
            Test-Path -LiteralPath $root | Should -BeFalse
        }
    }

    It 'копии, которые не удалось удалить, дают предупреждение, а не ошибку' {
        InModuleScope LunqDebloater {
            $root = Get-LunqScheduleRoot
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Mock Remove-Item { throw 'занято' } -ParameterFilter { $LiteralPath -eq $root }
            { Remove-LunqScheduleLeftovers } | Should -Not -Throw
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -match 'занято' }
        }
    }
}
