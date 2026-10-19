#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Проверки загрузчика Install.ps1 (запуск одной командой irm | iex). Сеть и запуск LunqDebloater
# заменены заглушками, релиз собирается в TestDrive.

BeforeAll {
    $script:Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install.ps1'
    # Функции загрузчика берутся из его текста без выполнения: в конце файла стоит сам запуск.
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($script:Source, [ref]$tokens, [ref]$errors)
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    function New-TestRelease {
        # Распакованный релиз: главный скрипт, модуль и Config.
        param([string]$Root, [string]$Version, [hashtable]$Config)
        New-Item -ItemType Directory -Path (Join-Path $Root 'Modules\LunqDebloater\Private') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'LunqDebloater.ps1') -Value "# $Version"
        Set-Content -LiteralPath (Join-Path $Root "Modules\LunqDebloater\Private\$Version.ps1") -Value "# $Version"
        foreach ($name in $Config.Keys) {
            $file = Join-Path (Join-Path $Root 'Config') $name
            New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
            Set-Content -LiteralPath $file -Value $Config[$name]
        }
    }

    $script:OldOS = $env:OS
    $env:OS = 'Windows_NT'
}

AfterAll {
    $env:OS = $script:OldOS
}

Describe 'Install.ps1' {
    It 'только ASCII и без BOM: irm передаёт его в iex текстом' {
        $bytes = [IO.File]::ReadAllBytes($script:Source)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'разбирается без ошибок' {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($script:Source, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Test-LunqInstallFolder' {
    It 'новая, пустая папка и прежняя установка подходят, чужая папка нет' {
        Test-LunqInstallFolder -Path (Join-Path $TestDrive 'none') | Should -BeTrue
        $empty = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'empty')
        Test-LunqInstallFolder -Path $empty.FullName | Should -BeTrue
        $own = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'own')
        Set-Content -LiteralPath (Join-Path $own.FullName 'LunqDebloater.ps1') -Value ''
        Test-LunqInstallFolder -Path $own.FullName | Should -BeTrue
        $foreign = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'foreign')
        Set-Content -LiteralPath (Join-Path $foreign.FullName 'photo.jpg') -Value ''
        Test-LunqInstallFolder -Path $foreign.FullName | Should -BeFalse
    }

    It 'клон репозитория не принимается за прежнюю установку, а установка с файлом состояния принимается' {
        # В клоне тоже есть LunqDebloater.ps1, но папки релиза заменились бы целиком вместе с несохранённой работой.
        $clone = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'clone')
        Set-Content -LiteralPath (Join-Path $clone.FullName 'LunqDebloater.ps1') -Value ''
        New-Item -ItemType Directory -Path (Join-Path $clone.FullName '.git') | Out-Null
        Test-LunqInstallFolder -Path $clone.FullName | Should -BeFalse
        Set-Content -LiteralPath (Join-Path $clone.FullName '.lunq-install.json') -Value '{}'
        Test-LunqInstallFolder -Path $clone.FullName | Should -BeTrue
    }
}

Describe 'Install-LunqFiles' {
    It 'обновление заменяет программу, а изменённые пользователем файлы Config оставляет' {
        $target = Join-Path $TestDrive 'Lunq'
        $old = Join-Path $TestDrive 'v1'
        New-TestRelease -Root $old -Version 'v1' -Config @{ 'Apps.txt' = 'v1'; 'Profile.json' = 'v1' }
        @(Install-LunqFiles -Source $old -Destination $target -Tag 'v1') | Should -BeNullOrEmpty

        # Пользователь правит Apps.txt и кладёт рядом свой ISO.
        Set-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') -Value 'my apps'
        Set-Content -LiteralPath (Join-Path $target 'Win11.iso') -Value 'iso'

        $new = Join-Path $TestDrive 'v2'
        New-TestRelease -Root $new -Version 'v2' -Config @{ 'Apps.txt' = 'v2'; 'Profile.json' = 'v2'; 'Scripts\10-new.ps1' = 'v2' }
        $kept = Install-LunqFiles -Source $new -Destination $target -Tag 'v2'

        $kept | Should -Be @('Apps.txt')
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be 'my apps'
        Get-Content -LiteralPath (Join-Path $target 'Config\Profile.json') | Should -Be 'v2'
        Get-Content -LiteralPath (Join-Path $target 'Config\Scripts\10-new.ps1') | Should -Be 'v2'
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -Be '# v2'
        # Файл, убранный из модуля, не остаётся и не подключается.
        Test-Path -LiteralPath (Join-Path $target 'Modules\LunqDebloater\Private\v1.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'Modules\LunqDebloater\Private\v2.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'Win11.iso') | Should -BeTrue
        (Get-LunqInstallState -Path $target).Tag | Should -Be 'v2'
    }

    It 'изменённый файл остаётся и на следующих обновлениях' {
        $target = Join-Path $TestDrive 'Lunq2'
        $v1 = Join-Path $TestDrive 'r1'
        New-TestRelease -Root $v1 -Version 'v1' -Config @{ 'Apps.txt' = 'v1' }
        Install-LunqFiles -Source $v1 -Destination $target -Tag 'v1' | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') -Value 'my apps'
        foreach ($version in 'v2', 'v3') {
            $release = Join-Path $TestDrive "r$version"
            New-TestRelease -Root $release -Version $version -Config @{ 'Apps.txt' = $version }
            Install-LunqFiles -Source $release -Destination $target -Tag $version | Should -Be @('Apps.txt')
        }
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be 'my apps'
    }
}

