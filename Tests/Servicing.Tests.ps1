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

    It 'языковые пакеты идут до накопительных обновлений, а .NET после них' {
        $dir = Join-Path $TestDrive 'order'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $names = 'windows11.0-kb5080002-x64-ndp481.msu', 'windows11.0-kb5080000-x64.msu', 'Microsoft-Windows-Client-Language-Pack_x64_ru-ru.cab',
        'windows11.0-kb5079999-x64-ndp481.msu', 'Microsoft-Windows-LanguageFeatures-Basic-ru-ru-Package~31bf3856ad364e35~amd64~~.cab', 'windows11.0-kb5080001-x64.msu'
        foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        @(Get-LunqUpdateFiles -Path $dir | ForEach-Object { $_.Name }) | Should -Be @(
            'Microsoft-Windows-Client-Language-Pack_x64_ru-ru.cab', 'Microsoft-Windows-LanguageFeatures-Basic-ru-ru-Package~31bf3856ad364e35~amd64~~.cab',
            'windows11.0-kb5080000-x64.msu', 'windows11.0-kb5080001-x64.msu',
            'windows11.0-kb5079999-x64-ndp481.msu', 'windows11.0-kb5080002-x64-ndp481.msu')
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

    It 'Safe OS и Setup Dynamic Update узнаются по содержимому .cab' {
        # expand.exe заменён: что лежит в .cab, задаёт текст файла.
        Mock Invoke-Native -ModuleName LunqDebloater {
            $text = Get-Content -LiteralPath $Arguments[0] -Raw
            if ($text -match 'safeos') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'update.mum') -Value '<assemblyIdentity name="Package_for_SafeOSDU" />' }
            elseif ($text -match 'rollup') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'update.mum') -Value '<assemblyIdentity name="Package_for_RollupFix" />' }
            return 0
        }
        $dir = Join-Path $TestDrive 'du'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb1-x64.msu') -Value 'MSCF msu'
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb2-x64.cab') -Value 'MSCF rollup'
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb3-x64_0123456789abcdef0123456789abcdef01234567.cab') -Value 'MSCF safeos'
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb4-x64_0123456789abcdef0123456789abcdef01234567.cab') -Value 'MSCF setup files'
        # Не архив CAB: распаковка не запускается, файл считается обычным обновлением.
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb5-x64.cab') -Value 'not a cab'

        $cache = @{}
        $split = Split-LunqDynamicUpdates -Files (Get-LunqUpdateFiles -Path $dir) -TempDir (Join-Path $TestDrive 'check') -Cache $cache 6>$null
        @($split.Updates | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb1-x64.msu', 'windows11.0-kb2-x64.cab', 'windows11.0-kb5-x64.cab')
        @($split.SafeOS | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb3-x64_0123456789abcdef0123456789abcdef01234567.cab')
        @($split.Setup | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb4-x64_0123456789abcdef0123456789abcdef01234567.cab')
        Should -Invoke Invoke-Native -ModuleName LunqDebloater -Times 3 -Exactly
        # Распознанные файлы не распаковываются снова, когда сводка показывается ещё раз.
        Split-LunqDynamicUpdates -Files (Get-LunqUpdateFiles -Path $dir) -TempDir (Join-Path $TestDrive 'check') -Cache $cache 6>$null | Out-Null
        Should -Invoke Invoke-Native -ModuleName LunqDebloater -Times 3 -Exactly
        # Временные папки проверки удаляются.
        @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'check')).Count | Should -Be 0
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

    It 'с кэшем каждый .inf читается один раз' {
        $dir = Join-Path $TestDrive 'pecache'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'rst.inf') -Value "[Version]`r`nClass = SCSIAdapter"
        Set-Content -LiteralPath (Join-Path $dir 'net.inf') -Value "[Version]`r`nClass = Net"
        $infs = Get-LunqDriverFiles -Path $dir
        $cache = @{}
        (Select-LunqPEDrivers $infs -Cache $cache).Count | Should -Be 1
        $cache.Count | Should -Be 2
        # Повторный вызов берёт ответ из кэша, а заменённый файл читается заново.
        foreach ($key in @($cache.Keys)) { if ($key -like '*rst.inf|*') { $cache[$key] = $false } }
        (Select-LunqPEDrivers $infs -Cache $cache).Count | Should -Be 0
        Set-Content -LiteralPath (Join-Path $dir 'net.inf') -Value "[Version]`r`nClass = HDC"
        (Get-Item -LiteralPath (Join-Path $dir 'net.inf')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(1)
        @(Select-LunqPEDrivers (Get-LunqDriverFiles -Path $dir) -Cache $cache | ForEach-Object { $_.Name }) | Should -Be @('net.inf')
    }
}
