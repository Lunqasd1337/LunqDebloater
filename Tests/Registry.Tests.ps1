#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Запись в настоящий реестр через .NET: только на Windows, во временный ключ HKCU\Software.
# На сборке те же функции пишут в загруженные кусты образа (HKLM\LUNQ_*).

BeforeDiscovery {
    $script:OnWindows = $env:OS -eq 'Windows_NT'
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    $script:TestKey = 'Software\LunqDebloaterTests_' + [guid]::NewGuid().ToString('N')
    $script:Root = "HKCU\$script:TestKey"
    function Invoke-InModule([scriptblock]$Block, [object[]]$Arguments) { & (Get-Module LunqDebloater) $Block @Arguments }
}

AfterAll {
    if ($env:OS -eq 'Windows_NT') { Remove-Item -LiteralPath "HKCU:\$script:TestKey" -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module LunqDebloater -Force -ErrorAction SilentlyContinue
}

Describe 'Запись в реестр' -Skip:(-not $script:OnWindows) {
    It 'типы значений записываются как в профиле' {
        $entries = @(
            @{ Name = 'Sz'; Type = 'REG_SZ'; Value = '"C:\Program Files\App\app.exe" /min C:\Temp\' },
            @{ Name = 'Expand'; Type = 'REG_EXPAND_SZ'; Value = '%SystemRoot%\x' },
            @{ Name = 'Multi'; Type = 'REG_MULTI_SZ'; Value = @('a', 'b') },
            @{ Name = 'Dword'; Type = 'REG_DWORD'; Value = 4294967295 },
            @{ Name = 'Qword'; Type = 'REG_QWORD'; Value = '0x10' },
            @{ Name = 'Binary'; Type = 'REG_BINARY'; Value = 'de ad be ef' },
            @{ Name = ''; Type = 'REG_SZ'; Value = 'по умолчанию' }
        )
        foreach ($e in $entries) {
            Invoke-InModule {
                param($Key, $Entry)
                $value = ConvertTo-LunqRegValue -Type $Entry.Type -Value $Entry.Value
                Set-LunqRegistryValue -Key "$Key\Sub" -Name $Entry.Name -Kind $value.Kind -Data $value.Data
            } @($script:Root, $e)
        }
        $key = Get-Item -LiteralPath "HKCU:\$script:TestKey\Sub"
        $key.GetValue('Sz') | Should -BeExactly '"C:\Program Files\App\app.exe" /min C:\Temp\'
        $key.GetValueKind('Expand') | Should -Be 'ExpandString'
        $key.GetValue('Expand', $null, 'DoNotExpandEnvironmentNames') | Should -Be '%SystemRoot%\x'
        $key.GetValue('Multi') | Should -Be @('a', 'b')
        $key.GetValue('Dword') | Should -Be -1
        $key.GetValueKind('Dword') | Should -Be 'DWord'
        $key.GetValue('Qword') | Should -Be 16
        $key.GetValue('Binary') | Should -Be ([byte[]](0xDE, 0xAD, 0xBE, 0xEF))
        $key.GetValue('') | Should -Be 'по умолчанию'
        $key.Close()
    }

    It 'удаление значения и ключа, повторное удаление ничего не находит' {
        Invoke-InModule { param($Key) Set-LunqRegistryValue -Key "$Key\Del\Child" -Name 'v' -Kind 'DWord' -Data 1 } @($script:Root)
        Invoke-InModule { param($Key) Remove-LunqRegistryValue -Key "$Key\Del\Child" -Name 'v' } @($script:Root) | Should -BeTrue
        Invoke-InModule { param($Key) Remove-LunqRegistryValue -Key "$Key\Del\Child" -Name 'v' } @($script:Root) | Should -BeFalse
        Invoke-InModule { param($Key) Remove-LunqRegistryKey -Key "$Key\Del" } @($script:Root) | Should -BeTrue
        Test-Path -LiteralPath "HKCU:\$script:TestKey\Del" | Should -BeFalse
        Invoke-InModule { param($Key) Remove-LunqRegistryKey -Key "$Key\Del" } @($script:Root) | Should -BeFalse
        Invoke-InModule { param($Key) Remove-LunqRegistryValue -Key "$Key\Missing" -Name 'v' } @($script:Root) | Should -BeFalse
    }
}
