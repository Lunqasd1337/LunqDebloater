function Test-NamePattern {
    # Возвращает $true, если имя подходит хотя бы под один шаблон (-like, с * и ?).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [string[]]$Patterns
    )
    foreach ($pattern in $Patterns) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-ConfigValue {
    # Безопасно достаёт значение из профиля по цепочке имён: отсутствующий ключ даёт $null.
    param($Object, [Parameter(Mandatory)][string[]]$Names)
    foreach ($name in $Names) {
        if ($null -eq $Object) { return $null }
        $prop = $Object.PSObject.Properties[$name]
        if ($null -eq $prop) { return $null }
        $Object = $prop.Value
    }
    return $Object
}

function Get-ConfigList {
    param($Object, [Parameter(Mandatory)][string[]]$Names)
    # Запятая не даёт PowerShell развернуть пустой или одноэлементный массив при возврате.
    $value = Get-ConfigValue $Object $Names
    if ($null -eq $value) { return , @() }
    return , @($value)
}

function Read-LunqProfile {
    # Читает профиль и приводит его к списку категорий. Профиль старого формата
    # (без Categories) превращается в одну категорию «Профиль».
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Профиль не найден: $Path"
    }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $config = $json | ConvertFrom-Json

    $categories = New-Object System.Collections.Generic.List[object]
    $rawCategories = Get-ConfigValue $config 'Categories'
    if ($null -ne $rawCategories) {
        foreach ($raw in @($rawCategories)) {
            $id = [string](Get-ConfigValue $raw 'Id')
            if (-not $id) { throw "В профиле $Path у одной из категорий не указан Id." }
            if ($categories | Where-Object { $_.Id -eq $id }) { throw "В профиле $Path Id категории '$id' повторяется." }
            $name = Get-ConfigValue $raw 'Name'
            if (-not $name) { $name = $id }
            $enabled = Get-ConfigValue $raw 'Enabled'
            if ($null -eq $enabled) { $enabled = $true }
            $categories.Add([pscustomobject]@{
                    Id           = $id
                    Name         = [string]$name
                    Description  = [string](Get-ConfigValue $raw 'Description')
                    Enabled      = [bool]$enabled
                    Appx         = Get-ConfigList $raw 'Appx'
                    Capabilities = Get-ConfigList $raw 'Capabilities'
                    Features     = Get-ConfigList $raw 'Features'
                    Packages     = Get-ConfigList $raw 'Packages'
                    Registry     = Get-ConfigList $raw 'Registry'
                })
        }
    }
    else {
        $categories.Add([pscustomobject]@{
                Id           = 'profile'
                Name         = 'Профиль'
                Description  = ''
                Enabled      = $true
                Appx         = Get-ConfigList $config 'Appx', 'Remove'
                Capabilities = Get-ConfigList $config 'Capabilities', 'Remove'
                Features     = Get-ConfigList $config 'Features', 'Disable'
                Packages     = Get-ConfigList $config 'Packages', 'Remove'
                Registry     = Get-ConfigList $config 'Registry'
            })
    }

    foreach ($category in $categories) {
        foreach ($entry in $category.Registry) {
            $hive = [string](Get-ConfigValue $entry 'Hive')
            if (-not $script:HiveMap.Contains($hive)) {
                throw "Неизвестный куст '$hive' в категории '$($category.Name)'. Допустимо: $($script:HiveMap.Keys -join ', ')"
            }
            $path = Get-ConfigValue $entry 'Path'
            if (-not $path) {
                throw "У записи реестра для куста $hive в категории '$($category.Name)' не указан Path."
            }
            $problem = Test-LunqRegistryEntry -Entry $entry
            if ($problem) {
                throw "Запись реестра $hive\$path в категории '$($category.Name)': $problem"
            }
        }
    }

    # RemoveFeaturePayload в Options; в старом формате он лежал в Features.RemovePayload.
    $removePayload = Get-ConfigValue $config 'Options', 'RemoveFeaturePayload'
    if ($null -eq $removePayload) { $removePayload = Get-ConfigValue $config 'Features', 'RemovePayload' }

    $profileName = Get-ConfigValue $config 'Name'
    if (-not $profileName) { $profileName = [IO.Path]::GetFileNameWithoutExtension($Path) }

    # Requirements: какую сборку Windows ожидает профиль. Все поля необязательны.
    $requirements = [pscustomobject]@{
        Build        = [int](Get-ConfigValue $config 'Requirements', 'Build')
        MinRevision  = [int](Get-ConfigValue $config 'Requirements', 'MinRevision')
        Architecture = [string](Get-ConfigValue $config 'Requirements', 'Architecture')
    }

    return [pscustomobject]@{
        Name                 = [string]$profileName
        Requirements         = $requirements
        Description          = [string](Get-ConfigValue $config 'Description')
        Path                 = $Path
        RemoveFeaturePayload = [bool]$removePayload
        Categories           = $categories.ToArray()
    }
}

function Get-CategoryCounts {
    param([Parameter(Mandatory)]$Category)
    $parts = @()
    if ($Category.Appx.Count) { $parts += "приложений: $($Category.Appx.Count)" }
    if ($Category.Capabilities.Count) { $parts += "компонентов: $($Category.Capabilities.Count)" }
    if ($Category.Features.Count) { $parts += "функций: $($Category.Features.Count)" }
    if ($Category.Packages.Count) { $parts += "пакетов: $($Category.Packages.Count)" }
    if ($Category.Registry.Count) { $parts += "реестр: $($Category.Registry.Count)" }
    return ($parts -join ', ')
}

