#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Модуль целиком: манифест, справка скрипта, аргументы перезапуска и таблицы строк.

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
