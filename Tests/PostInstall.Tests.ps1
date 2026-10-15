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
        $xml = [xml](Get-Content -LiteralPath (Join-Path $mount 'Windows\System32\Sysprep\unattend.xml') -Raw -Encoding UTF8)
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        $component = (Select-Xml -Xml $xml -XPath "//u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']" -Namespace $ns).Node
        $component.processorArchitecture | Should -Be 'amd64'
        (Select-Xml -Xml $xml -XPath '//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine' -Namespace $ns).Node.InnerText |
            Should -Be 'cmd.exe /c start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Lunq\FirstLogon.ps1"'
        # По этой пометке скрипт первого входа узнаёт свой unattend.xml и удаляет его в конце.
        Get-Content -LiteralPath (Join-Path $mount 'Windows\System32\Sysprep\unattend.xml') -Raw | Should -Match 'Created by LunqDebloater'
    }
}

Describe 'Файл ответов' {
    BeforeAll {
        $regionInfo = [pscustomobject]@{ Locale = 'en-GB'; SystemLocale = 'ru-RU'; InputLocale = '0419:00000419;0409:00000409'; Keyboards = @('ru-RU', 'en-US'); TimeZone = 'Russian Standard Time' }
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
    }

    It 'язык образа берётся без пометки (Default)' {
        & (Get-Module LunqDebloater) { Get-LunqImageLanguage -Image ([pscustomobject]@{ Languages = @('en-US', 'ru-RU (Default)'); DefaultLanguageIndex = 1 }) } | Should -Be 'ru-RU'
        & (Get-Module LunqDebloater) { Get-LunqImageLanguage -Image ([pscustomobject]@{ ImageName = 'x' }) } | Should -BeNullOrEmpty
    }
}
