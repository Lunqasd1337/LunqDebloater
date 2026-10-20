#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Что кладётся в образ для установки и первого входа (Private\PostInstall.ps1, Private\Unattend.ps1).

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

Describe 'Install-LunqFirstLogon' {
    It 'кладёт в образ скрипт первого входа, свои скрипты, язык и unattend.xml с командой' {
        $config = Join-Path $TestDrive 'logon'
        $scripts = Join-Path $config 'Scripts'
        New-Item -ItemType Directory -Path (Join-Path $scripts 'data') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $config 'Apps.txt') -Value @('# комментарий', '7zip.7zip')
        [IO.File]::WriteAllText((Join-Path $scripts '10-привет.ps1'), "Write-Host 'Привет'", (New-Object Text.UTF8Encoding($false)))
        Set-Content -LiteralPath (Join-Path $scripts 'data\key.txt') -Value 'secret'
        [IO.File]::WriteAllText((Join-Path $scripts 'data\run.cmd'), "@echo off`r`necho Привет", (New-Object Text.UTF8Encoding($false)))
        Set-Content -LiteralPath (Join-Path $scripts '.gitkeep') -Value ''
        $mount = Join-Path $TestDrive 'logonmount'
        New-Item -ItemType Directory -Path $mount -Force | Out-Null
        $result = & (Get-Module LunqDebloater) {
            param($c, $s, $m)
            $logon = Get-LunqFirstLogon -AppsPath (Join-Path $c 'Apps.txt') -ScriptsPath $s
            Install-LunqFirstLogon -MountPath $m -FirstLogon $logon -Architecture amd64
        } $config $scripts $mount 6>$null
        $result.Done | Should -Be @('7zip.7zip')
        $lunq = Join-Path $mount 'Windows\Setup\Scripts\Lunq'
        Test-Path -LiteralPath (Join-Path $lunq 'FirstLogon.ps1') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $lunq 'Language.txt') -Raw | Should -Be 'ru'
        Test-Path -LiteralPath (Join-Path $lunq 'User\Apps.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $lunq 'User\data\key.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $lunq 'User\.gitkeep') | Should -BeFalse
        # Скрипт в UTF-8 без BOM пересохранён с BOM, иначе Windows PowerShell 5.1 сломает русский текст.
        $bytes = [IO.File]::ReadAllBytes((Join-Path $lunq 'User\10-привет.ps1'))
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        # Остальные файлы не меняются: .cmd с BOM не запускается.
        $bytes = [IO.File]::ReadAllBytes((Join-Path $lunq 'User\data\run.cmd'))
        $bytes[0..2] | Should -Be @(0x40, 0x65, 0x63)
        $xml = [xml](Get-Content -LiteralPath (Join-Path $mount 'Windows\System32\Sysprep\unattend.xml') -Raw -Encoding UTF8)
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        $component = (Select-Xml -Xml $xml -XPath "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']" -Namespace $ns).Node
        $component.processorArchitecture | Should -Be 'amd64'
        (Select-Xml -Xml $xml -XPath '//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine' -Namespace $ns).Node.InnerText |
            Should -Be 'cmd.exe /c start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Lunq\FirstLogon.ps1"'
        # По этой пометке скрипт первого входа узнаёт свой unattend.xml и удаляет его в конце.
        Get-Content -LiteralPath (Join-Path $mount 'Windows\System32\Sysprep\unattend.xml') -Raw | Should -Match 'Created by LunqDebloater'
    }

    It 'программы из Uninstall: скрипты удаления в образе и запись для отката' {
        $mount = Join-Path $TestDrive 'uninstallmount'
        New-Item -ItemType Directory -Path $mount -Force | Out-Null
        $restore = & (Get-Module LunqDebloater) {
            param($m)
            $lunqProfile = [pscustomobject]@{ Categories = @([pscustomobject]@{ Id = 'edge'; Name = 'Microsoft Edge'; Enabled = $true; Uninstall = @('MicrosoftEdge') }) }
            $restore = New-LunqRestoreData -LunqProfile $lunqProfile -Source Image
            $logon = [pscustomobject]@{ AppsPath = 'Apps.txt'; Apps = @(); ScriptsPath = 'Scripts'; Scripts = @(); Uninstall = @('MicrosoftEdge') }
            $result = Install-LunqFirstLogon -MountPath $m -FirstLogon $logon -Architecture amd64 -Restore $restore
            $result.Summary | Should -Be 'удаление: Microsoft Edge'
            $restore
        } $mount 6>$null
        $lunq = Join-Path $mount 'Windows\Setup\Scripts\Lunq'
        Test-Path -LiteralPath (Join-Path $lunq 'Uninstall\Uninstall.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $lunq 'Uninstall\EdgeRemover\RemoveEdge.ps1') | Should -BeTrue
        # Своих скриптов нет: папка User пуста, а в итоге нет «скриптов: 0».
        @(Get-ChildItem -LiteralPath (Join-Path $lunq 'User')).Count | Should -Be 0
        @($restore.Categories[0].Uninstall | ForEach-Object { $_.Name }) | Should -Be @('MicrosoftEdge')
    }
}

