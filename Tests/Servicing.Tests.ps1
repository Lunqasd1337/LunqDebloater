#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Обновления и драйверы (Private\Servicing.ps1): порядок, отбор для установщика и WinRE.

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

Describe 'Обновления и драйверы' {
    It 'обновления сортируются по номеру KB' {
        $dir = Join-Path $TestDrive 'upd'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($name in 'windows11.0-kb5080000-x64.msu', 'windows11.0-kb5079999-x64.msu', 'readme.txt') { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        @($files | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb5079999-x64.msu', 'windows11.0-kb5080000-x64.msu')
    }

    It 'пакет для другого образа (0x800f081e) пропускается, а не считается ошибкой' {
        $dir = Join-Path $TestDrive 'na'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($name in 'windows11.0-kb1-x64.msu', 'windows11.0-kb2-x64_notapplicable.cab', 'windows11.0-kb3-x64-broken.msu') { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        $output = & { $script:r = Add-LunqUpdates -MountPath $dir -Files $files -ScratchDir (Join-Path $TestDrive 'scratch') } *>&1 | Out-String
        $script:r.Done | Should -Be @('windows11.0-kb1-x64.msu')
        $script:r.Skipped | Should -Be @('windows11.0-kb2-x64_notapplicable.cab')
        $script:r.Failed | Should -Be @('windows11.0-kb3-x64-broken.msu')
        $output | Should -Match 'windows11\.0-kb2-x64_notapplicable\.cab не подходит к этому образу, пропускаю'
        $output | Should -Match 'подпапку SafeOS или Setup'
        # Предупреждение командлета не дублирует сообщение скрипта.
        $output | Should -Not -Match 'Не удалось добавить пакет'
        $report = Write-LunqReport -Results @($script:r) 6>&1 | Out-String
        $report | Should -Match 'Обновления: установлено 1, ошибок 1'
        $report | Should -Match 'Не подходят к этому образу: windows11\.0-kb2-x64_notapplicable\.cab'
    }

    It 'в установщик и WinRE идут только обновления самой Windows' {
        $files = @('windows11.0-kb1-x64.msu', 'windows11.0-kb2-x64-ndp481.msu', 'office-kb3.cab') | ForEach-Object { [pscustomobject]@{ Name = $_ } }
        @(Select-LunqPEUpdates $files | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb1-x64.msu')
        Test-CumulativeUpdate $files | Should -BeTrue
        Test-CumulativeUpdate @([pscustomobject]@{ Name = 'office-kb3.cab' }) | Should -BeFalse
        # Обновление .NET не заменяет накопительное обновление Windows.
        Test-CumulativeUpdate @([pscustomobject]@{ Name = 'windows11.0-kb2-x64-ndp481.msu' }) | Should -BeFalse
    }

    It 'в установщик и WinRE идут только драйверы контроллеров дисков, в том числе .inf в UTF-16' {
        $dir = Join-Path $TestDrive 'drv'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'net.inf') -Value "[Version]`r`nClass=Net"
        Set-Content -LiteralPath (Join-Path $dir 'rst.inf') -Value "[Version]`r`nClass = SCSIAdapter"
        [IO.File]::WriteAllText((Join-Path $dir 'hdc.inf'), "[Version]`r`nClass=""HDC""", [Text.Encoding]::Unicode)
        Set-Content -LiteralPath (Join-Path $dir 'autorun.inf') -Value '[autorun]'
        $infs = Get-LunqDriverFiles -Path $dir
        $infs.Count | Should -Be 3
        @(Select-LunqPEDrivers $infs | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('hdc.inf', 'rst.inf')
    }
}
