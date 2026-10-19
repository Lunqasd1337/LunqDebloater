#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Обновления и драйверы (Private\Servicing.ps1): порядок, отбор для установщика и WinRE.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru

    # Внутренние функции модуля под теми же именами: снаружи модуля они не видны.
    function Get-LunqUpdateFiles { param($Path) & (Get-Module LunqDebloater) { param($p) Get-LunqUpdateFiles -Path $p } $Path }
    function Get-LunqDriverFiles { param($Path) & (Get-Module LunqDebloater) { param($p) Get-LunqDriverFiles -Path $p } $Path }
    function Split-LunqDynamicUpdates {
        param($Files, $TempDir, $Cache)
        & (Get-Module LunqDebloater) { param($f, $t, $c) Split-LunqDynamicUpdates -Files $f -TempDir $t -Cache $c } $Files $TempDir $Cache
    }
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
        foreach ($name in 'windows11.0-kb1-x64.msu', 'windows11.0-kb2-x64_notapplicable.cab', 'windows11.0-kb3-x64-broken.cab') { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        $scratch = Join-Path $TestDrive 'scratch'
        $output = & { $script:r = & (Get-Module LunqDebloater) { param($d, $f, $s) Add-LunqUpdates -MountPath $d -Files $f -ScratchDir $s } $dir $files $scratch } *>&1 | Out-String
        $script:r.Done | Should -Be @('windows11.0-kb1-x64.msu')
        $script:r.Skipped | Should -Be @('windows11.0-kb2-x64_notapplicable.cab')
        $script:r.Failed | Should -Be @('windows11.0-kb3-x64-broken.cab')
        $output | Should -Match 'windows11\.0-kb2-x64_notapplicable\.cab не подходит к этому образу, пропускаю'
        $output | Should -Match 'подпапку SafeOS или Setup'
        # Предупреждение командлета не дублирует сообщение скрипта.
        $output | Should -Not -Match 'Не удалось добавить пакет'
        $report = Write-LunqReport -Results @($script:r) 6>&1 | Out-String
        $report | Should -Match 'Обновления: установлено 1, ошибок 1'
        $report | Should -Match 'Не подходят к этому образу: windows11\.0-kb2-x64_notapplicable\.cab'
    }

    It 'контрольное и целевое накопительные обновления ставятся одним вызовом DISM из отдельной папки' {
        # В 24H2 каталог отдаёт к накопительному обновлению ещё и контрольное KB5043080: отдельно
        # оно не ставится («An error occurred applying the Unattend.xml file from the .msu package»).
        $dir = Join-Path $TestDrive 'checkpoint'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $names = 'windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu', 'windows11.0-kb5090000-x64_aabbccddeeff00112233445566778899aabbccdd.msu', 'windows11.0-kb5090001-x64-ndp481.msu'
        foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        $script:DismCalls = New-Object System.Collections.Generic.List[object]
        Mock Invoke-Native -ModuleName LunqDebloater {
            $package = (@($Arguments | Where-Object { $_ -like '/PackagePath:*' }) -replace '^/PackagePath:', '')[0]
            $script:DismCalls.Add([pscustomobject]@{ Arguments = @($Arguments); Folder = @(Get-ChildItem -LiteralPath (Split-Path $package -Parent) | ForEach-Object { $_.Name } | Sort-Object) })
            return 0
        } -ParameterFilter { $FilePath -eq 'dism.exe' }
        $work = Join-Path $TestDrive 'cpwork'
        # Без -Width консоль Windows переносит длинные строки, и проверка текста не находит его.
        $output = & { $script:r = & (Get-Module LunqDebloater) { param($f, $s) Add-LunqUpdates -MountPath 'mount' -Files $f -ScratchDir $s } $files (Join-Path $work 'scratch') } *>&1 | Out-String -Width 400
        $script:DismCalls.Count | Should -Be 1
        $call = $script:DismCalls[0]
        $call.Arguments | Should -Contain '/Add-Package'
        @($call.Arguments | Where-Object { $_ -like '/PackagePath:*' })[0] | Should -Match 'kb5090000-x64_aabb.*\.msu$'
        # В папке только накопительные обновления Windows, без .NET.
        $call.Folder | Should -Be @($names[0], $names[1])
        $script:r.Done | Should -Be @($names[0], $names[1], $names[2])
        $output | Should -Match 'kb5043080.* ставится вместе с windows11\.0-kb5090000'
        $output | Should -Match 'add package windows11\.0-kb5090001-x64-ndp481\.msu'
        # Папка для DISM убрана, исходные файлы на месте.
        Test-Path -LiteralPath (Join-Path $work 'cumulative') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 3
    }

    It 'пакет включения не входит в группу накопительных и ставится отдельно, после них' {
        # Раньше пакет включения 25H2 попадал в папку целевого обновления, DISM его не брал,
        # а итог писал, что он встроен.
        $dir = Join-Path $TestDrive 'enablement'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $names = 'windows11.0-kb5043080-x64.msu', 'windows11.0-kb5054156-x64.msu', 'windows11.0-kb5090000-x64.msu', 'windows11.0-kb5090001-x64-ndp481.msu'
        foreach ($name in $names) { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        @($files | ForEach-Object { $_.Name }) | Should -Be @($names[0], $names[2], $names[1], $names[3])
        $script:DismCalls = New-Object System.Collections.Generic.List[object]
        Mock Invoke-Native -ModuleName LunqDebloater {
            $package = (@($Arguments | Where-Object { $_ -like '/PackagePath:*' }) -replace '^/PackagePath:', '')[0]
            $script:DismCalls.Add(@(Get-ChildItem -LiteralPath (Split-Path $package -Parent) | ForEach-Object { $_.Name } | Sort-Object))
            return 0
        } -ParameterFilter { $FilePath -eq 'dism.exe' }
        $output = & { $script:r = & (Get-Module LunqDebloater) { param($f, $s) Add-LunqUpdates -MountPath 'mount' -Files $f -ScratchDir $s } $files (Join-Path $TestDrive 'ekbwork\scratch') } *>&1 | Out-String -Width 400
        $script:DismCalls.Count | Should -Be 1
        $script:DismCalls[0] | Should -Be @($names[0], $names[2])
        $script:r.Done | Should -Be @($names[0], $names[2], $names[1], $names[3])
        $output | Should -Match 'add package windows11\.0-kb5054156-x64\.msu'
        $output | Should -Not -Match 'kb5054156.* ставится вместе с'
    }

    It 'DISM не поставил накопительные обновления: ошибка с кодом по каждому из них' {
        $dir = Join-Path $TestDrive 'checkpoint2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($name in 'windows11.0-kb5043080-x64.msu', 'windows11.0-kb5090000-x64.msu') { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        Mock Invoke-Native -ModuleName LunqDebloater { return -2146498529 } -ParameterFilter { $FilePath -eq 'dism.exe' }
        $output = & { $script:r = & (Get-Module LunqDebloater) { param($f, $s) Add-LunqUpdates -MountPath 'mount' -Files $f -ScratchDir $s } $files (Join-Path $TestDrive 'cpwork2\scratch') } *>&1 | Out-String -Width 400
        $script:r.Failed | Should -Be @('windows11.0-kb5043080-x64.msu', 'windows11.0-kb5090000-x64.msu')
        $output | Should -Match 'Не удалось установить windows11\.0-kb5090000-x64\.msu \(dism\.exe, код 0x800f081f\)'
        # 0x800f081e: накопительные обновления не для этого образа, это не ошибка.
        Mock Invoke-Native -ModuleName LunqDebloater { return -2146498530 } -ParameterFilter { $FilePath -eq 'dism.exe' }
        $null = & { $script:r = & (Get-Module LunqDebloater) { param($f, $s) Add-LunqUpdates -MountPath 'mount' -Files $f -ScratchDir $s } $files (Join-Path $TestDrive 'cpwork3\scratch') } *>&1
        $script:r.Skipped.Count | Should -Be 2
        $script:r.Failed.Count | Should -Be 0
    }

    It 'Safe OS и Setup Dynamic Update узнаются по содержимому .cab' {
        # expand.exe заменён: что лежит в .cab, задаёт текст файла.
        Mock Invoke-Native -ModuleName LunqDebloater {
            $text = Get-Content -LiteralPath $Arguments[0] -Raw
            if ($Arguments[1] -eq '-F:setup*.exe') {
                if ($text -match 'setup') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'SetupHost.exe') -Value 'exe' }
            }
            elseif ($text -match 'safeos') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'update.mum') -Value '<assemblyIdentity name="Package_for_SafeOSDU" />' }
            elseif ($text -match 'rollup') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'update.mum') -Value '<assemblyIdentity name="Package_for_RollupFix" />' }
            return 0
        }
        Mock Write-Warning -ModuleName LunqDebloater { }
        $dir = Join-Path $TestDrive 'du'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb1-x64.msu') -Value 'MSCF msu'
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb2-x64.cab') -Value 'MSCF rollup'
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb3-x64_0123456789abcdef0123456789abcdef01234567.cab') -Value 'MSCF safeos'
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb4-x64_0123456789abcdef0123456789abcdef01234567.cab') -Value 'MSCF setup files'
        # Не архив CAB: распаковка не запускается, файл считается обычным обновлением.
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb5-x64.cab') -Value 'not a cab'
        # Архив без пакета и без файлов установщика (драйвер из каталога): его не распаковывают в sources.
        Set-Content -LiteralPath (Join-Path $dir 'windows11.0-kb6-x64.cab') -Value 'MSCF driver'

        $cache = @{}
        $split = Split-LunqDynamicUpdates -Files (Get-LunqUpdateFiles -Path $dir) -TempDir (Join-Path $TestDrive 'check') -Cache $cache 6>$null
        @($split.Updates | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb1-x64.msu', 'windows11.0-kb2-x64.cab', 'windows11.0-kb5-x64.cab')
        @($split.SafeOS | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb3-x64_0123456789abcdef0123456789abcdef01234567.cab')
        @($split.Setup | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb4-x64_0123456789abcdef0123456789abcdef01234567.cab')
        @($split.Unknown | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb6-x64.cab')
        Should -Invoke Write-Warning -ModuleName LunqDebloater -Times 1 -Exactly -ParameterFilter { $Message -match 'kb6-x64\.cab не похож ни на обновление' }
        # По одному вызову на пакет и по два на архивы без .mum: Setup и драйвер.
        Should -Invoke Invoke-Native -ModuleName LunqDebloater -Times 6 -Exactly
        # Распознанные файлы не распаковываются снова, когда сводка показывается ещё раз.
        Split-LunqDynamicUpdates -Files (Get-LunqUpdateFiles -Path $dir) -TempDir (Join-Path $TestDrive 'check') -Cache $cache 6>$null | Out-Null
        Should -Invoke Invoke-Native -ModuleName LunqDebloater -Times 6 -Exactly
        Should -Invoke Write-Warning -ModuleName LunqDebloater -Times 1 -Exactly
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

Describe 'Add-LunqSetupDynamicUpdate' {
    It 'распаковывает в sources только файлы с подписью Microsoft' {
        $iso = Join-Path $TestDrive 'sdu'
        New-Item -ItemType Directory -Path (Join-Path $iso 'sources') -Force | Out-Null
        $signed = Join-Path $TestDrive 'windows11.0-kb1-x64.cab'
        $unsigned = Join-Path $TestDrive 'windows11.0-kb2-x64.cab'
        Set-Content -LiteralPath $signed, $unsigned -Value 'cab'
        Mock Get-LunqSignatureError -ModuleName LunqDebloater { if ($Path -like '*kb2*') { 'NotSigned' } }
        Mock Invoke-Native -ModuleName LunqDebloater { 0 }
        $output = & { $script:r = & (Get-Module LunqDebloater) { param($i, $f) Add-LunqSetupDynamicUpdate -IsoRoot $i -Files $f } $iso @((Get-Item -LiteralPath $signed), (Get-Item -LiteralPath $unsigned)) } *>&1 | Out-String -Width 400
        $script:r.Done | Should -Be @('windows11.0-kb1-x64.cab')
        $script:r.Failed | Should -Be @('windows11.0-kb2-x64.cab')
        $output | Should -Match 'windows11\.0-kb2-x64\.cab не подписан Microsoft \(NotSigned\)'
        Should -Invoke Invoke-Native -ModuleName LunqDebloater -Times 1 -Exactly
        Should -Invoke Invoke-Native -ModuleName LunqDebloater -Times 0 -Exactly -ParameterFilter { $Arguments[0] -like '*kb2*' }
    }
}

Describe 'Загрузчик Windows UEFI CA 2023' {
    It 'ISO для ARM64: заменяется bootaa64.efi, а bootx64.efi не появляется' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $mount = Join-Path $Root 'arm\mount'
            foreach ($name in 'EFI_EX\bootmgfw_EX.efi', 'EFI_EX\bootmgr_EX.efi', 'DVD_EX\EFI\en-US\efisys_EX.bin', 'DVD_EX\EFI\en-US\efisys_noprompt_EX.bin', 'Fonts_EX\segoe_slboot_EX.ttf') {
                $file = Join-Path $mount "Windows\Boot\$name"
                New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
                Set-Content -LiteralPath $file -Value "$name new"
            }
            $iso = Join-Path $Root 'arm\iso'
            foreach ($name in 'efi\boot\bootaa64.efi', 'bootmgr.efi', 'efi\microsoft\boot\efisys.bin', 'efi\microsoft\boot\efisys_noprompt.bin') {
                $file = Join-Path $iso $name
                New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
                Set-Content -LiteralPath $file -Value 'old'
            }
            $stage = Join-Path $Root 'arm\bootex'
            Export-LunqBootCA2023 -MountPath $mount -Destination $stage | Should -BeTrue
            $result = Install-LunqBootCA2023 -IsoRoot $iso -From $stage
            $result.Failed.Count | Should -Be 0
            @($result.Done) | Should -Be @('efi\boot\bootaa64.efi', 'bootmgr.efi', 'efi\microsoft\boot\efisys.bin', 'efi\microsoft\boot\efisys_noprompt.bin')
            Get-Content -LiteralPath (Join-Path $iso 'efi\boot\bootaa64.efi') | Should -Be 'EFI_EX\bootmgfw_EX.efi new'
            Get-Content -LiteralPath (Join-Path $iso 'efi\microsoft\boot\efisys_noprompt.bin') | Should -Be 'DVD_EX\EFI\en-US\efisys_noprompt_EX.bin new'
            Test-Path -LiteralPath (Join-Path $iso 'efi\boot\bootx64.efi') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $iso 'efi\microsoft\boot\fonts\segoe_slboot.ttf') | Should -BeTrue
        }
    }

    It 'в образе нет одного из файлов: предупреждение, в рабочую папку ничего не копируется' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $mount = Join-Path $Root 'part\mount'
            $file = Join-Path $mount 'Windows\Boot\EFI_EX\bootmgfw_EX.efi'
            New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value 'new'
            Mock Write-Warning { }
            $stage = Join-Path $Root 'part\bootex'
            Export-LunqBootCA2023 -MountPath $mount -Destination $stage | Should -BeFalse
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*bootmgr_EX.efi*efisys_EX.bin*' }
            Test-Path -LiteralPath $stage | Should -BeFalse
        }
    }
}

Describe 'Get-FolderSize' {
    It 'с -Cache папка обходится один раз, пока её не уберут из кэша' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $dir = Join-Path $Root 'SizeCache'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $dir 'a.inf'), (New-Object byte[] 100))
            $cache = @{}
            Get-FolderSize $dir -Cache $cache | Should -Be 100
            [IO.File]::WriteAllBytes((Join-Path $dir 'b.inf'), (New-Object byte[] 50))
            Get-FolderSize $dir -Cache $cache | Should -Be 100
            Get-FolderSize $dir | Should -Be 150
            $cache.Remove($dir)
            Get-FolderSize $dir -Cache $cache | Should -Be 150
        }
    }
}
