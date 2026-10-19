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
        $p.Categories.Count | Should -Be 10
        $p.Requirements.Build | Should -Be 26300
        ($p.Categories | Where-Object Id -eq 'drivers').Enabled | Should -BeFalse
        # Edge удаляется только по выбору: категория выключена.
        $edge = $p.Categories | Where-Object Id -eq 'edge'
        $edge.Enabled | Should -BeFalse
        $edge.FirstLogon | Should -Be @('RemoveEdge')
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

    It 'флаги в кавычках отвергаются, а не считаются включёнными' {
        # [bool]"false" в PowerShell равно $true: такая категория раньше молча включалась.
        $path = New-TestProfile @{ Categories = @(@{ Id = 'drivers'; Enabled = 'false' }) }
        { Read-LunqProfile -Path $path } | Should -Throw "*Categories[[]drivers].Enabled*true или false*'false'*"
        $path = New-TestProfile @{ Options = @{ RemoveFeaturePayload = 'false' }; Categories = @(@{ Id = 'a' }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*Options.RemoveFeaturePayload*'
        $path = New-TestProfile @{ Options = @{ RemoveFeaturePayload = $true }; Categories = @(@{ Id = 'a'; Enabled = $false }) }
        $p = Read-LunqProfile -Path $path
        $p.RemoveFeaturePayload | Should -BeTrue
        $p.Categories[0].Enabled | Should -BeFalse
    }

    It 'предупреждает об опечатках в именах полей, а профиль по умолчанию проходит без предупреждений' {
        $null = Read-LunqProfile -Path $script:ProfilePath -WarningVariable clean -WarningAction SilentlyContinue
        $clean | Should -BeNullOrEmpty
        $path = New-TestProfile @{ Categores = @(); Options = @{ RemovePayload = $true } }
        $null = Read-LunqProfile -Path $path -WarningVariable typos -WarningAction SilentlyContinue
        @($typos).Count | Should -Be 2
        ($typos -join "`n") | Should -Match 'неизвестное поле Categores'
        ($typos -join "`n") | Should -Match 'неизвестное поле Options\.RemovePayload'
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Capabilites = @('x'); Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Name = 'v'; Type = 'REG_DWORD'; Value = 1; Comment = 'y' }) }) }
        $null = Read-LunqProfile -Path $path -WarningVariable typos -WarningAction SilentlyContinue
        ($typos -join "`n") | Should -Match 'неизвестное поле Categories\[a\]\.Capabilites'
        ($typos -join "`n") | Should -Match 'неизвестное поле Categories\[a\]\.Registry\[0\]\.Comment'
    }

    It 'отвергает путь реестра с кустом в начале и CurrentControlSet в SYSTEM' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'HKLM\SOFTWARE\Policies'; Name = 'v'; Type = 'REG_DWORD'; Value = 1 }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*без HKLM\ и имени куста (HKLM)*'
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SYSTEM'; Path = 'CurrentControlSet\Control'; Name = 'v'; Type = 'REG_DWORD'; Value = 1 }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*ControlSet001*'
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SYSTEM'; Path = 'ControlSet001\Control'; Name = 'v'; Type = 'REG_DWORD'; Value = 1 }) }) }
        { Read-LunqProfile -Path $path } | Should -Not -Throw
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

    It 'неизвестное действие первого входа отвергается, а не пропускается молча' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'browser'; FirstLogon = @('RemoveEgde') }) }
        { Read-LunqProfile -Path $path } | Should -Throw "*у категории 'browser' неизвестное действие первого входа 'RemoveEgde'. Допустимо: RemoveEdge"
    }

    It 'сразу отвергает DWORD, который не число' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Name = 'v'; Type = 'REG_DWORD'; Value = 'abc' }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*не число*'
    }

    It 'сразу отвергает неизвестное действие' {
        $path = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = 'x'; Action = 'Rename' }) }) }
        { Read-LunqProfile -Path $path } | Should -Throw '*неизвестное действие*'
    }
    It 'отвергает путь реестра <Path>' -TestCases @(
        @{ Path = 'Policies\X\' }, @{ Path = '\Policies\X' }, @{ Path = 'Policies\\X' }, @{ Path = 'Policies/X' }
    ) {
        param($Path)
        $file = New-TestProfile @{ Categories = @(@{ Id = 'a'; Registry = @(@{ Hive = 'SOFTWARE'; Path = $Path; Action = 'DeleteKey' }) }) }
        { Read-LunqProfile -Path $file } | Should -Throw '*одиночный \*'
    }
}

Describe 'Select-LunqProfile' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        Mock -ModuleName LunqDebloater Write-Host { }
        Mock -ModuleName LunqDebloater Write-Info { }
        Mock -ModuleName LunqDebloater Write-Warning { }
    }

    It 'сломанный профиль пропускается с предупреждением, исправный выбирается' {
        Copy-Item -LiteralPath $script:ProfilePath -Destination (Join-Path $script:dir 'Profile.json')
        Set-Content -LiteralPath (Join-Path $script:dir 'Broken.json') -Value '{ "Name": '
        Select-LunqProfile -ProfileDir $script:dir | Should -Be (Join-Path $script:dir 'Profile.json')
        Should -Invoke -ModuleName LunqDebloater Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like 'Профиль Broken.json пропущен:*' }
    }

    It 'если не прочитался ни один профиль, это ошибка' {
        Set-Content -LiteralPath (Join-Path $script:dir 'Broken.json') -Value '{ "Name": '
        { Select-LunqProfile -ProfileDir $script:dir } | Should -Throw '*нет ни одного профиля, который удалось прочитать*'
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

    It 'действия первого входа берутся только из включённых категорий' {
        $p = Read-LunqProfile -Path $script:ProfilePath
        (Get-LunqEffectiveConfig -LunqProfile $p).FirstLogon.Count | Should -Be 0
        Set-LunqOnlyCategories -LunqProfile $p -Ids 'edge', 'ads'
        $config = Get-LunqEffectiveConfig -LunqProfile $p
        $config.FirstLogon | Should -Be @('RemoveEdge')
        @($config.Registry | Where-Object { $_.LunqCategory -eq 'edge' } | ForEach-Object { $_.Name }) | Should -Be @('AllowUninstall', 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}')
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
