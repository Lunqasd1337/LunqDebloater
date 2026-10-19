#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Обновления из каталога Microsoft (Private\Catalog.ps1): разбор страниц каталога, выбор
# свежего обновления и скачивание. В сеть тесты не ходят: ответы каталога подменяются.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru

    # Страница поиска каталога в том виде, в каком её отдаёт сайт: строка заголовка и строки
    # результатов <tr id="<guid>_R<n>"> с семью ячейками.
    function global:New-LunqFakeCatalogPage {
        param([object[]]$Rows)
        $html = '<table id="ctl00_catalogBody_updateMatches"><tr id="headerRow"><td>Title</td></tr>'
        foreach ($r in $Rows) {
            $html += '<tr id="{0}_R1"><td></td><td><a href="#">  {1}  </a></td><td>Windows 11</td><td>Security Updates</td><td>{2}</td><td>n/a</td><td><span>1 MB</span><span id="x_originalSize" style="display:none">{3}</span></td><td><input type="button" /></td></tr>' -f $r.Id, $r.Title, $r.Date, $r.Size
        }
        return $html + '</table>'
    }

    # Ответ окна скачивания: ссылка на файл и его SHA-1 в base64.
    function global:New-LunqFakeDownloadDialog {
        param([string]$Name, [string]$Content)
        $sha1 = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Content))
        return "downloadInformation[0].files[0].url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/files/$Name';`r`ndownloadInformation[0].files[0].digest = '$([Convert]::ToBase64String($sha1))';"
    }
}

AfterAll {
    Remove-Item function:global:New-LunqFakeCatalogPage, function:global:New-LunqFakeDownloadDialog -ErrorAction SilentlyContinue
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Разбор страниц каталога' {
    It 'из страницы поиска берутся Id, название, дата и размер, строка заголовка пропускается' {
        InModuleScope LunqDebloater {
            $html = New-LunqFakeCatalogPage @(
                @{ Id = '0f0e0d0c-0b0a-0908-0706-050403020100'; Title = '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5090000) (26300.7000)'; Date = '10/14/2026'; Size = 812345678 })
            $rows = ConvertFrom-LunqCatalogSearch $html
            $rows.Count | Should -Be 1
            $rows[0].Id | Should -Be '0f0e0d0c-0b0a-0908-0706-050403020100'
            $rows[0].Title | Should -Be '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5090000) (26300.7000)'
            $rows[0].Date | Should -Be ([datetime]'2026-10-14')
            $rows[0].Size | Should -Be 812345678
        }
    }

    It 'пустая или непохожая страница даёт пустой список' {
        InModuleScope LunqDebloater {
            (ConvertFrom-LunqCatalogSearch '').Count | Should -Be 0
            (ConvertFrom-LunqCatalogSearch '<html><body>We did not find any results</body></html>').Count | Should -Be 0
        }
    }

    It 'из окна скачивания берутся ссылки и SHA-1, повторы ссылок отбрасываются' {
        InModuleScope LunqDebloater {
            $digest = [Convert]::ToBase64String([byte[]](1..20))
            $text = @(
                "downloadInformation[0].files[0].url = 'https://dl.example/windows11.0-kb5090000-x64.msu';",
                "downloadInformation[0].files[0].digest = '$digest';",
                "downloadInformation[0].files[1].url = 'https://dl.example/windows11.0-kb5090000-x64.msu';",
                "downloadInformation[1].files[0].url = 'https://dl.example/windows11.0-kb5043080-x64_aabbccddeeff00112233445566778899aabbccdd.msu';") -join "`r`n"
            $files = ConvertFrom-LunqCatalogDownload $text
            $files.Count | Should -Be 2
            $files[0].Name | Should -Be 'windows11.0-kb5090000-x64.msu'
            $files[0].Sha1 | Should -Be '0102030405060708090a0b0c0d0e0f1011121314'
            # Суммы в окне нет: она берётся из имени файла.
            $files[1].Sha1 | Should -Be 'aabbccddeeff00112233445566778899aabbccdd'
        }
    }
}

