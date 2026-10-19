#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Данные для отката и откат (Private\Restore.ps1): что записывается, как сливается с прошлым
# файлом и что возвращается. Реестр и приложения подменяются: систему тесты не трогают.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru

    # Профиль из двух категорий: удалённое раскладывается по их шаблонам.
    $script:TestProfile = [pscustomobject]@{
        Name       = 'Test'
        Categories = @(
            [pscustomobject]@{ Id = 'news'; Name = 'Новости'; NameSource = [pscustomobject]@{ ru = 'Новости'; en = 'News' }; Enabled = $true; Appx = @('Microsoft.BingNews'); Capabilities = @(); Features = @(); Packages = @() },
            [pscustomobject]@{ Id = 'tools'; Name = 'Инструменты'; Enabled = $true; Appx = @(); Capabilities = @('App.StepsRecorder*'); Features = @('Recall'); Packages = @('*MediaPlayer*') })
    }
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Запись данных для отката' {
    It 'удалённое раскладывается по категориям профиля, имя категории с переводами' {
        $path = Join-Path $TestDrive 'r1\Restore.json'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; P = $script:TestProfile } {
            param($Path, $P)
            $data = New-LunqRestoreData -LunqProfile $P -Source Online
            Add-LunqRestoreItem -Restore $data -Kind Appx -Name 'Microsoft.BingNews' -Extra @{ PackageFamilyName = 'Microsoft.BingNews_8wekyb3d8bbwe' }
            Add-LunqRestoreItem -Restore $data -Kind Capabilities -Name 'App.StepsRecorder~~~~0.0.1.0'
            Add-LunqRestoreItem -Restore $data -Kind Appx -Name 'Unknown.App'
            Add-LunqRestoreRegistry -Restore $data -Category 'news' -Entry ([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Action = 'DeleteValue' })
            Save-LunqRestoreData -Restore $data -Path $Path
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.Kind | Should -Be 'LunqDebloaterRestore'
            $json.Source | Should -Be 'Online'
            @($json.Categories | ForEach-Object { $_.Id }) | Should -Be @('news', 'tools', 'profile')
            $json.Categories[0].Name.en | Should -Be 'News'
            $json.Categories[0].Appx[0].PackageFamilyName | Should -Be 'Microsoft.BingNews_8wekyb3d8bbwe'
            $json.Categories[0].Registry[0].Action | Should -Be 'DeleteValue'
            $json.Categories[1].Capabilities[0].Name | Should -Be 'App.StepsRecorder~~~~0.0.1.0'
            # Пустые списки в файл не пишутся.
            $json.Categories[1].PSObject.Properties['Appx'] | Should -BeNullOrEmpty
            # Прочитанный файл даёт те же категории.
            $back = Read-LunqRestoreData -Path $Path
            @($back.Categories | ForEach-Object { $_.Id }) | Should -Be @('news', 'tools', 'profile')
            $back.Categories[0].Appx.Count | Should -Be 1
        }
    }

    It 'при повторном -Online старое значение реестра не заменяется новым, новое добавляется' {
        $path = Join-Path $TestDrive 'r2\Restore.json'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; P = $script:TestProfile } {
            param($Path, $P)
            $first = New-LunqRestoreData -LunqProfile $P -Source Online
            Add-LunqRestoreRegistry -Restore $first -Category 'news' -Entry ([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'A'; Name = 'V'; Type = 'DWord'; Value = 1 })
            Save-LunqRestoreData -Restore $first -Path $Path
            $second = New-LunqRestoreData -LunqProfile $P -Source Online
            # Во второй раз значение уже изменено LunqDebloater: «прежнее» 0 не настоящее.
            Add-LunqRestoreRegistry -Restore $second -Category 'news' -Entry ([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'a'; Name = 'v'; Type = 'DWord'; Value = 0 })
            Add-LunqRestoreRegistry -Restore $second -Category 'news' -Entry ([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'B'; Name = 'W'; Action = 'DeleteValue' })
            Save-LunqRestoreData -Restore $second -Path $Path -Merge
            $back = Read-LunqRestoreData -Path $Path
            $back.Categories[0].Registry.Count | Should -Be 2
            $back.Categories[0].Registry[0].Value | Should -Be 1
            $back.Categories[0].Registry[1].Path | Should -Be 'B'
        }
    }

    It 'файл пишется через временный, прошлая версия остаётся в .bak, а испорченный файл откладывается' {
        $dir = Join-Path $TestDrive 'r-atomic'
        $path = Join-Path $dir 'Restore.json'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; P = $script:TestProfile } {
            param($Path, $P)
            Mock Write-Warning { }
            $first = New-LunqRestoreData -LunqProfile $P -Source Online
            Add-LunqRestoreItem -Restore $first -Kind Appx -Name 'Microsoft.BingNews'
            Save-LunqRestoreData -Restore $first -Path $Path
            $second = New-LunqRestoreData -LunqProfile $P -Source Online
            Add-LunqRestoreItem -Restore $second -Kind Features -Name 'Recall'
            Save-LunqRestoreData -Restore $second -Path $Path -Merge
            Test-Path -LiteralPath "$Path.tmp" | Should -BeFalse
            # В .bak прошлая версия: только первое приложение.
            $backup = Get-Content -LiteralPath "$Path.bak" -Raw -Encoding UTF8 | ConvertFrom-Json
            @($backup.Categories | ForEach-Object { $_.Id }) | Should -Be @('news')

            # Запись оборвалась: файл испорчен. Он откладывается, а данные берутся из прошлой версии.
            Set-Content -LiteralPath $Path -Value '{ "Kind": "LunqDebloaterRes'
            $back = Read-LunqRestoreData -Path $Path
            @($back.Categories | ForEach-Object { $_.Id }) | Should -Be @('news')
            @(Get-ChildItem -LiteralPath (Split-Path $Path) -Filter 'Restore.json.corrupt-*').Count | Should -Be 1
            Should -Invoke Write-Warning -Times 2 -Exactly

            # Новое -Online после этого дописывается к прошлой версии, а не падает.
            $third = New-LunqRestoreData -LunqProfile $P -Source Online
            Add-LunqRestoreItem -Restore $third -Kind Features -Name 'Recall'
            Save-LunqRestoreData -Restore $third -Path $Path -Merge
            @((Read-LunqRestoreData -Path $Path).Categories | ForEach-Object { $_.Id }) | Should -Be @('news', 'tools')

            # Пустой файл без прошлой версии: данных нет, но и ошибки нет.
            Remove-Item -LiteralPath "$Path.bak"
            Set-Content -LiteralPath $Path -Value ''
            Read-LunqRestoreData -Path $Path | Should -BeNullOrEmpty
            Test-Path -LiteralPath $Path | Should -BeFalse
        }
    }

    It 'всё вернулось: файл отката удаляется' {
        $path = Join-Path $TestDrive 'r3\Restore.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value '{}'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; P = $script:TestProfile } {
            param($Path, $P)
            Save-LunqRestoreData -Restore (New-LunqRestoreData -LunqProfile $P) -Path $Path
        }
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'чужой файл не принимается за файл отката' {
        $path = Join-Path $TestDrive 'r4.json'
        Set-Content -LiteralPath $path -Value '{ "Kind": "LunqDebloaterRecipe" }'
        InModuleScope LunqDebloater -Parameters @{ Path = $path } {
            param($Path)
            { Read-LunqRestoreData -Path $Path } | Should -Throw '*не файл отката LunqDebloater*'
            Read-LunqRestoreData -Path ($Path + '.none') | Should -BeNullOrEmpty
        }
    }

    It 'кусты образа в .reg переводятся в кусты этой Windows' {
        InModuleScope LunqDebloater {
            $text = "[HKEY_LOCAL_MACHINE\LUNQ_SOFTWARE\Policies\X]`r`n[-HKEY_LOCAL_MACHINE\LUNQ_SYSTEM]`r`n[HKEY_LOCAL_MACHINE\LUNQ_NTUSER\Software\Y]`r`n`"Path`"=`"HKEY_LOCAL_MACHINE\\LUNQ_SOFTWARE`""
            $out = ConvertTo-LunqImportText -Text $text
            $out | Should -Match '^\[HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\X\]'
            $out | Should -Match '\[-HKEY_LOCAL_MACHINE\\SYSTEM\]'
            # Профиль Default подключается под тем же именем, а значения внутри не трогаются.
            $out | Should -Match '\[HKEY_LOCAL_MACHINE\\LUNQ_NTUSER\\Software\\Y\]'
            $out | Should -Match '"Path"="HKEY_LOCAL_MACHINE\\\\LUNQ_SOFTWARE"'
            ConvertTo-LunqImportText -Text $text -ToCurrentUser | Should -Match '\[HKEY_CURRENT_USER\\Software\\Y\]'
        }
    }
}