Describe 'Invoke-LunqInstall' {
    BeforeEach {
        $script:Archive = Join-Path $TestDrive ('archive-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-TestRelease -Root (Join-Path $script:Archive 'LunqDebloater-1.7.0') -Version 'v1.7.0' -Config @{ 'Apps.txt' = '7zip.7zip' }
        Mock Write-Host { }
        Mock Start-LunqDebloater { }
        Mock Get-LunqLatestRelease {
            [pscustomobject]@{
                Tag = 'v1.7.0'; ZipUrl = 'https://example.invalid/v1.7.0.zip'
                AssetUrl = 'https://example.invalid/download/v1.7.0/LunqDebloater-v1.7.0.zip'; SumsUrl = 'https://example.invalid/download/v1.7.0/SHA256SUMS'
            }
        }
        # Релиз с архивом и SHA256SUMS, как его выпускает release.yml.
        $script:Zip = Join-Path $script:Archive 'LunqDebloater-v1.7.0.zip'
        Compress-Archive -Path (Join-Path $script:Archive 'LunqDebloater-1.7.0') -DestinationPath $script:Zip
        $script:Sums = '{0}  LunqDebloater-v1.7.0.zip' -f (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:Zip -Destination $OutFile }
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value @('0000000000000000000000000000000000000000000000000000000000000000  other.zip', $script:Sums) } -ParameterFilter { $Uri -like '*SHA256SUMS' }
    }

    It 'папку установки могут менять только владелец, администраторы и SYSTEM' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $target = Join-Path $TestDrive 'Protected'
        Protect-LunqInstallFolder -Path $target
        $acl = Get-Acl -LiteralPath $target
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        $expected = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-32-544', 'S-1-5-18') | Sort-Object -Unique
        $sids | Should -Be $expected
    }

    It 'скачивает релиз, раскладывает его и запускает LunqDebloater' {
        $target = Join-Path $TestDrive 'Fresh'
        Invoke-LunqInstall -Path $target
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -Be '# v1.7.0'
        Get-Content -LiteralPath (Join-Path $target 'Config\Apps.txt') | Should -Be '7zip.7zip'
        Should -Invoke Start-LunqDebloater -Times 1 -Exactly -ParameterFilter { $Path -eq $target }
    }

    It 'та же версия уже стоит: не скачивает заново' {
        $target = Join-Path $TestDrive 'Same'
        Invoke-LunqInstall -Path $target
        Invoke-LunqInstall -Path $target
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*.zip' }
        Should -Invoke Start-LunqDebloater -Times 2 -Exactly
    }

    It 'GitHub недоступен: запускает установленную версию' {
        $target = Join-Path $TestDrive 'Offline'
        Invoke-LunqInstall -Path $target
        Mock Get-LunqLatestRelease { throw 'нет сети' }
        Mock Write-Warning { }
        Invoke-LunqInstall -Path $target
        Should -Invoke Write-Warning -Times 1 -Exactly
        Should -Invoke Start-LunqDebloater -Times 2 -Exactly
    }

    It 'архив сверяется с SHA256SUMS: не совпал, и ничего не установлено' {
        $target = Join-Path $TestDrive 'BadHash'
        $script:Sums = ('f' * 64) + '  LunqDebloater-v1.7.0.zip'
        { Invoke-LunqInstall -Path $target } | Should -Throw '*does not match its SHA256SUMS*'
        Test-Path -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -BeFalse
        Should -Invoke Start-LunqDebloater -Times 0 -Exactly
        # Архив релиза, а не архив тега, который собирает сам GitHub.
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://example.invalid/v1.7.0.zip' }
    }

    It 'у релиза до 1.12.0 нет SHA256SUMS: берётся архив тега с предупреждением' {
        $target = Join-Path $TestDrive 'OldRelease'
        Mock Invoke-WebRequest { throw 'The remote server returned an error: (404) Not Found.' } -ParameterFilter { $Uri -like '*SHA256SUMS' }
        Mock Write-Warning { }
        Invoke-LunqInstall -Path $target
        Get-Content -LiteralPath (Join-Path $target 'LunqDebloater.ps1') | Should -Be '# v1.7.0'
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*no SHA256SUMS*' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://example.invalid/v1.7.0.zip' }
    }

    It 'SHA256SUMS не скачался по другой причине: установка останавливается, а не берёт непроверенный архив' {
        $target = Join-Path $TestDrive 'SumsError'
        Mock Invoke-WebRequest { throw 'The operation has timed out.' } -ParameterFilter { $Uri -like '*SHA256SUMS' }
        { Invoke-LunqInstall -Path $target } | Should -Throw '*timed out*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*.zip' }
    }

    It 'чужую папку не трогает' {
        $foreign = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Photos')
        Set-Content -LiteralPath (Join-Path $foreign.FullName 'photo.jpg') -Value ''
        { Invoke-LunqInstall -Path $foreign.FullName } | Should -Throw '*not a LunqDebloater folder*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Start-LunqDebloater -Times 0 -Exactly
    }
}