Describe 'Выбор обновления' {
    It 'берётся самое свежее накопительное обновление выпуска, без предварительных и .NET' {
        InModuleScope LunqDebloater {
            $target = (Get-LunqCatalogTargets -Release '26H2' -Architecture 'amd64')[0]
            $rows = @(
                [pscustomobject]@{ Title = '2026-10 Cumulative Update Preview for Windows 11, version 26H2 for x64-based Systems (KB5090099) (26300.7100)'; Date = [datetime]'2026-10-28' },
                [pscustomobject]@{ Title = '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5090000) (26300.7000)'; Date = [datetime]'2026-10-14' },
                [pscustomobject]@{ Title = '2026-10 Cumulative Update for Windows 11, version 26H2 for arm64-based Systems (KB5090000) (26300.7000)'; Date = [datetime]'2026-10-14' },
                [pscustomobject]@{ Title = '2026-10 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5090005) (26200.7000)'; Date = [datetime]'2026-10-15' },
                [pscustomobject]@{ Title = '2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB5090001)'; Date = [datetime]'2026-10-16' },
                [pscustomobject]@{ Title = '2026-09 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5080000) (26300.6000)'; Date = [datetime]'2026-09-09' })
            (Select-LunqCatalogUpdate -Rows $rows -Target $target).Title | Should -Match 'x64-based Systems \(KB5090000\)'
        }
    }

    It 'в один день побеждает более поздняя ревизия сборки' {
        InModuleScope LunqDebloater {
            $target = (Get-LunqCatalogTargets -Release '26H2' -Architecture 'amd64')[0]
            $rows = @(
                [pscustomobject]@{ Title = 'Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB1) (26300.7000)'; Date = [datetime]'2026-10-14' },
                [pscustomobject]@{ Title = 'Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB2) (26300.7001)'; Date = [datetime]'2026-10-14' })
            (Select-LunqCatalogUpdate -Rows $rows -Target $target).Title | Should -Match 'KB2'
        }
    }

    It 'для arm64 x64-обновление не подходит, а без подходящих возвращается $null' {
        InModuleScope LunqDebloater {
            $target = (Get-LunqCatalogTargets -Release '26H2' -Architecture 'arm64')[0]
            $rows = @([pscustomobject]@{ Title = 'Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB1)'; Date = [datetime]'2026-10-14' })
            Select-LunqCatalogUpdate -Rows $rows -Target $target | Should -BeNullOrEmpty
            $rows += [pscustomobject]@{ Title = 'Cumulative Update for Windows 11, version 26H2 for ARM64-based Systems (KB2)'; Date = [datetime]'2026-10-14' }
            (Select-LunqCatalogUpdate -Rows $rows -Target $target).Title | Should -Match 'KB2'
        }
    }

    It 'Dynamic Update ищутся, только когда они нужны' {
        InModuleScope LunqDebloater {
            @((Get-LunqCatalogTargets -Release '26H2' -Architecture 'amd64') | ForEach-Object { $_.Kind }) | Should -Be @('Update', 'DotNet')
            @((Get-LunqCatalogTargets -Release '26H2' -Architecture 'amd64' -WithDynamic) | ForEach-Object { $_.Kind }) | Should -Be @('Update', 'DotNet', 'SafeOS', 'Setup')
        }
    }

    It 'выпуск для поиска берётся из номера сборки' {
        InModuleScope LunqDebloater {
            Get-LunqCatalogRelease -Build 26300 | Should -Be '26H2'
            Get-LunqCatalogRelease -Build 26100 | Should -Be '24H2'
            Get-LunqCatalogRelease -Build 12345 | Should -BeNullOrEmpty
        }
    }
}