Describe 'Install-LunqFirstLogon: пароль учётной записи' {
    It 'без программ и скриптов кладёт отметку для вопроса о пароле' {
        $mount = Join-Path $TestDrive 'accountmount'
        New-Item -ItemType Directory -Path $mount -Force | Out-Null
        & (Get-Module LunqDebloater) {
            param($m)
            $logon = [pscustomobject]@{ AppsPath = 'Apps.txt'; Apps = @(); ScriptsPath = 'Scripts'; Scripts = @(); LocalAccount = 'Иван' }
            $result = Install-LunqFirstLogon -MountPath $m -FirstLogon $logon -Architecture amd64
            $result.Summary | Should -Be 'пароль для Иван'
        } $mount 6>$null
        Get-Content -LiteralPath (Join-Path $mount 'Windows\Setup\Scripts\Lunq\LocalAccount.txt') -Encoding UTF8 | Should -Be 'Иван'
    }
}

Describe 'Install-LunqFirstLogon: права' {
    It 'папки User и Wifi закрываются от пользователей уже в образе, до копирования файлов' {
        # Первый вход закрывает их только после согласия в UAC: без него пароли Wi-Fi остались бы
        # открыты всем пользователям, ведь права наследуются от C:\Windows.
        $wifi = Join-Path $TestDrive 'aclwifi'
        New-Item -ItemType Directory -Path $wifi -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $wifi 'Home.xml') -Value '<WLANProfile />'
        $mount = Join-Path $TestDrive 'aclmount'
        New-Item -ItemType Directory -Path $mount -Force | Out-Null
        $script:Order = New-Object System.Collections.Generic.List[string]
        Mock Set-LunqAdminOnlyAccess -ModuleName LunqDebloater { $script:Order.Add("protect $(Split-Path $Path -Leaf) files=$(@(Get-ChildItem -LiteralPath $Path).Count)") }
        & (Get-Module LunqDebloater) {
            param($m, $w)
            $logon = [pscustomobject]@{ AppsPath = 'Apps.txt'; Apps = @(); ScriptsPath = 'Scripts'; Scripts = @(); Wifi = @('Home'); WifiPath = $w }
            $null = Install-LunqFirstLogon -MountPath $m -FirstLogon $logon -Architecture amd64
        } $mount $wifi 6>$null
        $script:Order | Should -Be @('protect User files=0', 'protect Wifi files=0')
        Test-Path -LiteralPath (Join-Path $mount 'Windows\Setup\Scripts\Lunq\Wifi\Home.xml') | Should -BeTrue
    }
}

