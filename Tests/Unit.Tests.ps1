#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Проверки отдельных функций модуля, без сборки образа. Работают и на Windows, и на Linux.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru
    $script:ProfilePath = Join-Path $repo 'Config\Profile.json'

    function New-TestProfile {
        # Профиль во временной папке из готового объекта.
        param([Parameter(Mandatory)]$Content)
        $path = Join-Path $TestDrive ("profile_{0}.json" -f [guid]::NewGuid().ToString('N'))
        $Content | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Манифест и версия' {
    It 'версия берётся из манифеста' {
        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\LunqDebloater\LunqDebloater.psd1')
        Get-LunqVersion | Should -Be $manifest.ModuleVersion
    }

    It 'внутренние функции не видны снаружи' {
        Get-Command -Module LunqDebloater -Name Invoke-Native -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command -Module LunqDebloater -Name Write-LunqReport | Should -Not -BeNullOrEmpty
    }

    It 'каждая функция из FunctionsToExport есть в модуле' {
        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\LunqDebloater\LunqDebloater.psd1')
        foreach ($name in $manifest.FunctionsToExport) {
            Get-Command -Module LunqDebloater -Name $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because $name
        }
    }
}

Describe 'Справка скрипта' {
    It 'Get-Help показывает описание и ссылку на GitHub' {
        $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'LunqDebloater.ps1'
        $help = Get-Help $script -Full
        $help.Synopsis | Should -Match 'Windows 11'
        # Get-Help -Online открывает первую ссылку.
        @($help.relatedLinks.navigationLink)[0].uri | Should -BeLike 'https://github.com/*'
    }

    It 'каждый параметр описан в README.md и README.en.md' {
        # Подробная справка живёт только в README, поэтому новый параметр нельзя забыть там.
        $repo = Split-Path $PSScriptRoot -Parent
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        $names = @((Get-Command (Join-Path $repo 'LunqDebloater.ps1')).Parameters.Keys | Where-Object { $common -notcontains $_ })
        foreach ($readme in 'README.md', 'README.en.md') {
            $text = [IO.File]::ReadAllText((Join-Path $repo $readme))
            foreach ($name in $names) {
                $text | Should -Match "``-$name\b" -Because "-$name должен быть в $readme"
            }
        }
    }
}

Describe 'Read-LunqProfile' {
    It 'читает профиль по умолчанию' {
        $p = Read-LunqProfile -Path $script:ProfilePath
        $p.Categories.Count | Should -Be 9
        $p.Requirements.Build | Should -Be 26300
        ($p.Categories | Where-Object Id -eq 'drivers').Enabled | Should -BeFalse
        ($p.Categories | Where-Object Id -eq 'telemetry').Enabled | Should -BeTrue
    }

    It 'профиль старого формата становится одной категорией' {
        $path = New-TestProfile @{ Name = 'Old'; Appx = @{ Remove = @('Microsoft.BingNews') }; Registry = @() }
        $p = Read-LunqProfile -Path $path
        $p.Categories.Count | Should -Be 1
        $p.Categories[0].Appx | Should -Be @('Microsoft.BingNews')
    }

    It 'не принимает повторяющийся Id' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a' }, @{ Id = 'a' }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*повторяется*'
    }

    It 'не принимает неизвестный куст' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'HKCU'; Path = 'x' }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*Неизвестный куст*'
    }

    It 'сразу отвергает запись с неизвестным типом' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Name = 'v'; Type = 'REG_WORD'; Value = 1 }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*неизвестный тип*'
    }

    It 'сразу отвергает DWORD, который не число' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Name = 'v'; Type = 'REG_DWORD'; Value = 'abc' }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*не число*'
    }

    It 'сразу отвергает неизвестное действие' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Action = 'Rename' }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*неизвестное действие*'
    }
}