Describe 'Save-LunqCatalogUpdates' {
    BeforeEach {
        InModuleScope LunqDebloater {
            Mock Write-Info { }
            Mock Write-Warning { }
            $script:WebCalls = New-Object System.Collections.Generic.List[string]
            $script:BadHash = $false
            # Каталог отвечает по виду запроса: поиск, окно скачивания или сам файл.
            Mock Invoke-LunqWebRequest {
                $script:WebCalls.Add("$Method $Uri")
                if ($OutFile) {
                    $name = [IO.Path]::GetFileName(([uri]$Uri).AbsolutePath)
                    $content = "update $name"
                    if ($script:BadHash) { $content = 'broken' }
                    [IO.File]::WriteAllText($OutFile, $content)
                    return
                }
                if ($Uri -like '*Search.aspx*') {
                    $q = [uri]::UnescapeDataString(($Uri -split 'q=')[1])
                    if ($q -like '*.NET*') { return (New-LunqFakeCatalogPage @(@{ Id = '00000000-0000-0000-0000-000000000002'; Title = '2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB5090001)'; Date = '10/14/2026'; Size = 1 })) }
                    if ($q -like '*Safe OS*') { return (New-LunqFakeCatalogPage @(@{ Id = '00000000-0000-0000-0000-000000000003'; Title = '2026-10 Safe OS Dynamic Update for Windows 11, version 26H2 for x64-based Systems (KB5090002)'; Date = '10/14/2026'; Size = 1 })) }
                    if ($q -like '*Setup Dynamic*') { return (New-LunqFakeCatalogPage @()) }
                    return (New-LunqFakeCatalogPage @(@{ Id = '00000000-0000-0000-0000-000000000001'; Title = '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5090000) (26300.7000)'; Date = '10/14/2026'; Size = 1 }))
                }
                $id = [regex]::Match([string]$Body.updateIDs, '"updateID":"([^"]+)"').Groups[1].Value
                $name = switch ($id.Substring($id.Length - 1)) {
                    '1' { 'windows11.0-kb5090000-x64.msu' }
                    '2' { 'windows11.0-kb5090001-x64-ndp481.msu' }
                    '3' { 'windows11.0-kb5090002-x64.cab' }
                }
                return (New-LunqFakeDownloadDialog -Name $name -Content "update $name")
            }
        }
    }

    It 'скачивает накопительное и .NET в корень, Safe OS в подпапку, без Setup предупреждает' {
        $dest = Join-Path $TestDrive 'cat1'
        InModuleScope LunqDebloater -Parameters @{ Dest = $dest } {
            param($Dest)
            $found = Save-LunqCatalogUpdates -Release '26H2' -Architecture 'amd64' -Destination $Dest -WithDynamic
            @($found | ForEach-Object { $_.Kind }) | Should -Be @('Update', 'DotNet', 'SafeOS')
            Test-Path -LiteralPath (Join-Path $Dest 'windows11.0-kb5090000-x64.msu') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Dest 'windows11.0-kb5090001-x64-ndp481.msu') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Dest 'SafeOS\windows11.0-kb5090002-x64.cab') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $Dest -Recurse -Filter '*.partial').Count | Should -Be 0
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'Setup Dynamic Update' }
        }
    }

    It 'уже скачанное с верной суммой не скачивается снова, а обновления прошлого месяца удаляются' {
        $dest = Join-Path $TestDrive 'cat2'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'windows11.0-kb5080000-x64.msu') -Value 'old'
        Set-Content -LiteralPath (Join-Path $dest 'readme.txt') -Value 'keep'
        InModuleScope LunqDebloater -Parameters @{ Dest = $dest } {
            param($Dest)
            $null = Save-LunqCatalogUpdates -Release '26H2' -Architecture 'amd64' -Destination $Dest
            $first = @($script:WebCalls | Where-Object { $_ -like '*files/*' }).Count
            $first | Should -Be 2
            $script:WebCalls.Clear()
            $null = Save-LunqCatalogUpdates -Release '26H2' -Architecture 'amd64' -Destination $Dest
            @($script:WebCalls | Where-Object { $_ -like '*files/*' }).Count | Should -Be 0
            Should -Invoke Write-Info -ParameterFilter { $Message -match 'уже скачано: windows11\.0-kb5090000-x64\.msu' }
        }
        Test-Path -LiteralPath (Join-Path $dest 'windows11.0-kb5080000-x64.msu') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dest 'readme.txt') | Should -BeTrue
    }

    It 'файл с неверной суммой удаляется, сборка останавливается' {
        $dest = Join-Path $TestDrive 'cat3'
        InModuleScope LunqDebloater -Parameters @{ Dest = $dest } {
            param($Dest)
            $script:BadHash = $true
            { Save-LunqCatalogUpdates -Release '26H2' -Architecture 'amd64' -Destination $Dest } | Should -Throw '*не совпадает с контрольной суммой*'
        }
        @(Get-ChildItem -LiteralPath $dest -Recurse -File).Count | Should -Be 0
    }

    It 'каталог не отвечает: понятная ошибка с советом скачать вручную' {
        InModuleScope LunqDebloater -Parameters @{ Dest = (Join-Path $TestDrive 'cat4') } {
            param($Dest)
            Mock Invoke-LunqWebRequest { throw 'The remote name could not be resolved' }
            { Save-LunqCatalogUpdates -Release '26H2' -Architecture 'amd64' -Destination $Dest } | Should -Throw '*не ответил: The remote name could not be resolved*Config\Updates*'
        }
    }

    It 'накопительного обновления нет: ошибка, а не сборка без него' {
        InModuleScope LunqDebloater -Parameters @{ Dest = (Join-Path $TestDrive 'cat5') } {
            param($Dest)
            Mock Invoke-LunqWebRequest { New-LunqFakeCatalogPage @() }
            { Save-LunqCatalogUpdates -Release '26H2' -Architecture 'amd64' -Destination $Dest } | Should -Throw '*не нашлось: накопительное обновление для Windows 11 26H2 x64*'
        }
    }
}