Describe 'Get-LunqForeignItems' {
    BeforeAll {
        # В PowerShell на Linux нет Get-Acl, а заглушке нужна команда, которую она подменит.
        if (-not (Get-Command Get-Acl -ErrorAction SilentlyContinue)) {
            function script:Get-Acl { param([string]$LiteralPath) }
        }
    }

    It 'находит папку и файлы, владелец которых не вы и не администраторы, и файлы, права которых не прочитать' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Owned') -Force
        New-Item -ItemType Directory -Path (Join-Path $root.FullName 'Modules') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root.FullName 'LunqDebloater.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $root.FullName 'Modules\planted.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $root.FullName 'Modules\locked.ps1') -Value ''
        Mock Get-Acl {
            if ($LiteralPath -like '*locked.ps1') { throw 'Access denied' }
            $sid = if ($LiteralPath -like '*planted.ps1') { 'S-1-5-21-1-2-3-1002' } else { 'S-1-5-21-1-2-3-1001' }
            [pscustomobject]@{ Sid = $sid } | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) [pscustomobject]@{ Value = $this.Sid } } -PassThru
        }
        $foreign = Get-LunqForeignItems -Path $root.FullName -Trusted @('S-1-5-21-1-2-3-1001', 'S-1-5-32-544')
        @($foreign | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object) | Should -Be @('locked.ps1', 'planted.ps1')
        # Новой папки ещё нет: проверять нечего.
        (Get-LunqForeignItems -Path (Join-Path $TestDrive 'Missing') -Trusted @('S-1-5-32-544')).Count | Should -Be 0
    }

    It 'папка другого пользователя на диске с правами NTFS: установка отказывается' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Planted') -Force
        Mock Write-Host { }
        Mock Start-LunqDebloater { }
        Mock Get-LunqLatestRelease { throw 'не должен вызываться' }
        Mock Test-LunqAclDrive { $true }
        Mock Get-LunqForeignItems { , @('C:\Planted\LunqDebloater.ps1') }
        { Invoke-LunqInstall -Path $target.FullName } | Should -Throw '*belongs to another user*'
        Should -Invoke Start-LunqDebloater -Times 0 -Exactly
    }
}

Describe 'Get-LunqLatestRelease' {
    It 'API GitHub отказал (лимит запросов): версия берётся со страницы релизов' {
        Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 403 (rate limit exceeded).' }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [uri]'https://github.com/Lunqasd1337/LunqDebloater/releases/tag/v1.9.2' } }
        } -ParameterFilter { $Uri -like '*/releases/latest' }
        $release = Get-LunqLatestRelease
        $release.Tag | Should -Be 'v1.9.2'
        $release.ZipUrl | Should -Be 'https://github.com/Lunqasd1337/LunqDebloater/archive/refs/tags/v1.9.2.zip'
        $release.AssetUrl | Should -Be 'https://github.com/Lunqasd1337/LunqDebloater/releases/download/v1.9.2/LunqDebloater-v1.9.2.zip'
        $release.SumsUrl | Should -Be 'https://github.com/Lunqasd1337/LunqDebloater/releases/download/v1.9.2/SHA256SUMS'
        # В PowerShell 7 адрес лежит в RequestMessage.
        Mock Invoke-WebRequest {
            [pscustomobject]@{ BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://github.com/Lunqasd1337/LunqDebloater/releases/tag/v1.9.3' } } }
        } -ParameterFilter { $Uri -like '*/releases/latest' }
        (Get-LunqLatestRelease).Tag | Should -Be 'v1.9.3'
        # Страница не дала тега: видна исходная ошибка API.
        Mock Invoke-WebRequest { [pscustomobject]@{ BaseResponse = [pscustomobject]@{ ResponseUri = [uri]'https://github.com/login' } } } -ParameterFilter { $Uri -like '*/releases/latest' }
        { Get-LunqLatestRelease } | Should -Throw '*403*'
    }

    It 'окно из ярлыка (-Command без -NoExit) ждёт Enter после ошибки, открытая консоль нет' {
        Test-LunqClosingWindow -CommandLine @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm x | iex') | Should -BeTrue
        Test-LunqClosingWindow -CommandLine @('powershell.exe', '-c', 'irm x | iex') | Should -BeTrue
        Test-LunqClosingWindow -CommandLine @('powershell.exe', '-NoExit', '-Command', 'irm x | iex') | Should -BeFalse
        Test-LunqClosingWindow -CommandLine @('powershell.exe', '-NonInteractive', '-Command', 'irm x | iex') | Should -BeFalse
        Test-LunqClosingWindow -CommandLine @('powershell.exe') | Should -BeFalse
        Test-LunqClosingWindow -CommandLine @('powershell.exe', '-File', 'C:\x\Install.ps1') | Should -BeFalse
    }
}
