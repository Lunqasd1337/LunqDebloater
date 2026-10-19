#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Вывод и вопросы в консоли (Private\Console.ps1).

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

Describe 'Read-YesNo' {
    It 'да на обоих языках в любом регистре, всё остальное нет' {
        InModuleScope LunqDebloater {
            Mock Read-Host { $global:LunqYesNoAnswer }
            foreach ($answer in 'y', 'YES', 'Д', ' да ') {
                $global:LunqYesNoAnswer = $answer
                Read-YesNo 'Продолжить?' | Should -BeTrue -Because $answer
            }
            foreach ($answer in 'n', '', 'нет', '1') {
                $global:LunqYesNoAnswer = $answer
                Read-YesNo 'Продолжить?' | Should -BeFalse -Because $answer
            }
            Remove-Variable -Name LunqYesNoAnswer -Scope Global
        }
    }

    It 'закрытый ввод ($null вместо строки) означает нет, а не ошибку' {
        InModuleScope LunqDebloater {
            Mock Read-Host { $null }
            Read-YesNo 'Продолжить?' | Should -BeFalse
        }
    }
}
