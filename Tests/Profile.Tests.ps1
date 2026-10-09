#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Чтение профиля (Private\Profile.ps1): формат, проверка записей, категории и шаблоны имён.

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

    It 'сразу отвергает запись без типа понятным текстом' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Name = 'v'; Value = 1 }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*не указан Type*'
    }

    It 'списки в категориях профиля по умолчанию отсортированы' {
        $json = Get-Content -LiteralPath $script:ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($category in $json.Categories) {
            foreach ($list in 'Appx', 'Capabilities', 'Features', 'Packages') {
                if (-not ($category.PSObject.Properties.Name -contains $list)) { continue }
                $names = [string[]]@($category.$list)
                $sorted = [string[]]@($names)
                [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
                $names | Should -Be $sorted -Because "$($category.Id).$list"
            }
        }
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

Describe 'Test-NamePattern' {
    It 'шаблоны с *' {
        InModuleScope LunqDebloater {
            Test-NamePattern -Name 'Browser.InternetExplorer~~~~0.0.11.0' -Patterns 'Browser.InternetExplorer*' | Should -BeTrue
            Test-NamePattern -Name 'Microsoft.BingNews' -Patterns 'Microsoft.Bing' | Should -BeFalse
        }
    }
}