Describe 'Invoke-LunqRestore' {
    It 'куст не выгрузился: файл отката всё равно записан, вернувшееся из него убрано' {
        $path = Join-Path $TestDrive 'r-stuck\Restore.json'
        InModuleScope LunqDebloater -Parameters @{ Path = $path; P = $script:TestProfile } {
            param($Path, $P)
            $data = New-LunqRestoreData -LunqProfile $P -Source Online
            Add-LunqRestoreItem -Restore $data -Kind Appx -Name 'Microsoft.BingNews'
            Save-LunqRestoreData -Restore $data -Path $Path
            Mock Get-LunqSystemDrive { 'C:\' }
            Mock Mount-OfflineHives { }
            Mock Write-Step { }
            Mock Write-LunqDismMarker { }
            Mock Restore-LunqCategory { $Category.Appx.Clear(); New-LunqResult 'news' 'Restore' }
            Mock Dismount-OfflineHives { throw 'hive is stuck' }
            { Invoke-LunqRestore -Restore (Read-LunqRestoreData -Path $Path) -Ids 'news' -Path $Path } | Should -Throw '*hive is stuck*'
            # Всё вернулось, поэтому файла больше нет: следующий -Restore не повторит откат.
            Test-Path -LiteralPath $Path | Should -BeFalse
        }
    }
}

Describe 'Откат категории' {
    BeforeEach {
        InModuleScope LunqDebloater {
            Mock Write-Info { }
            Mock Write-Warning { }
            Mock Add-LunqAppxBack { if ($PackageFamilyName -like 'Gone*') { throw 'package files are gone' } }
            Mock Add-WindowsCapability { if ($Name -like 'Broken*') { throw 'source files not found' } }
            Mock Enable-WindowsOptionalFeature { }
            Mock Invoke-RegistryEntry { 'Applied' }
            Mock Import-LunqRegistryText { $true }
        }
    }

    It 'возвращается всё, что можно, а в категории остаётся только то, что не вернулось' {
        InModuleScope LunqDebloater {
            $category = New-LunqRestoreCategory -Id 'news' -Name ([pscustomobject]@{ ru = 'Новости'; en = 'News' })
            $category.Appx.Add([pscustomobject]@{ Name = 'Microsoft.BingNews'; PackageFamilyName = 'Microsoft.BingNews_8wekyb3d8bbwe' })
            $category.Appx.Add([pscustomobject]@{ Name = 'Gone.App'; PackageFamilyName = 'Gone.App_8wekyb3d8bbwe' })
            $category.Capabilities.Add([pscustomobject]@{ Name = 'App.StepsRecorder~~~~0.0.1.0' })
            $category.Capabilities.Add([pscustomobject]@{ Name = 'Broken.Capability~~~~0.0.1.0' })
            $category.Features.Add([pscustomobject]@{ Name = 'Recall' })
            $category.Packages.Add([pscustomobject]@{ Name = 'Microsoft-Windows-MediaPlayer-Package' })
            $category.Registry.Add([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'Policies\X'; Name = 'V'; Action = 'DeleteValue' })
            $category.RegistryKeys.Add([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'Classes\Y'; Export = 'Windows Registry Editor Version 5.00' })

            $r = Restore-LunqCategory -Category $category
            $r.Title | Should -Be 'Новости'
            @($r.Done) | Should -Be @('Microsoft.BingNews', 'App.StepsRecorder~~~~0.0.1.0', 'Recall', 'SOFTWARE\Policies\X\V', 'SOFTWARE\Classes\Y')
            @($r.Failed) | Should -Be @('Broken.Capability~~~~0.0.1.0')
            # Удалённое с файлами приложение и системный пакет возвращаются вручную.
            @($r.Skipped) | Should -Be @('Gone.App', 'Microsoft-Windows-MediaPlayer-Package')
            @($r.StoreLinks) | Should -Be @('ms-windows-store://pdp/?PFN=Gone.App_8wekyb3d8bbwe')

            @($category.Appx | ForEach-Object { $_.Name }) | Should -Be @('Gone.App')
            @($category.Capabilities | ForEach-Object { $_.Name }) | Should -Be @('Broken.Capability~~~~0.0.1.0')
            $category.Features.Count | Should -Be 0
            $category.Registry.Count | Should -Be 0
            $category.RegistryKeys.Count | Should -Be 0
            Should -Invoke Enable-WindowsOptionalFeature -Times 1 -ParameterFilter { $Online -and $All -and $NoRestart }
            Should -Invoke Invoke-RegistryEntry -Times 1 -ParameterFilter { $Root -eq 'HKLM\SOFTWARE' }
        }
    }

    It 'значение профиля Default возвращается и текущему пользователю, если для него нет своего' {
        InModuleScope LunqDebloater {
            $category = New-LunqRestoreCategory -Id 'ads' -Name 'Реклама'
            $category.Registry.Add([pscustomobject]@{ Hive = 'DefaultUser'; Path = 'Software\A'; Name = 'One'; Action = 'DeleteValue' })
            $category.Registry.Add([pscustomobject]@{ Hive = 'DefaultUser'; Path = 'Software\B'; Name = 'Two'; Action = 'DeleteValue' })
            # Своё прежнее значение текущего пользователя для второй записи записал -Online.
            $category.Registry.Add([pscustomobject]@{ Hive = 'CurrentUser'; Path = 'Software\B'; Name = 'Two'; Type = 'DWord'; Value = 1 })
            $null = Restore-LunqCategory -Category $category
            Should -Invoke Invoke-RegistryEntry -Times 2 -Exactly -ParameterFilter { $Root -eq 'HKCU' }
            Should -Invoke Invoke-RegistryEntry -Times 1 -Exactly -ParameterFilter { $Root -eq 'HKCU' -and $Entry.Path -eq 'Software\B' -and $Entry.Hive -eq 'CurrentUser' }
            Should -Invoke Invoke-RegistryEntry -Times 2 -Exactly -ParameterFilter { $Root -eq 'HKLM\LUNQ_NTUSER' }
        }
    }

    It 'удалённая программа ставится обратно своим скриптом, а не вернувшаяся остаётся в категории' {
        InModuleScope LunqDebloater {
            $category = New-LunqRestoreCategory -Id 'edge' -Name 'Microsoft Edge'
            $category.Uninstall.Add([pscustomobject]@{ Name = 'MicrosoftEdge' })
            Mock Invoke-LunqUninstaller { 0 }
            $r = Restore-LunqCategory -Category $category
            @($r.Done) | Should -Be @('Microsoft Edge')
            $category.Uninstall.Count | Should -Be 0
            Should -Invoke Invoke-LunqUninstaller -Times 1 -Exactly -ParameterFilter { $Name -eq 'MicrosoftEdge' -and $Action -eq 'Restore' }

            # Без интернета EdgeRemover не скачает Edge: программа ждёт следующего -Restore.
            $category.Uninstall.Add([pscustomobject]@{ Name = 'MicrosoftEdge' })
            Mock Invoke-LunqUninstaller { 404 }
            $r = Restore-LunqCategory -Category $category
            @($r.Failed) | Should -Be @('Microsoft Edge')
            $category.Uninstall.Count | Should -Be 1
        }
    }

    It 'запись реестра не вернулась: она остаётся в категории для следующей попытки' {
        InModuleScope LunqDebloater {
            Mock Invoke-RegistryEntry { 'Failed' }
            Mock Import-LunqRegistryText { $false }
            $category = New-LunqRestoreCategory -Id 'x' -Name 'X'
            $category.Registry.Add([pscustomobject]@{ Hive = 'SYSTEM'; Path = 'A'; Name = 'B'; Action = 'DeleteValue' })
            $category.RegistryKeys.Add([pscustomobject]@{ Hive = 'SOFTWARE'; Path = 'C'; Export = 'x' })
            $r = Restore-LunqCategory -Category $category
            @($r.Failed) | Should -Be @('SYSTEM\A\B', 'SOFTWARE\C')
            $category.Registry.Count | Should -Be 1
            $category.RegistryKeys.Count | Should -Be 1
        }
    }
}
