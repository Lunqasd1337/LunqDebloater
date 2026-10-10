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