Describe 'Get-LunqEffectiveConfig' {
    It 'берёт только включённые категории и помечает записи реестра категорией' {
        $p = Read-LunqProfile -Path $script:ProfilePath
        Disable-LunqCategories -LunqProfile $p -Ids 'ai'
        $config = Get-LunqEffectiveConfig -LunqProfile $p
        $config.Appx.Remove | Should -Not -Contain 'Microsoft.Copilot'
        $config.Appx.Remove | Should -Contain 'Microsoft.BingNews'
        @($config.Registry | Where-Object { $_.LunqCategory -eq 'ai' }).Count | Should -Be 0
        @($config.Registry | Where-Object { $_.LunqCategory -eq 'telemetry' }).Count | Should -Be 13
    }

    It 'неизвестный Id в -SkipCategory даёт понятную ошибку' {
        $p = Read-LunqProfile -Path $script:ProfilePath
        { Disable-LunqCategories -LunqProfile $p -Ids 'nope' } | Should -Throw '*Доступные Id*'
    }
}

Describe 'ConvertTo-LunqRegValue' {
    BeforeAll {
        $convert = { param($Type, $Value) & (Get-Module LunqDebloater) { param($t, $v) ConvertTo-LunqRegValue -Type $t -Value $v } $Type $Value }
    }

    It 'DWORD 0xFFFFFFFF и 4294967295 записываются как одно и то же значение' {
        (& $convert 'REG_DWORD' '0xFFFFFFFF').Data | Should -Be -1
        (& $convert 'REG_DWORD' 4294967295).Data | Should -Be -1
        (& $convert 'REG_DWORD' 1).Data | Should -Be 1
        (& $convert 'REG_DWORD' 1).Kind | Should -Be 'DWord'
    }

    It 'DWORD больше 32 бит не принимается' {
        { & $convert 'REG_DWORD' 4294967296 } | Should -Throw '*не помещается*'
    }

    It 'QWORD' {
        (& $convert 'REG_QWORD' '0x10').Data | Should -Be 16
        (& $convert 'REG_QWORD' '0x10').Kind | Should -Be 'QWord'
    }

    It 'строка с кавычками и обратной косой чертой в конце остаётся как есть' {
        $value = & $convert 'REG_SZ' '"C:\Program Files\App\app.exe" /min C:\Temp\'
        $value.Data | Should -BeExactly '"C:\Program Files\App\app.exe" /min C:\Temp\'
        $value.Kind | Should -Be 'String'
    }

    It 'REG_MULTI_SZ из массива' {
        $value = & $convert 'REG_MULTI_SZ' @('a', 'b')
        $value.Data | Should -Be @('a', 'b')
        $value.Kind | Should -Be 'MultiString'
    }

    It 'REG_BINARY из hex-строки с пробелами и запятыми' {
        $value = & $convert 'REG_BINARY' 'de ad,BE ef'
        $value.Data | Should -Be ([byte[]](0xDE, 0xAD, 0xBE, 0xEF))
    }

    It 'REG_BINARY с нечётным числом цифр не принимается' {
        { & $convert 'REG_BINARY' 'abc' } | Should -Throw '*hex*'
    }
}

Describe 'Test-NamePattern' {
    It 'шаблоны с *' {
        InModuleScope LunqDebloater {
            Test-NamePattern -Name 'Browser.InternetExplorer~~~~0.0.11.0' -Patterns 'Browser.InternetExplorer*' | Should -BeTrue
            Test-NamePattern -Name 'Microsoft.BingNews' -Patterns 'Microsoft.Bing' | Should -BeFalse
        }
    }
}

