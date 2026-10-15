#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Удаление из образа (Private\Removal.ps1). Командлеты DISM подменяет Tests\Mocks\Dism.

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

Describe 'Remove-LunqPackages' {
    It 'удаляет только установленные пакеты по шаблонам, а ошибку и ненайденный шаблон показывает в итоге' {
        InModuleScope LunqDebloater {
            Mock Write-Warning { }
            Mock Write-Info { }
            $config = [pscustomobject]@{ Packages = [pscustomobject]@{ Remove = @('Microsoft-Windows-MediaPlayer-Package*', 'Microsoft-Windows-Broken-Package*', 'Microsoft-Windows-Nothing-Package*') } }
            $result = Remove-LunqPackages -MountPath 'mount' -Config $config
            # Staged-пакет wow64 не установлен и не удаляется, Foundation не подходит под шаблоны.
            @($result.Done) | Should -Be @('Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35~amd64~~10.0.26300.1')
            @($result.Failed) | Should -Be @('Microsoft-Windows-Broken-Package~31bf3856ad364e35~amd64~~10.0.26300.1')
            @($result.NotMatched) | Should -Be @('Microsoft-Windows-Nothing-Package*')
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*системных пакетов*' }
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Microsoft-Windows-Broken-Package*' }
        }
    }

    It 'без шаблонов в профиле ничего не трогает' {
        InModuleScope LunqDebloater {
            Mock Get-WindowsPackage { throw 'must not be called' }
            Remove-LunqPackages -MountPath 'mount' -Config ([pscustomobject]@{ Packages = [pscustomobject]@{ Remove = @() } }) | Should -BeNullOrEmpty
        }
    }
}