function Write-CategoryList {
    param([Parameter(Mandatory)]$LunqProfile, [switch]$Numbered)
    $i = 0
    foreach ($category in $LunqProfile.Categories) {
        $i++
        $mark = if ($category.Enabled) { '[x]' } else { '[ ]' }
        $color = if ($category.Enabled) { 'Green' } else { 'DarkGray' }
        $prefix = if ($Numbered) { '    {0,-4} ' -f "[$i]" } else { '    ' }
        Write-Host $prefix -NoNewline -ForegroundColor Cyan
        Write-Host "$mark " -NoNewline -ForegroundColor $color
        Write-Host $category.Name -NoNewline
        Write-Host ("  ({0}; id: {1})" -f (Get-CategoryCounts $category), $category.Id) -ForegroundColor DarkGray
        if ($Numbered -and $category.Description) { Write-Host "           $($category.Description)" -ForegroundColor DarkGray }
    }
}

function Disable-LunqCategories {
    # Выключает категории по Id (для параметра -SkipCategory).
    param([Parameter(Mandatory)]$LunqProfile, [string[]]$Ids)
    foreach ($id in $Ids) {
        $category = $LunqProfile.Categories | Where-Object { $_.Id -eq $id }
        if (-not $category) {
            $known = ($LunqProfile.Categories | ForEach-Object { $_.Id }) -join ', '
            throw "Категории '$id' нет в профиле. Доступные Id: $known"
        }
        $category.Enabled = $false
    }
}

function Select-LunqCategories {
    # Даёт включить или выключить категории по номерам, пока пользователь не нажмёт Enter.
    param([Parameter(Mandatory)]$LunqProfile)

    Write-Info 'Категории профиля. [x] будет применена, [ ] пропущена.'
    while ($true) {
        Write-Info ''
        Write-CategoryList -LunqProfile $LunqProfile -Numbered
        Write-Info ''
        $answer = Read-Host '    Номера категорий, чтобы включить или выключить их (через пробел), или Enter, чтобы продолжить'
        if (-not $answer -or -not $answer.Trim()) { return }
        foreach ($token in ($answer -split '[\s,;]+' | Where-Object { $_ })) {
            $parsed = 0
            if ([int]::TryParse($token, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $LunqProfile.Categories.Count) {
                $category = $LunqProfile.Categories[$parsed - 1]
                $category.Enabled = -not $category.Enabled
            }
            else { Write-Warning "Номера $token нет в списке." }
        }
    }
}

function Get-LunqEffectiveConfig {
    # Собирает включённые категории в общие списки для шагов удаления и реестра.
    # Каждой записи реестра добавляется LunqCategory, чтобы считать итог по категориям.
    param([Parameter(Mandatory)]$LunqProfile)

    $enabled = @($LunqProfile.Categories | Where-Object { $_.Enabled })
    $registry = foreach ($category in $enabled) {
        foreach ($entry in $category.Registry) {
            $copy = $entry.PSObject.Copy()
            $copy | Add-Member -NotePropertyName LunqCategory -NotePropertyValue $category.Id -Force
            $copy
        }
    }
    $collect = { param($kind) , @($enabled | ForEach-Object { $_.$kind } | Select-Object -Unique) }

    return [pscustomobject]@{
        Appx         = [pscustomobject]@{ Remove = & $collect 'Appx' }
        Capabilities = [pscustomobject]@{ Remove = & $collect 'Capabilities' }
        Features     = [pscustomobject]@{ Disable = & $collect 'Features'; RemovePayload = $LunqProfile.RemoveFeaturePayload }
        Packages     = [pscustomobject]@{ Remove = & $collect 'Packages' }
        Registry     = @($registry)
    }
}

function Select-LunqProfile {
    # Показывает профили (*.json) из папки Config и даёт выбрать один, если их несколько.
    param([Parameter(Mandatory)][string]$ProfileDir)

    $files = @(Get-ChildItem -LiteralPath $ProfileDir -Filter '*.json' -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw "В папке $ProfileDir нет профилей (*.json)." }

    $items = foreach ($file in $files) {
        $loaded = Read-LunqProfile -Path $file.FullName
        [pscustomobject]@{ Path = $file.FullName; Name = $loaded.Name; Description = $loaded.Description }
    }
    $items = @($items)

    if ($items.Count -eq 1) {
        Write-Info "Профиль: $($items[0].Name)"
        if ($items[0].Description) { Write-Host "    $($items[0].Description)" -ForegroundColor DarkGray }
        return $items[0].Path
    }

    Write-Info 'Профиль определяет, что будет удалено и изменено в образе:'
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ("    [{0}] " -f ($i + 1)) -ForegroundColor Cyan -NoNewline
        Write-Host $items[$i].Name
        if ($items[$i].Description) { Write-Host "        $($items[$i].Description)" -ForegroundColor DarkGray }
    }
    while ($true) {
        $answer = Read-Host '    Введите номер профиля'
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $items.Count) {
            return $items[$parsed - 1].Path
        }
        Write-Warning 'Такого номера нет в списке, попробуйте ещё раз.'
    }
}