Describe 'Рабочая папка и итоговый ISO' {
    It 'корень диска не годится' {
        InModuleScope LunqDebloater { Test-LunqWorkDir -WorkDir ([IO.Path]::GetPathRoot($TestDrive)) | Should -Be 'это корень диска' }
    }

    It 'папка, внутри которой лежит ISO, не годится' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Test-LunqWorkDir -WorkDir $Root -ProtectedPaths (Join-Path $Root 'Win11.iso') | Should -BeLike 'внутри неё лежит*'
        }
    }

    It 'чужая непустая папка не годится, своя с меткой годится' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $foreign = Join-Path $Root 'foreign'
            New-Item -ItemType Directory -Path $foreign -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $foreign 'file.txt') -Value 'x'
            Test-LunqWorkDir -WorkDir $foreign | Should -Be 'папка не пустая и создана не этим скриптом'

            $own = Join-Path $Root 'own'
            Initialize-LunqWorkDir -WorkDir $own
            Set-Content -LiteralPath (Join-Path $own 'leftover.txt') -Value 'x'
            Test-LunqWorkDir -WorkDir $own | Should -BeNullOrEmpty
        }
    }

    It 'итоговый ISO не может совпадать с исходным' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $iso = Join-Path $Root 'Win11.iso'
            Test-LunqOutputPath -OutputIso $iso -IsoPath $iso | Should -BeLike 'это исходный ISO*'
        }
    }

    It 'папки для итогового ISO нет' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Test-LunqOutputPath -OutputIso (Join-Path $Root 'missing\out.iso') -IsoPath (Join-Path $Root 'in.iso') | Should -BeLike 'папки*нет*'
        }
    }

    It 'папка есть и доступна для записи' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Test-LunqOutputPath -OutputIso (Join-Path $Root 'out.iso') -IsoPath (Join-Path $Root 'in.iso') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-LunqImageRequirements' {
    BeforeAll {
        $requirements = [pscustomobject]@{ Build = 26300; MinRevision = 9457; Architecture = 'amd64' }
    }

    It 'подходящая сборка' {
        $info = [pscustomobject]@{ Build = 26300; Revision = 9500; Architecture = 'amd64' }
        $r = Test-LunqImageRequirements -Info $info -Requirements $requirements
        $r.Errors.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 0
    }

    It 'другая сборка и архитектура' {
        $info = [pscustomobject]@{ Build = 26200; Revision = 9500; Architecture = 'arm64' }
        $r = Test-LunqImageRequirements -Info $info -Requirements $requirements
        $r.Errors.Count | Should -Be 2
    }

    It 'старая ревизия: ошибка без накопительного обновления и предупреждение с ним' {
        $info = [pscustomobject]@{ Build = 26300; Revision = 100; Architecture = 'amd64' }
        (Test-LunqImageRequirements -Info $info -Requirements $requirements).Errors.Count | Should -Be 1
        $r = Test-LunqImageRequirements -Info $info -Requirements $requirements -HasCumulativeUpdate
        $r.Errors.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 1
    }
}

Describe 'Get-LunqHostWarning' {
    It 'предупреждает, если система старше образа' {
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 19045 | Should -BeLike '*19045 (Windows 10)*старше образа*'
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 22631 | Should -BeLike '*Windows 11 23H2*'
    }

    It 'молчит, если система той же версии или новее, или версия неизвестна' {
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 26300 | Should -BeNullOrEmpty
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 0 | Should -BeNullOrEmpty
    }
}