Describe 'Файл ответов' {
    BeforeAll {
        $regionInfo = [pscustomobject]@{ Locale = 'en-GB'; SystemLocale = 'ru-RU'; InputLocale = '0419:00000419;0409:00000409'; Keyboards = @('ru-RU', 'en-US'); TimeZone = 'Russian Standard Time' }
        function Get-Answers {
            param([switch]$Oobe, [switch]$Region, [switch]$Bypass, [switch]$LocalAccount, [string]$Language = 'ru-RU', [string]$Command, [string]$AccountName)
            $answers = [pscustomobject]@{ Oobe = [bool]$Oobe; Region = $(if ($Region) { $regionInfo } else { $null }); Bypass = [bool]$Bypass; LocalAccount = [bool]$LocalAccount }
            if ($AccountName) { $answers | Add-Member -NotePropertyName AccountName -NotePropertyValue $AccountName }
            $text = & (Get-Module LunqDebloater) { param($a, $l, $c) New-LunqUnattendXml -Unattend $a -Architecture 'amd64' -ImageLanguage $l -FirstLogonCommand $c } $answers $Language $Command
            [xml]$text
        }
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
    }

    It 'все пункты сразу дают корректный XML' {
        $xml = Get-Answers -Oobe -Region -Bypass -LocalAccount -Command 'cmd.exe /c start "" powershell.exe -File "x.ps1"'
        $xml | Should -Not -BeNullOrEmpty
        @(Select-Xml -Xml $xml -XPath "//u:settings[@pass='windowsPE']//u:RunSynchronousCommand" -Namespace $ns).Count | Should -Be 3
        (Select-Xml -Xml $xml -XPath '//u:HideOnlineAccountScreens' -Namespace $ns).Node.InnerText | Should -Be 'true'
        (Select-Xml -Xml $xml -XPath "//u:settings[@pass='specialize']//u:RunSynchronousCommand/u:Path" -Namespace $ns).Node.InnerText | Should -BeLike '*BypassNRO*'
        (Select-Xml -Xml $xml -XPath '//u:TimeZone' -Namespace $ns).Node.InnerText | Should -Be 'Russian Standard Time'
        (Select-Xml -Xml $xml -XPath '//u:ProtectYourPC' -Namespace $ns).Node.InnerText | Should -Be '3'
        (Select-Xml -Xml $xml -XPath '//u:FirstLogonCommands//u:CommandLine' -Namespace $ns).Node.InnerText | Should -Be 'cmd.exe /c start "" powershell.exe -File "x.ps1"'
    }

    It 'в windowsPE заданы все поля первой страницы установщика' {
        $xml = Get-Answers -Oobe -Region
        $winpe = (Select-Xml -Xml $xml -XPath "//u:component[@name='Microsoft-Windows-International-Core-WinPE']" -Namespace $ns).Node
        $winpe | Should -Not -BeNullOrEmpty
        $winpe.SetupUILanguage.UILanguage | Should -Be 'ru-RU'
        $winpe.InputLocale | Should -Be '0419:00000419;0409:00000409'
        # Кодовая страница из системного языка, формат чисел и дат из пользовательского.
        $winpe.SystemLocale | Should -Be 'ru-RU'
        $winpe.UILanguage | Should -Be 'ru-RU'
        $winpe.UserLocale | Should -Be 'en-GB'
        $oobe = (Select-Xml -Xml $xml -XPath "//u:component[@name='Microsoft-Windows-International-Core']" -Namespace $ns).Node
        $oobe.SystemLocale | Should -Be 'ru-RU'
        $oobe.UserLocale | Should -Be 'en-GB'
    }

    It 'без региона нет языковых разделов и часового пояса' {
        $xml = Get-Answers -Oobe
        Select-Xml -Xml $xml -XPath "//u:component[@name='Microsoft-Windows-International-Core-WinPE']" -Namespace $ns | Should -BeNullOrEmpty
        Select-Xml -Xml $xml -XPath '//u:TimeZone' -Namespace $ns | Should -BeNullOrEmpty
        Select-Xml -Xml $xml -XPath '//u:RunSynchronous' -Namespace $ns | Should -BeNullOrEmpty
        Select-Xml -Xml $xml -XPath "//u:settings[@pass='specialize']" -Namespace $ns | Should -BeNullOrEmpty
    }

    It 'локальная учётная запись без региона: в specialize только BypassNRO' {
        $xml = Get-Answers -LocalAccount
        Select-Xml -Xml $xml -XPath '//u:TimeZone' -Namespace $ns | Should -BeNullOrEmpty
        $commands = @(Select-Xml -Xml $xml -XPath "//u:settings[@pass='specialize']//u:RunSynchronousCommand/u:Path" -Namespace $ns)
        $commands.Count | Should -Be 1
        $commands[0].Node.InnerText | Should -Be 'reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f'
    }

    It 'учётная запись с именем создаётся в specialize, группа берётся по SID, экран учётной записи скрыт' {
        $xml = Get-Answers -LocalAccount -AccountName 'Иван&Co'
        $commands = @(Select-Xml -Xml $xml -XPath "//u:settings[@pass='specialize']//u:RunSynchronousCommand/u:Path" -Namespace $ns | ForEach-Object { $_.Node.InnerText })
        $commands.Count | Should -Be 2
        $commands[0] | Should -BeLike '*BypassNRO*'
        $commands[1] | Should -BeLike "*New-LocalUser -Name 'Иван&Co' -NoPassword*"
        $commands[1] | Should -BeLike "*Add-LocalGroupMember -SID S-1-5-32-544 -Member 'Иван&Co'*"
        # Path у RunSynchronousCommand не длиннее 259 символов даже с самым длинным именем.
        $long = Get-Answers -LocalAccount -AccountName ('a' * 20)
        @(Select-Xml -Xml $long -XPath "//u:RunSynchronousCommand/u:Path" -Namespace $ns)[-1].Node.InnerText.Length | Should -BeLessOrEqual 259
        (Select-Xml -Xml $xml -XPath '//u:HideLocalAccountScreen' -Namespace $ns).Node.InnerText | Should -Be 'true'
        # Пароля в файле ответов нет.
        Select-Xml -Xml $xml -XPath '//u:Password' -Namespace $ns | Should -BeNullOrEmpty
        & (Get-Module LunqDebloater) { param($a) Format-LunqUnattendSummary -Unattend $a } ([pscustomobject]@{ Oobe = $false; Region = $null; Bypass = $false; LocalAccount = $true; AccountName = 'Иван' }) |
            Should -Be 'локальная учётная запись Иван без пароля'
    }

    It 'без имени учётная запись не создаётся: имя и пароль спросит установка' {
        $xml = Get-Answers -LocalAccount
        Select-Xml -Xml $xml -XPath '//u:HideLocalAccountScreen' -Namespace $ns | Should -BeNullOrEmpty
        ($xml.OuterXml) | Should -Not -Match 'New-LocalUser'
    }

    It 'имя учётной записи проверяется по правилам Windows' {
        $check = { param($n) & (Get-Module LunqDebloater) { param($x) Test-LunqAccountName -Name $x } $n }
        & $check 'Иван' | Should -BeNullOrEmpty
        & $check 'user.name-1' | Should -BeNullOrEmpty
        & $check '' | Should -Match 'пустое'
        & $check ('a' * 21) | Should -Match 'длиннее 20'
        foreach ($bad in 'a/b', 'a@b', 'a:b', "a'b", 'a%b', 'a"b', 'a\b') { & $check $bad | Should -Match 'недопустимые' }
        & $check ' user' | Should -Match 'пробелом'
        & $check 'user.' | Should -Match 'точкой'
        & $check 'Administrator' | Should -Match 'занято'
    }

    It 'язык образа берётся без пометки (Default)' {
        & (Get-Module LunqDebloater) { Get-LunqImageLanguage -Image ([pscustomobject]@{ Languages = @('en-US', 'ru-RU (Default)'); DefaultLanguageIndex = 1 }) } | Should -Be 'ru-RU'
        & (Get-Module LunqDebloater) { Get-LunqImageLanguage -Image ([pscustomobject]@{ ImageName = 'x' }) } | Should -BeNullOrEmpty
    }
}