Describe 'Обновления и драйверы' {
    It 'обновления сортируются по номеру KB' {
        $dir = Join-Path $TestDrive 'upd'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($name in 'windows11.0-kb5080000-x64.msu', 'windows11.0-kb5079999-x64.msu', 'readme.txt') { Set-Content -LiteralPath (Join-Path $dir $name) -Value 'x' }
        $files = Get-LunqUpdateFiles -Path $dir
        @($files | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb5079999-x64.msu', 'windows11.0-kb5080000-x64.msu')
    }

    It 'в установщик и WinRE идут только обновления самой Windows' {
        $files = @('windows11.0-kb1-x64.msu', 'windows11.0-kb2-x64-ndp481.msu', 'office-kb3.cab') | ForEach-Object { [pscustomobject]@{ Name = $_ } }
        @(Select-LunqPEUpdates $files | ForEach-Object { $_.Name }) | Should -Be @('windows11.0-kb1-x64.msu')
        Test-CumulativeUpdate $files | Should -BeTrue
        Test-CumulativeUpdate @([pscustomobject]@{ Name = 'office-kb3.cab' }) | Should -BeFalse
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

Describe 'ConvertTo-LunqUtf8Bom' {
    BeforeAll {
        $convert = { param($Path) & (Get-Module LunqDebloater) { param($p) ConvertTo-LunqUtf8Bom -Path $p } $Path }
    }

    It 'UTF-8 без BOM с русским текстом пересохраняется с BOM' {
        $path = Join-Path $TestDrive 'ru.ps1'
        [IO.File]::WriteAllText($path, "Write-Host 'Готово'", (New-Object Text.UTF8Encoding($false)))
        & $convert $path | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [IO.File]::ReadAllText($path) | Should -Be "Write-Host 'Готово'"
    }

    It 'файл только с латиницей и файл с BOM не меняются' {
        $ascii = Join-Path $TestDrive 'en.ps1'
        [IO.File]::WriteAllText($ascii, "Write-Host 'Done'", (New-Object Text.UTF8Encoding($false)))
        & $convert $ascii | Should -BeFalse
        $bom = Join-Path $TestDrive 'bom.ps1'
        [IO.File]::WriteAllText($bom, "Write-Host 'Готово'", (New-Object Text.UTF8Encoding($true)))
        & $convert $bom | Should -BeFalse
    }

    It 'файл не в UTF-8 (например, ANSI) не меняется' {
        $path = Join-Path $TestDrive 'ansi.ps1'
        [IO.File]::WriteAllBytes($path, [byte[]](0x57, 0x20, 0xC3, 0xEE, 0xF2, 0xEE, 0xE2, 0xEE))
        & $convert $path | Should -BeFalse
    }
}

Describe 'Файл ответов' {
    BeforeAll {
        $regionInfo = [pscustomobject]@{ Locale = 'ru-RU'; InputLocale = '0419:00000419;0409:00000409'; Keyboards = @('ru-RU', 'en-US'); TimeZone = 'Russian Standard Time' }
        function Get-Answers {
            param([switch]$Oobe, [switch]$Region, [switch]$Bypass, [switch]$LocalAccount, [string]$Language = 'ru-RU', [string]$Command)
            $answers = [pscustomobject]@{ Oobe = [bool]$Oobe; Region = $(if ($Region) { $regionInfo } else { $null }); Bypass = [bool]$Bypass; LocalAccount = [bool]$LocalAccount }
            $text = & (Get-Module LunqDebloater) { param($a, $l, $c) New-LunqUnattendXml -Unattend $a -Architecture 'amd64' -ImageLanguage $l -FirstLogonCommand $c } $answers $Language $Command
            [xml]$text
        }
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
    }

    It 'все пункты сразу дают корректный XML' {
        $xml = Get-Answers -Oobe -Region -Bypass -LocalAccount -Command 'cmd.exe /c start "" powershell.exe -File "x.ps1"'
        $xml | Should -Not -BeNullOrEmpty
        @(Select-Xml -Xml $xml -XPath '//u:RunSynchronousCommand' -Namespace $ns).Count | Should -Be 3
        (Select-Xml -Xml $xml -XPath '//u:HideOnlineAccountScreens' -Namespace $ns).Node.InnerText | Should -Be 'true'
        (Select-Xml -Xml $xml -XPath '//u:ProtectYourPC' -Namespace $ns).Node.InnerText | Should -Be '3'
        (Select-Xml -Xml $xml -XPath '//u:FirstLogonCommands//u:CommandLine' -Namespace $ns).Node.InnerText | Should -Be 'cmd.exe /c start "" powershell.exe -File "x.ps1"'
    }

    It 'в windowsPE заданы все поля первой страницы установщика' {
        $xml = Get-Answers -Oobe -Region
        $winpe = (Select-Xml -Xml $xml -XPath "//u:component[@name='Microsoft-Windows-International-Core-WinPE']" -Namespace $ns).Node
        $winpe | Should -Not -BeNullOrEmpty
        $winpe.SetupUILanguage.UILanguage | Should -Be 'ru-RU'
        $winpe.InputLocale | Should -Be '0419:00000419;0409:00000409'
        $winpe.SystemLocale | Should -Be 'ru-RU'
        $winpe.UILanguage | Should -Be 'ru-RU'
        $winpe.UserLocale | Should -Be 'ru-RU'
    }

    It 'без региона нет языковых разделов и часового пояса' {
        $xml = Get-Answers -Oobe
        Select-Xml -Xml $xml -XPath "//u:component[@name='Microsoft-Windows-International-Core-WinPE']" -Namespace $ns | Should -BeNullOrEmpty
        Select-Xml -Xml $xml -XPath '//u:TimeZone' -Namespace $ns | Should -BeNullOrEmpty
        Select-Xml -Xml $xml -XPath '//u:RunSynchronous' -Namespace $ns | Should -BeNullOrEmpty
    }

    It 'язык образа берётся без пометки (Default)' {
        Get-LunqImageLanguage -Image ([pscustomobject]@{ Languages = @('en-US', 'ru-RU (Default)'); DefaultLanguageIndex = 1 }) | Should -Be 'ru-RU'
        Get-LunqImageLanguage -Image ([pscustomobject]@{ ImageName = 'x' }) | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-LunqArgumentList' {
    It 'ключи, списки и значения' {
        $bound = [ordered]@{ Index = 6; SkipCategory = @('drivers', 'store'); Force = [switch]$true; KeepWorkDir = [switch]$false }
        $result = ConvertTo-LunqArgumentList -BoundParameters $bound
        $result | Should -Be @('-Index', '6', '-SkipCategory', 'drivers,store', '-Force')
    }

    It 'в кавычках обратная косая черта в конце удваивается' {
        $bound = [ordered]@{ DriversPath = 'D:\' ; Label = 'MY WIN' }
        $result = ConvertTo-LunqArgumentList -BoundParameters $bound -Quote
        $result | Should -Be @('-DriversPath', '"D:\\"', '-Label', '"MY WIN"')
    }

    It 'относительные пути становятся полными' {
        $bound = [ordered]@{ WorkDir = 'work' }
        $result = ConvertTo-LunqArgumentList -BoundParameters $bound -PathParameters 'WorkDir'
        [IO.Path]::IsPathRooted($result[1]) | Should -BeTrue
    }
}

Describe 'Test-LunqPrerequisites: остатки прошлого запуска' {
    BeforeAll {
        $work = Join-Path $TestDrive 'w'
        $iso = Join-Path $TestDrive 'in.iso'
        Set-Content -LiteralPath $iso -Value 'iso'
        Mock -ModuleName LunqDebloater Get-LunqDriveInfo { [pscustomobject]@{ Name = 'T:\'; DriveFormat = 'NTFS'; AvailableFreeSpace = [long]500GB } }
        Mock -ModuleName LunqDebloater Find-Oscdimg { 'oscdimg.exe' }
        Mock -ModuleName LunqDebloater Write-Host { }
    }

    It 'свой смонтированный образ не считается предупреждением' {
        $own = Join-Path $work 'mount'
        Mock -ModuleName LunqDebloater Get-WindowsImage { [pscustomobject]@{ Path = $own } } -ParameterFilter { $Mounted }
        $r = Test-LunqPrerequisites -IsoPath $iso -WorkDir $work -OutputIso (Join-Path $TestDrive 'out.iso') -OwnMountPaths $own
        $r.Warnings | Should -Be 0
        $r.Errors | Should -Be 0
    }

    It 'чужой смонтированный образ даёт предупреждение' {
        Mock -ModuleName LunqDebloater Get-WindowsImage { [pscustomobject]@{ Path = 'C:\Other\mount' } } -ParameterFilter { $Mounted }
        $r = Test-LunqPrerequisites -IsoPath $iso -WorkDir $work -OutputIso (Join-Path $TestDrive 'out.iso') -OwnMountPaths (Join-Path $work 'mount')
        $r.Warnings | Should -Be 1
    }
}

Describe 'Строки интерфейса' {
    BeforeAll {
        $script:Repo = Split-Path $PSScriptRoot -Parent
        $script:Tables = & (Get-Module LunqDebloater) { @{ ru = Import-LunqStrings -Language ru; en = Import-LunqStrings -Language en } }
        function Get-Placeholders([string]$Text) {
            @([regex]::Matches(($Text -replace '\{\{|\}\}', ''), '\{(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
        }
    }

    It 'в русской и английской таблицах одни и те же ключи' {
        $ru = @($script:Tables.ru.Keys | Sort-Object)
        $en = @($script:Tables.en.Keys | Sort-Object)
        @(Compare-Object $ru $en | ForEach-Object { "$($_.InputObject) $($_.SideIndicator)" }) | Should -BeNullOrEmpty
    }

    It 'у каждого ключа одинаковые подстановки {N} в обоих языках' {
        $mismatch = foreach ($key in $script:Tables.ru.Keys) {
            if ($script:Tables.en.ContainsKey($key) -and ((Get-Placeholders $script:Tables.ru[$key]) -join ',') -ne ((Get-Placeholders $script:Tables.en[$key]) -join ',')) { $key }
        }
        @($mismatch) | Should -BeNullOrEmpty
    }

    It 'каждый ключ из кода есть в таблицах' {
        $files = @(Get-Item -LiteralPath (Join-Path $script:Repo 'LunqDebloater.ps1')) +
            @(Get-ChildItem -LiteralPath (Join-Path $script:Repo 'Modules\LunqDebloater\Private') -Filter '*.ps1' -File)
        $missing = foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($match in [regex]::Matches($text, "Get-LunqText\s+'([^']+)'")) {
                $key = $match.Groups[1].Value
                if (-not $script:Tables.ru.ContainsKey($key)) { "$($file.Name): $key" }
            }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'в английской таблице нет русских букв' {
        @($script:Tables.en.Keys | Where-Object { $script:Tables.en[$_] -match '[А-Яа-яЁё]' }) | Should -BeNullOrEmpty
    }

    It 'текст профиля: строка или перевод, запасной язык английский' {
        & (Get-Module LunqDebloater) {
            try {
                Set-LunqLanguage -Language en
                Get-LunqLocalized 'Просто строка' | Should -Be 'Просто строка'
                Get-LunqLocalized ([pscustomobject]@{ ru = 'Приложения'; en = 'Apps' }) | Should -Be 'Apps'
                Set-LunqLanguage -Language ru
                Get-LunqLocalized ([pscustomobject]@{ ru = 'Приложения'; en = 'Apps' }) | Should -Be 'Приложения'
                Get-LunqLocalized ([pscustomobject]@{ en = 'Apps only' }) | Should -Be 'Apps only'
                Get-LunqLocalized $null | Should -Be ''
            }
            finally { Set-LunqLanguage -Language ru }
        }
    }

    It 'профиль по умолчанию переведён целиком' {
        & (Get-Module LunqDebloater) {
            param($Path)
            try {
                Set-LunqLanguage -Language en
                $loaded = Read-LunqProfile -Path $Path
                ($loaded.Description + ($loaded.Categories | ForEach-Object { $_.Name + $_.Description })) | Should -Not -Match '[А-Яа-яЁё]'
            }
            finally { Set-LunqLanguage -Language ru }
        } $script:ProfilePath
    }
}
