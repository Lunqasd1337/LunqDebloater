#Requires -Version 5.1
<#
    LunqDebloater: функции офлайн-преднастройки образа Windows 11.
    Все операции выполняются над смонтированным install.wim через модуль DISM
    и reg.exe, поэтому работают только на Windows и с правами администратора.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Имена, под которыми офлайн-кусты подключаются в HKLM на время работы.
$script:HiveMap = [ordered]@{
    SOFTWARE    = @{ Key = 'HKLM\LUNQ_SOFTWARE'; File = 'Windows\System32\config\SOFTWARE' }
    SYSTEM      = @{ Key = 'HKLM\LUNQ_SYSTEM';   File = 'Windows\System32\config\SYSTEM' }
    DefaultUser = @{ Key = 'HKLM\LUNQ_NTUSER';   File = 'Users\Default\NTUSER.DAT' }
}

# Счётчик шагов для вывода «Шаг N из M».
$script:StepCurrent = 0
$script:StepTotal = 0

function Initialize-LunqSteps {
    param([Parameter(Mandatory)][int]$Total)
    $script:StepCurrent = 0
    $script:StepTotal = $Total
}

function Write-Step {
    # Заголовок шага. -Hint выводит под ним короткое пояснение для нового пользователя.
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint
    )
    Write-Host ''
    if ($script:StepTotal -gt 0) {
        $script:StepCurrent++
        Write-Host ("==> Шаг {0} из {1}. {2}" -f $script:StepCurrent, $script:StepTotal, $Message) -ForegroundColor Cyan
    }
    else {
        Write-Host "==> $Message" -ForegroundColor Cyan
    }
    if ($Hint) { Write-Host "    $Hint" -ForegroundColor DarkGray }
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Yellow
}

function Write-Info {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host "    $Message"
}

function Write-Check {
    # Строка проверки: [ OK ], [ !! ] (предупреждение) или [FAIL].
    param(
        [Parameter(Mandatory)][ValidateSet('Ok', 'Warn', 'Fail')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Hint
    )
    $label = @{ Ok = '[ OK ]'; Warn = '[ !! ]'; Fail = '[FAIL]' }[$Status]
    $color = @{ Ok = 'Green'; Warn = 'Yellow'; Fail = 'Red' }[$Status]
    Write-Host "    $label " -ForegroundColor $color -NoNewline
    Write-Host $Message
    if ($Hint) { Write-Host "           $Hint" -ForegroundColor DarkGray }
}

function Read-YesNo {
    # Спрашивает да/нет. Принимает y/yes/д/да в любом регистре, всё остальное означает «нет».
    param([Parameter(Mandatory)][string]$Prompt)
    $answer = Read-Host "    $Prompt [Y/N]"
    return ($answer.Trim().ToLower() -in @('y', 'yes', 'д', 'да'))
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -lt 1GB) { return ('{0:N0} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N1} ГБ' -f ($Bytes / 1GB))
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native {
    # Запускает внешнюю программу и возвращает код выхода. Вывод stderr не превращается
    # в исключение (в Windows PowerShell 5.1 это происходит при ErrorActionPreference = Stop).
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$ShowOutput
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($ShowOutput) { & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host "    $_" } }
        else { & $FilePath @Arguments 2>&1 | Out-Null }
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
}

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
            if (-not (Get-ConfigValue $entry 'Path')) {
                throw "У записи реестра для куста $hive в категории '$($category.Name)' не указан Path."
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
        $prefix = if ($Numbered) { '    [{0,2}] ' -f $i } else { '    ' }
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

function New-LunqOption {
    # Пункт сводки «Что войдёт в образ». Parent: Key пункта, без которого этот не имеет смысла.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Enabled = $true,
        [bool]$Available = $true,
        [string[]]$Details = @(),
        [string]$Parent
    )
    return [pscustomobject]@{
        Key = $Key; Name = $Name; Enabled = $Enabled; Available = $Available
        Details = @($Details); Parent = $Parent
    }
}

function Test-LunqOption {
    # Включён ли пункт с учётом родителя.
    param([Parameter(Mandatory)]$Options, [Parameter(Mandatory)][string]$Key)
    $option = $Options | Where-Object { $_.Key -eq $Key }
    if (-not $option -or -not $option.Available -or -not $option.Enabled) { return $false }
    if ($option.Parent) { return (Test-LunqOption -Options $Options -Key $option.Parent) }
    return $true
}

function Select-LunqBuildOptions {
    # Одна сводка вместо отдельных вопросов: всё, что найдено в папке Config, с переключением по номерам.
    # Пункты, для которых ничего не найдено, показываются с подсказкой и без номера.
    param([Parameter(Mandatory)]$Options)

    $numbered = @($Options | Where-Object { $_.Available })
    $numbers = @{}
    for ($i = 0; $i -lt $numbered.Count; $i++) { $numbers[$numbered[$i].Key] = $i + 1 }
    while ($true) {
        Write-Info ''
        foreach ($option in $Options) {
            if (-not $option.Available -and $option.Parent) { continue }
            $indent = if ($option.Parent) { '    ' } else { '' }
            $on = Test-LunqOption -Options $Options -Key $option.Key
            if ($option.Available) {
                Write-Host ('    [{0,2}] ' -f $numbers[$option.Key]) -ForegroundColor Cyan -NoNewline
            }
            else { Write-Host '         ' -NoNewline }
            $mark = if ($on) { '[x]' } else { '[ ]' }
            $color = if ($on) { 'Green' } else { 'DarkGray' }
            Write-Host "$indent$mark " -NoNewline -ForegroundColor $color
            if ($option.Available) { Write-Host $option.Name } else { Write-Host $option.Name -ForegroundColor DarkGray }
            foreach ($line in $option.Details) { Write-Host "           $indent$line" -ForegroundColor DarkGray }
        }
        Write-Info ''
        if ($numbered.Count -eq 0) { return }
        $answer = Read-Host '    Номера пунктов, чтобы включить или выключить их (через пробел), или Enter, чтобы продолжить'
        if (-not $answer -or -not $answer.Trim()) { return }
        foreach ($token in ($answer -split '[\s,;]+' | Where-Object { $_ })) {
            $parsed = 0
            if (-not ([int]::TryParse($token, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $numbered.Count)) {
                Write-Warning "Номера $token нет в списке."
                continue
            }
            $option = $numbered[$parsed - 1]
            if ($option.Parent -and -not (Test-LunqOption -Options $Options -Key $option.Parent)) {
                Write-Warning "Пункт $parsed работает только вместе с пунктом $($numbers[$option.Parent]). Сначала включите его."
                continue
            }
            $option.Enabled = -not $option.Enabled
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

function Mount-IsoImage {
    # Монтирует ISO и возвращает корень его диска, например "E:\".
    param([Parameter(Mandatory)][string]$IsoPath)

    $image = Mount-DiskImage -ImagePath $IsoPath -PassThru
    # Буква диска иногда назначается с задержкой.
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $volume = $image | Get-Volume -ErrorAction SilentlyContinue
        if ($volume -and $volume.DriveLetter) { return "$($volume.DriveLetter):\" }
        Start-Sleep -Seconds 1
    }
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    throw 'Не удалось получить букву диска смонтированного ISO.'
}

function Get-IsoEditions {
    # Читает список редакций прямо из ISO, ещё до копирования файлов.
    param([Parameter(Mandatory)][string]$IsoPath)

    $root = Mount-IsoImage -IsoPath $IsoPath
    try {
        try { $imagePath = Get-InstallImagePath -IsoRoot $root }
        catch { throw 'В ISO нет sources\install.wim или install.esd. Похоже, это не установочный образ Windows.' }
        return , @(Get-WindowsImage -ImagePath $imagePath | Sort-Object ImageIndex)
    }
    finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
}

function Get-IsoImageInfo {
    # Версия и архитектура выбранной редакции прямо из ISO, без копирования.
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][int]$Index
    )

    $root = Mount-IsoImage -IsoPath $IsoPath
    try {
        $image = Get-WindowsImage -ImagePath (Get-InstallImagePath -IsoRoot $root) -Index $Index
    }
    finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }

    $version = [version]$image.Version
    $architecture = switch ([int]$image.Architecture) {
        0 { 'x86' }; 5 { 'arm' }; 9 { 'amd64' }; 12 { 'arm64' }; default { "unknown($($image.Architecture))" }
    }
    return [pscustomobject]@{
        Name         = $image.ImageName
        Version      = $version
        Build        = $version.Build
        Revision     = [Math]::Max($version.Revision, 0)
        Architecture = $architecture
    }
}

function Get-WindowsReleaseName {
    # Привычное название выпуска по номеру сборки. Неизвестная сборка даёт пустую строку.
    param([int]$Build)
    $names = @{ 22000 = '21H2'; 22621 = '22H2'; 22631 = '23H2'; 26100 = '24H2'; 26200 = '25H2'; 26300 = '26H2' }
    if ($names.ContainsKey($Build)) { return "Windows 11 $($names[$Build])" }
    return ''
}

function Test-LunqImageRequirements {
    # Сравнивает сборку и архитектуру образа с Requirements профиля.
    # Возвращает списки ошибок и предупреждений; решение об остановке принимает вызывающий.
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)]$Requirements,
        [switch]$HasCumulativeUpdate
    )

    $result = [pscustomobject]@{
        Errors   = New-Object System.Collections.Generic.List[string]
        Warnings = New-Object System.Collections.Generic.List[string]
    }
    $actual = '{0}.{1}' -f $Info.Build, $Info.Revision
    $release = Get-WindowsReleaseName -Build $Info.Build
    if ($release) { $actual = "$actual ($release)" }

    if ($Requirements.Architecture -and $Info.Architecture -ne $Requirements.Architecture) {
        $result.Errors.Add("Архитектура образа $($Info.Architecture), а профиль рассчитан на $($Requirements.Architecture).")
    }

    if ($Requirements.Build -gt 0 -and $Info.Build -ne $Requirements.Build) {
        $wanted = [string]$Requirements.Build
        $wantedRelease = Get-WindowsReleaseName -Build $Requirements.Build
        if ($wantedRelease) { $wanted = "$wanted ($wantedRelease)" }
        $result.Errors.Add("Сборка образа $actual, а профиль рассчитан на сборку $wanted. Нужен ISO именно этой версии Windows.")
    }
    elseif ($Requirements.MinRevision -gt 0 -and $Info.Revision -lt $Requirements.MinRevision) {
        $wanted = '{0}.{1}' -f $Info.Build, $Requirements.MinRevision
        if ($HasCumulativeUpdate) {
            $result.Warnings.Add("Сборка образа $actual старше $wanted, но накопительное обновление из папки обновлений её поднимет.")
        }
        else {
            $result.Errors.Add("Сборка образа $actual старше, чем нужно профилю: $wanted или новее.")
        }
    }
    return $result
}

function Copy-IsoContent {
    # Монтирует ISO, копирует его содержимое в рабочую папку и снимает атрибут «только чтение».
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $source = Mount-IsoImage -IsoPath $IsoPath
    try {
        Write-Info "ISO смонтирован как $source, копирую файлы..."

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # robocopy возвращает коды < 8 при успехе.
        $code = Invoke-Native robocopy.exe @($source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        if ($code -ge 8) { throw "robocopy завершился с кодом $code" }
    }
    finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }

    Get-ChildItem -LiteralPath $Destination -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
}

function Get-InstallImagePath {
    param([Parameter(Mandatory)][string]$IsoRoot)

    foreach ($name in 'install.wim', 'install.esd') {
        $path = Join-Path $IsoRoot "sources\$name"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw 'В папке sources не найден install.wim или install.esd.'
}

function Get-EditionHint {
    # Короткое пояснение к редакции для тех, кто выбирает впервые.
    param([Parameter(Mandatory)][string]$Name)

    # Названия редакций в ISO зависят от языка, поэтому шаблоны на английском и русском.
    $hint = switch -Regex ($Name) {
        'for Workstations|для рабочих станций'     { 'Pro для мощных рабочих станций: ReFS, больше процессоров и памяти'; break }
        'Pro.*(Education|образовательных)'         { 'Pro для учебных заведений'; break }
        'Education|образовательных'                { 'для учебных заведений, по возможностям близка к Корпоративной'; break }
        'Enterprise|Корпоративная'                 { 'корпоративная: всё из Pro плюс функции для организаций, нужна корпоративная лицензия'; break }
        'Single Language|для одного языка'         { 'Домашняя с одним языком интерфейса, сменить язык нельзя'; break }
        'Pro'                                      { 'BitLocker, групповые политики, Hyper-V, удалённый рабочий стол; подходит большинству'; break }
        'Home|Домашняя'                            { 'для домашнего ПК, без BitLocker, групповых политик и Hyper-V'; break }
        default                                    { '' }
    }
    if ($Name -match '(^|\s)N(\s|$)') { $hint = "$hint. Версия N: без мультимедийных компонентов".TrimStart('. ') }
    return $hint
}

function Write-EditionList {
    param([Parameter(Mandatory)]$Images)

    foreach ($img in $Images) {
        Write-Host ("    [{0,2}] " -f $img.ImageIndex) -ForegroundColor Cyan -NoNewline
        Write-Host $img.ImageName -NoNewline
        $hint = Get-EditionHint -Name $img.ImageName
        if ($hint) { Write-Host "  ($hint)" -ForegroundColor DarkGray } else { Write-Host '' }
    }
}

function Select-LunqEdition {
    # Определяет индекс редакции по номеру, имени или интерактивному выбору.
    param(
        [Parameter(Mandatory)]$Images,
        [int]$Index,
        [string]$Edition
    )

    if ($Index -gt 0) {
        if (-not ($Images | Where-Object ImageIndex -eq $Index)) {
            Write-Info 'Доступные редакции:'
            Write-EditionList -Images $Images
            throw "В образе нет редакции с номером $Index. Выберите номер из списка выше."
        }
        return $Index
    }

    if ($Edition) {
        $match = @($Images | Where-Object { $_.ImageName -eq $Edition })
        if ($match.Count -eq 0) {
            Write-Info 'Доступные редакции:'
            Write-EditionList -Images $Images
            throw "Редакция '$Edition' не найдена. Укажите имя из списка выше в кавычках или номер через -Index."
        }
        return $match[0].ImageIndex
    }

    if ($Images.Count -eq 1) {
        Write-Info "В образе одна редакция: $($Images[0].ImageName)"
        return $Images[0].ImageIndex
    }

    Write-Info 'Какую редакцию Windows подготовить? В итоговом ISO останется только она.'
    Write-Info 'Если сомневаетесь, выбирайте ту, на которую у вас есть ключ (обычно Home или Pro).'
    Write-Info ''
    Write-EditionList -Images $Images
    Write-Info ''
    while ($true) {
        $answer = Read-Host '    Введите номер редакции'
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and ($Images | Where-Object ImageIndex -eq $parsed)) {
            return $parsed
        }
        Write-Warning 'Такого номера нет в списке, попробуйте ещё раз.'
    }
}

function Select-IsoFile {
    # Открывает окно выбора ISO. Если окно недоступно, просит ввести путь вручную.
    $useDialog = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
    while ($true) {
        $path = $null
        if ($useDialog) {
            $dialogResult = $null
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dialog = New-Object System.Windows.Forms.OpenFileDialog
                $dialog.Title = 'Выберите ISO-образ Windows 11'
                $dialog.Filter = 'Образ диска (*.iso)|*.iso'
                # Невидимое окно-владелец поверх остальных, чтобы диалог не открылся за консолью.
                $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
                $dialogResult = $dialog.ShowDialog($owner)
                $owner.Dispose()
            }
            catch { $useDialog = $false }

            if ($null -ne $dialogResult) {
                if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) { throw 'Выбор ISO отменён.' }
                $path = $dialog.FileName
            }
        }
        if (-not $path) {
            $path = (Read-Host '    Путь к ISO (можно перетащить файл в это окно)').Trim().Trim('"')
        }
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf) -and $path -like '*.iso') {
            return (Resolve-Path -LiteralPath $path).Path
        }
        Write-Warning "Файл не найден или это не ISO: $path"
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

function Test-PathInside {
    # $true, если путь совпадает с папкой или лежит внутри неё.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Folder)
    $sep = [IO.Path]::DirectorySeparatorChar
    $p = $Path.TrimEnd('\', '/') + $sep
    $f = $Folder.TrimEnd('\', '/') + $sep
    return $p.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)
}

$script:WorkDirMarker = '.lunqdebloater'

function Test-LunqWorkDir {
    # Рабочая папка удаляется целиком, поэтому годится только новая, пустая или уже
    # созданная скриптом (с файлом-меткой) папка. Возвращает текст проблемы или $null.
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [string[]]$ProtectedPaths = @(),
        [switch]$IsDefault
    )

    if ($WorkDir.TrimEnd('\', '/') -eq ([IO.Path]::GetPathRoot($WorkDir)).TrimEnd('\', '/')) {
        return 'это корень диска'
    }
    foreach ($path in $ProtectedPaths) {
        if ($path -and (Test-PathInside -Path $path -Folder $WorkDir)) {
            return "внутри неё лежит $path, он был бы удалён"
        }
    }
    if ((Test-Path -LiteralPath $WorkDir -PathType Leaf)) { return 'это файл, а не папка' }
    if ((Test-Path -LiteralPath $WorkDir) -and -not $IsDefault -and -not (Test-Path -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker))) {
        if (@(Get-ChildItem -LiteralPath $WorkDir -Force).Count -gt 0) {
            return 'папка не пустая и создана не этим скриптом'
        }
    }
    return $null
}

function Initialize-LunqWorkDir {
    # Создаёт рабочую папку с файлом-меткой, по которой скрипт узнаёт свою папку.
    param([Parameter(Mandatory)][string]$WorkDir)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker) -Value 'Рабочая папка LunqDebloater. Удаляется после сборки.' -Encoding UTF8
}

function Reset-LunqWorkDir {
    # Отключает образы, оставшиеся от прошлого запуска, и создаёт рабочую папку заново.
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string[]]$MountPaths)
    foreach ($leftover in (Get-LunqMountedPaths -Paths $MountPaths)) {
        Write-Info "Найден оставшийся смонтированный образ в $leftover, отключаю без сохранения."
        Dismount-WindowsImage -Path $leftover -Discard | Out-Null
    }
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    Initialize-LunqWorkDir -WorkDir $WorkDir
}

function Get-LunqMountedPaths {
    # Какие из указанных папок сейчас заняты смонтированным образом DISM.
    param([string[]]$Paths)
    try { $mountedImages = @(Get-WindowsImage -Mounted -ErrorAction Stop) }
    catch { return , @() }
    return , @($mountedImages | Where-Object { $Paths -contains $_.Path } | ForEach-Object { $_.Path })
}

function Test-LunqPrerequisites {
    # Проверяет всё, что нужно для сборки, до начала долгой работы.
    # Возвращает путь к oscdimg, ошибки и предупреждения.
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$OutputIso,
        [string]$OscdimgPath,
        [long]$UpdatesSize = 0,
        [long]$DriversSize = 0,
        [string[]]$ProtectedPaths = @(),
        [switch]$DefaultWorkDir,
        [long]$ExtraSize = 0,
        [switch]$SkipOscdimg
    )

    $result = [pscustomobject]@{ Oscdimg = $null; Errors = 0; Warnings = 0 }

    $workDirProblem = Test-LunqWorkDir -WorkDir $WorkDir -ProtectedPaths $ProtectedPaths -IsDefault:$DefaultWorkDir
    if ($workDirProblem) {
        Write-Check Fail "Рабочая папка $($WorkDir): $workDirProblem" 'Скрипт полностью очищает рабочую папку. Укажите через -WorkDir новую или пустую папку, например D:\LunqWork.'
        $result.Errors++
    }

    if (Test-Administrator) { Write-Check Ok 'Права администратора' }
    else {
        Write-Check Fail 'Нет прав администратора' 'Запустите PowerShell через «Запуск от имени администратора».'
        $result.Errors++
    }

    if (-not $SkipOscdimg) {
        try {
            $result.Oscdimg = Find-Oscdimg -Path $OscdimgPath
            Write-Check Ok "Windows ADK: $($result.Oscdimg)"
        }
        catch {
            Write-Check Fail 'Не найден oscdimg.exe из Windows ADK' 'Установите ADK (достаточно компонента Deployment Tools): https://learn.microsoft.com/windows-hardware/get-started/adk-install'
            $result.Errors++
        }
    }

    # Рабочей папке нужно место под копию ISO, экспорт install.wim и распакованный образ.
    $isoSize = (Get-Item -LiteralPath $IsoPath).Length
    $needWork = [long](25GB)
    # DISM распаковывает обновления во временную папку, а образ после них растёт.
    if ($UpdatesSize -gt 0) { $needWork += [long]($UpdatesSize * 3) }
    if ($DriversSize -gt 0) { $needWork += [long]($DriversSize * 2) }
    if ($ExtraSize -gt 0) { $needWork += $ExtraSize }
    $needOut = [long]($isoSize + 1GB)
    if ($WorkDir.StartsWith('\\')) {
        Write-Check Fail "Рабочая папка $WorkDir на сетевом диске" 'DISM монтирует образ только на локальном NTFS-диске. Укажите другую папку через -WorkDir.'
        $result.Errors++
        return $result
    }
    $workDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($WorkDir))
    $outDrive = $null
    if ($OutputIso.StartsWith('\\')) {
        Write-Info "Итоговый ISO будет сохранён в сетевую папку, свободное место там не проверяется."
    }
    else {
        $outDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($OutputIso))
    }

    if ($workDrive.DriveFormat -ne 'NTFS') {
        Write-Check Fail "Диск $($workDrive.Name) для рабочей папки не NTFS ($($workDrive.DriveFormat))" 'DISM монтирует образ только на NTFS. Укажите другую папку через -WorkDir.'
        $result.Errors++
    }

    if ($outDrive -and $workDrive.Name -eq $outDrive.Name) { $needWork += $needOut }
    if ($workDrive.AvailableFreeSpace -ge $needWork) {
        Write-Check Ok ("Место на {0} для рабочей папки: свободно {1}, нужно около {2}" -f $workDrive.Name, (Format-Size $workDrive.AvailableFreeSpace), (Format-Size $needWork))
    }
    else {
        Write-Check Warn ("Мало места на {0}: свободно {1}, нужно около {2}" -f $workDrive.Name, (Format-Size $workDrive.AvailableFreeSpace), (Format-Size $needWork)) 'Освободите место или укажите папку на другом диске через -WorkDir.'
        $result.Warnings++
    }
    if ($outDrive -and $workDrive.Name -ne $outDrive.Name) {
        if ($outDrive.AvailableFreeSpace -ge $needOut) {
            Write-Check Ok ("Место на {0} для итогового ISO: свободно {1}" -f $outDrive.Name, (Format-Size $outDrive.AvailableFreeSpace))
        }
        else {
            Write-Check Warn ("Мало места на {0} для итогового ISO: свободно {1}, нужно около {2}" -f $outDrive.Name, (Format-Size $outDrive.AvailableFreeSpace), (Format-Size $needOut))
            $result.Warnings++
        }
    }

    if (@(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Check Warn 'В системе уже есть смонтированные образы DISM' 'Если это остатки прошлого запуска в другой папке, выполните: dism /Cleanup-Wim'
        $result.Warnings++
    }

    return $result
}

function New-LunqResult {
    # Результат шага удаления: что сделано, что не удалось, какие шаблоны профиля ничего не нашли.
    param([string]$Title, [string]$Kind)
    return [pscustomobject]@{
        Title      = $Title
        Kind       = $Kind
        Done       = New-Object System.Collections.Generic.List[string]
        Failed     = New-Object System.Collections.Generic.List[string]
        NotMatched = New-Object System.Collections.Generic.List[string]
    }
}

function Add-NotMatched {
    param($Result, [string[]]$Patterns, [string[]]$Names)
    foreach ($pattern in $Patterns) {
        if (-not ($Names | Where-Object { $_ -like $pattern })) { $Result.NotMatched.Add($pattern) }
    }
}

function Write-LunqReport {
    # Итог сборки: обновления и результат по каждой включённой категории профиля.
    param(
        [object[]]$Results = @(),
        $Registry,
        $LunqProfile,
        [string]$OutputIso,
        [TimeSpan]$Elapsed
    )

    Write-Section 'Итог'
    $results = @($Results | Where-Object { $null -ne $_ })

    foreach ($r in @($results | Where-Object { $_.Kind -like 'Updates*' -or $_.Kind -like 'Drivers*' -or $_.Kind -eq 'FirstLogon' })) {
        if ($r.Kind -eq 'FirstLogon') { Write-Info ("{0}: {1}" -f $r.Title, $r.Summary); continue }
        $verb = if ($r.Kind -like 'Updates*') { 'установлено' } else { 'добавлено' }
        Write-Info ("{0}: {1} {2}, ошибок {3}" -f $r.Title, $verb, $r.Done.Count, $r.Failed.Count)
        if ($r.Failed.Count -gt 0) { Write-Host "        Не удалось: $($r.Failed -join ', ')" -ForegroundColor Yellow }
    }

    if ($LunqProfile) {
        foreach ($category in @($LunqProfile.Categories | Where-Object { $_.Enabled })) {
            $done = 0
            $failed = @()
            $missing = @()
            foreach ($r in $results) {
                if ($r.Kind -notin 'Appx', 'Capabilities', 'Features', 'Packages') { continue }
                $patterns = @($category.($r.Kind))
                if ($patterns.Count -eq 0) { continue }
                $done += @($r.Done | Where-Object { Test-NamePattern -Name $_ -Patterns $patterns }).Count
                $failed += @($r.Failed | Where-Object { Test-NamePattern -Name $_ -Patterns $patterns })
                $missing += @($r.NotMatched | Where-Object { $patterns -contains $_ })
            }
            $parts = @()
            if (($category.Appx.Count + $category.Capabilities.Count + $category.Features.Count + $category.Packages.Count) -gt 0) {
                $parts += "удалено или отключено: $done"
            }
            if ($Registry -and $Registry.ContainsKey('ByCategory') -and $Registry.ByCategory.ContainsKey($category.Id)) {
                $r = $Registry.ByCategory[$category.Id]
                $parts += ("реестр: {0} из {1}" -f ($r.Applied + $r.Skipped), $category.Registry.Count)
                if ($r.Failed -gt 0) { $failed += "записей реестра: $($r.Failed)" }
            }
            if ($parts.Count -eq 0) { continue }
            $color = if ($failed.Count -gt 0) { 'Yellow' } else { 'Gray' }
            Write-Host ("    {0}: {1}" -f $category.Name, ($parts -join ', ')) -ForegroundColor $color
            if ($failed.Count -gt 0) { Write-Host "        Не удалось: $($failed -join ', ')" -ForegroundColor Yellow }
            if ($missing.Count -gt 0) { Write-Host "        Нет в образе или уже убрано: $($missing -join ', ')" -ForegroundColor DarkGray }
        }
        $off = @($LunqProfile.Categories | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count -gt 0) { Write-Info "Пропущены категории: $($off -join ', ')" }
    }

    if ($OutputIso -and (Test-Path -LiteralPath $OutputIso)) {
        Write-Info ("Итоговый ISO: {0} ({1})" -f $OutputIso, (Format-Size (Get-Item -LiteralPath $OutputIso).Length))
    }
    if ($Elapsed) { Write-Info ('Время сборки: {0:hh\:mm\:ss}' -f $Elapsed) }
    Write-Info ''
    Write-Info 'Что дальше: запишите ISO на флешку (например, через Rufus) или подключите его к виртуальной машине.'
}

function Export-SingleEdition {
    # Экспортирует одну редакцию в новый install.wim (заодно конвертирует ESD в WIM).
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [Parameter(Mandatory)][int]$SourceIndex,
        [Parameter(Mandatory)][string]$DestinationImage
    )

    $temp = "$DestinationImage.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }

    Export-WindowsImage -SourceImagePath $SourceImage -SourceIndex $SourceIndex `
        -DestinationImagePath $temp -CompressionType Max -CheckIntegrity | Out-Null

    Remove-Item -LiteralPath $SourceImage -Force
    if (Test-Path -LiteralPath $DestinationImage) { Remove-Item -LiteralPath $DestinationImage -Force }
    Move-Item -LiteralPath $temp -Destination $DestinationImage
}

function Get-LunqUpdateFiles {
    # Находит .msu и .cab в папке и упорядочивает их по номеру KB: более старые
    # (например, контрольные накопительные обновления) устанавливаются раньше.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return , @() }
    $files = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in '.msu', '.cab' })
    $sorted = $files | Sort-Object @{ Expression = {
            if ($_.Name -match '(?i)kb(\d+)') { [long]$Matches[1] } else { [long]::MaxValue }
        }
    }, Name
    return , @($sorted)
}

function Test-CumulativeUpdate {
    # Похоже ли хотя бы одно обновление на накопительное для самой Windows (а не, например, для .NET).
    param($Files)
    return [bool](@($Files) | Where-Object { $_.Name -match '(?i)^windows1[01]\.0-kb' })
}

function Write-UpdateList {
    param([Parameter(Mandatory)]$Files)
    foreach ($file in $Files) {
        Write-Info ("  {0} ({1})" -f $file.Name, (Format-Size $file.Length))
    }
}

function Add-LunqUpdates {
    # Встраивает обновления в смонтированный образ. Временные файлы DISM кладёт
    # в рабочую папку, а не в %TEMP%, чтобы не забить системный диск.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Files,
        [Parameter(Mandatory)][string]$ScratchDir,
        [string]$Title = 'Обновления',
        [string]$Kind = 'Updates'
    )

    $result = New-LunqResult $Title $Kind
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
    $i = 0
    foreach ($file in $Files) {
        $i++
        Write-Info ("[{0}/{1}] Устанавливаю {2} ({3})..." -f $i, $Files.Count, $file.Name, (Format-Size $file.Length))
        try {
            Add-WindowsPackage -Path $MountPath -PackagePath $file.FullName -ScratchDirectory $ScratchDir -NoRestart -ErrorAction Stop | Out-Null
            $result.Done.Add($file.Name)
        }
        catch {
            Write-Warning "Не удалось установить $($file.Name): $($_.Exception.Message)"
            $result.Failed.Add($file.Name)
        }
    }
    return $result
}

function Get-LunqDriverFiles {
    # Все .inf в папке и подпапках: так драйверы обычно лежат после распаковки.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return , @() }
    # -Filter в Windows находит и *.inf_loc (из-за коротких имён 8.3), поэтому расширение проверяется явно.
    # autorun.inf к драйверам не относится, хотя часто лежит рядом с ними.
    return , @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.inf' |
            Where-Object { $_.Extension -eq '.inf' -and $_.Name -ne 'autorun.inf' } |
            Sort-Object FullName)
}

function Get-FolderSize {
    param([Parameter(Mandatory)][string]$Path)
    $sum = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)) { $sum += $f.Length }
    return $sum
}

function Add-LunqDrivers {
    # Добавляет драйверы по одному .inf, чтобы один неподходящий драйвер не срывал остальные.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$InfFiles,
        [Parameter(Mandatory)][string]$Root,
        [string]$Title = 'Драйверы',
        [string]$Kind = 'Drivers'
    )

    $result = New-LunqResult $Title $Kind
    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $i = 0
    foreach ($inf in $InfFiles) {
        $i++
        $relative = $inf.FullName
        if ($relative.StartsWith($rootFull)) { $relative = $relative.Substring($rootFull.Length).TrimStart('\', '/') }
        Write-Info ("[{0}/{1}] {2}" -f $i, $InfFiles.Count, $relative)
        try {
            Add-WindowsDriver -Path $MountPath -Driver $inf.FullName -ErrorAction Stop | Out-Null
            $result.Done.Add($relative)
        }
        catch {
            Write-Warning "Не удалось добавить $($relative): $($_.Exception.Message)"
            $result.Failed.Add($relative)
        }
    }
    return $result
}

function Select-LunqPEUpdates {
    # Для установщика и WinRE подходят только обновления самой Windows (windows11.0-kb...),
    # обновления .NET (ndp) в Windows PE не ставятся.
    param($Files)
    return , @(@($Files) | Where-Object { $_.Name -match '(?i)^windows1[01]\.0-kb' -and $_.Name -notmatch '(?i)ndp' })
}

function Update-LunqPEImage {
    # Встраивает обновления и драйверы в образ на базе Windows PE: boot.wim или winre.wim.
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$Where,
        [Parameter(Mandatory)][string]$KindSuffix,
        $Updates = @(),
        $Drivers = @(),
        [string]$DriversRoot
    )

    $results = @()
    New-Item -ItemType Directory -Path $MountPath -Force | Out-Null
    Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath | Out-Null
    try {
        $updated = 0
        if (@($Updates).Count -gt 0) {
            $r = Add-LunqUpdates -MountPath $MountPath -Files $Updates -ScratchDir $ScratchDir -Title "Обновления в $Where" -Kind "Updates$KindSuffix"
            $updated = $r.Done.Count
            $results += $r
        }
        if (@($Drivers).Count -gt 0) {
            $results += Add-LunqDrivers -MountPath $MountPath -InfFiles $Drivers -Root $DriversRoot -Title "Драйверы в $Where" -Kind "Drivers$KindSuffix"
        }
        if ($updated -gt 0) {
            Write-Info 'Удаляю старые версии файлов после обновлений...'
            try { Repair-WindowsImage -Path $MountPath -StartComponentCleanup -ResetBase | Out-Null }
            catch { Write-Warning "Очистка не удалась, образ будет больше: $($_.Exception.Message)" }
        }
        Dismount-WindowsImage -Path $MountPath -Save | Out-Null
    }
    catch {
        Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }
    return $results
}

function Optimize-LunqWim {
    # Пересобирает WIM со всеми его образами: после обслуживания файл заметно меньше.
    # -BootIndex помечает образ загрузочным (в boot.wim это образ 2, «Установка Windows»).
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$BootIndex = 0
    )
    $temp = "$Path.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    foreach ($image in @(Get-WindowsImage -ImagePath $Path | Sort-Object ImageIndex)) {
        $params = @{ SourceImagePath = $Path; SourceIndex = $image.ImageIndex; DestinationImagePath = $temp; CompressionType = 'Max' }
        if ($image.ImageIndex -eq $BootIndex) { $params.SetBootable = $true }
        Export-WindowsImage @params | Out-Null
    }
    Remove-Item -LiteralPath $Path -Force
    Move-Item -LiteralPath $temp -Destination $Path
}

function Update-LunqRecovery {
    # Среда восстановления лежит внутри системы: Windows\System32\Recovery\Winre.wim.
    # Её копируют в рабочую папку, обслуживают, пересжимают и возвращают на место.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$PEMountPath,
        $Updates = @(),
        $Drivers = @(),
        [string]$DriversRoot
    )

    $inImage = Join-Path $MountPath 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $inImage)) {
        Write-Warning 'В образе нет Windows\System32\Recovery\Winre.wim, среда восстановления пропущена.'
        return
    }
    $original = Get-Item -LiteralPath $inImage -Force
    $attributes = $original.Attributes
    $work = Join-Path $WorkDir 'winre.wim'
    Copy-Item -LiteralPath $inImage -Destination $work -Force
    (Get-Item -LiteralPath $work -Force).Attributes = 'Normal'

    $results = Update-LunqPEImage -ImagePath $work -Index 1 -MountPath $PEMountPath -ScratchDir (Join-Path $WorkDir 'scratch') `
        -Where 'WinRE' -KindSuffix 'Recovery' -Updates $Updates -Drivers $Drivers -DriversRoot $DriversRoot
    Write-Info 'Пересжимаю Winre.wim...'
    Optimize-LunqWim -Path $work
    Write-Info ("Winre.wim: было {0}, стало {1}" -f (Format-Size $original.Length), (Format-Size (Get-Item -LiteralPath $work).Length))

    $original.Attributes = 'Normal'
    Copy-Item -LiteralPath $work -Destination $inImage -Force
    (Get-Item -LiteralPath $inImage -Force).Attributes = $attributes
    Remove-Item -LiteralPath $work -Force
    return $results
}

function Update-LunqSetup {
    # Установщик: boot.wim, образ 2 («Установка Windows»), с которого загружается флешка.
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$PEMountPath,
        $Updates = @(),
        $Drivers = @(),
        [string]$DriversRoot
    )

    $bootWim = Join-Path $IsoRoot 'sources\boot.wim'
    if (-not (Test-Path -LiteralPath $bootWim)) { throw 'В ISO нет sources\boot.wim, установщик обновить нельзя.' }
    $before = (Get-Item -LiteralPath $bootWim).Length
    $results = Update-LunqPEImage -ImagePath $bootWim -Index 2 -MountPath $PEMountPath -ScratchDir (Join-Path $WorkDir 'scratch') `
        -Where 'установщике' -KindSuffix 'Setup' -Updates $Updates -Drivers $Drivers -DriversRoot $DriversRoot
    Write-Info 'Пересжимаю boot.wim...'
    Optimize-LunqWim -Path $bootWim -BootIndex 2
    Write-Info ("boot.wim: было {0}, стало {1}" -f (Format-Size $before), (Format-Size (Get-Item -LiteralPath $bootWim).Length))
    return $results
}

function Get-LunqFirstLogon {
    # Что выполнится при первом входе: программы из Apps.txt и скрипты *.ps1 из папки Scripts.
    # Если файла или папки нет, соответствующий список просто пуст.
    param([Parameter(Mandatory)][string]$AppsPath, [Parameter(Mandatory)][string]$ScriptsPath)
    $apps = @()
    if (Test-Path -LiteralPath $AppsPath -PathType Leaf) {
        $apps = @(Get-Content -LiteralPath $AppsPath -Encoding UTF8 | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { ($_ -split '\s+')[0] })
    }
    $scripts = @()
    if (Test-Path -LiteralPath $ScriptsPath -PathType Container) {
        $scripts = @(Get-ChildItem -LiteralPath $ScriptsPath -Filter '*.ps1' -File | Where-Object { $_.Extension -eq '.ps1' } | Sort-Object Name)
    }
    return [pscustomobject]@{
        AppsPath    = $AppsPath
        Apps        = $apps
        ScriptsPath = $ScriptsPath
        Scripts     = $scripts
    }
}

function Write-FirstLogonSummary {
    param([Parameter(Mandatory)]$FirstLogon)
    if ($FirstLogon.Apps.Count -gt 0) { Write-Info ("Программы (winget): {0}" -f ($FirstLogon.Apps -join ', ')) }
    if ($FirstLogon.Scripts.Count -gt 0) { Write-Info ("Скрипты: {0}" -f (($FirstLogon.Scripts | ForEach-Object { $_.Name }) -join ', ')) }
}

function Install-LunqFirstLogon {
    # Кладёт в образ скрипт первого входа и unattend.xml, который запускает его через
    # FirstLogonCommands. SetupComplete.cmd не подходит: Windows не запускает его,
    # если в BIOS ноутбука зашит OEM-ключ, а это почти все ноутбуки с Home и Pro.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$FirstLogon,
        [Parameter(Mandatory)][string]$Architecture
    )

    $result = New-LunqResult 'Первый вход' 'FirstLogon'
    $unattend = Join-Path $MountPath 'Windows\System32\Sysprep\unattend.xml'
    if (Test-Path -LiteralPath $unattend) {
        throw 'В образе уже есть Windows\System32\Sysprep\unattend.xml, скрипт первого входа добавить нельзя.'
    }

    $target = Join-Path $MountPath 'Windows\Setup\Scripts\Lunq'
    $userTarget = Join-Path $target 'User'
    New-Item -ItemType Directory -Path $userTarget -Force | Out-Null
    if ($FirstLogon.Apps.Count -gt 0) {
        Copy-Item -LiteralPath $FirstLogon.AppsPath -Destination (Join-Path $userTarget 'Apps.txt') -Force
    }
    if ($FirstLogon.Scripts.Count -gt 0) {
        # Вместе со скриптами копируется всё, что лежит рядом с ними: скрипты могут этим пользоваться.
        $skip = @('.gitkeep', 'README.txt', 'README.md')
        foreach ($item in @(Get-ChildItem -LiteralPath $FirstLogon.ScriptsPath -Force | Where-Object { $skip -notcontains $_.Name })) {
            Copy-Item -LiteralPath $item.FullName -Destination $userTarget -Recurse -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FirstLogon\FirstLogon.ps1') -Destination $target -Force

    $command = 'cmd.exe /c start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Lunq\FirstLogon.ps1"'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Created by LunqDebloater: runs the first logon setup script. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$([Security.SecurityElement]::Escape($command))</CommandLine>
          <Description>LunqDebloater first logon</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
    New-Item -ItemType Directory -Path (Split-Path $unattend -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($unattend, $xml, (New-Object Text.UTF8Encoding($false)))

    foreach ($app in $FirstLogon.Apps) { $result.Done.Add($app) }
    $result | Add-Member -NotePropertyName Summary -NotePropertyValue ("программ {0}, скриптов {1}" -f $FirstLogon.Apps.Count, $FirstLogon.Scripts.Count)
    Write-Info ("Добавлено: {0}. Запустится при первом входе в Windows." -f $result.Summary)
    return $result
}

function Write-LunqInventory {
    # Сохраняет в текстовый файл всё, что есть в образе, в виде, удобном для профиля.
    # Справа помечаются категории профиля, которые уже упоминают элемент.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$LunqProfile,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Header = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($h in $Header) { $lines.Add($h) }
    $lines.Add("Профиль для сравнения: $($LunqProfile.Name). [id] справа: элемент уже есть в категории профиля с этим Id.")
    $lines.Add('')

    $categories = @($LunqProfile.Categories)
    $mark = {
        param([string]$Name, [string]$Kind)
        $ids = @($categories | Where-Object { Test-NamePattern -Name $Name -Patterns @($_.$Kind) } | ForEach-Object { $_.Id })
        if ($ids.Count -gt 0) { return '[' + ($ids -join ', ') + ']' }
        return ''
    }
    $addSection = {
        param([string]$Title, [string[]]$Names, [string]$Kind)
        $lines.Add("== $Title ==")
        foreach ($n in $Names) { $lines.Add(('  {0,-60} {1}' -f $n, (& $mark $n $Kind)).TrimEnd()) }
        if ($Names.Count -eq 0) { $lines.Add('  (нет)') }
        $lines.Add('')
    }

    $appx = @(Get-AppxProvisionedPackage -Path $MountPath | ForEach-Object { $_.DisplayName } | Sort-Object -Unique)
    & $addSection "Приложения Appx: $($appx.Count). Для раздела Appx" $appx 'Appx'

    $caps = @(Get-WindowsCapability -Path $MountPath | Where-Object State -eq 'Installed' | ForEach-Object { $_.Name } | Sort-Object)
    & $addSection "Компоненты (Capabilities), установлены: $($caps.Count). Для раздела Capabilities, версию после ~~~~ можно заменить на *" $caps 'Capabilities'

    $features = @(Get-WindowsOptionalFeature -Path $MountPath | Sort-Object FeatureName)
    $enabled = @($features | Where-Object { [string]$_.State -eq 'Enabled' } | ForEach-Object { $_.FeatureName })
    $disabled = @($features | Where-Object { [string]$_.State -ne 'Enabled' } | ForEach-Object { $_.FeatureName })
    & $addSection "Функции Windows (Optional Features), включены: $($enabled.Count). Для раздела Features" $enabled 'Features'
    & $addSection "Функции Windows, выключены: $($disabled.Count). Их отключать не нужно" $disabled 'Features'

    $missing = @()
    foreach ($category in $categories) {
        foreach ($pair in @(@('Appx', $appx), @('Capabilities', $caps), @('Features', $enabled))) {
            foreach ($pattern in @($category.($pair[0]))) {
                if (-not (@($pair[1]) | Where-Object { $_ -like $pattern })) { $missing += ('  {0,-60} [{1}]' -f "$($pair[0]): $pattern", $category.Id) }
            }
        }
    }
    $lines.Add("== Есть в профиле, но нет в образе (или уже выключено): $($missing.Count) ==")
    foreach ($m in $missing) { $lines.Add($m) }
    if ($missing.Count -eq 0) { $lines.Add('  (нет)') }

    $lines | Set-Content -LiteralPath $Path -Encoding UTF8
    return [pscustomobject]@{ Appx = $appx.Count; Capabilities = $caps.Count; Enabled = $enabled.Count; Disabled = $disabled.Count; Missing = $missing.Count }
}

function Remove-LunqAppx {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Приложения Appx' Appx
    $patterns = Get-ConfigList $Config 'Appx', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info 'Список Appx в профиле пуст.'; return $result }

    $packages = @(Get-AppxProvisionedPackage -Path $MountPath)
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.DisplayName -Patterns $patterns) {
            Write-Info "Удаляю $($pkg.DisplayName)"
            try {
                Remove-AppxProvisionedPackage -Path $MountPath -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                $result.Done.Add($pkg.DisplayName)
            }
            catch {
                Write-Warning "Не удалось удалить $($pkg.DisplayName): $($_.Exception.Message)"
                $result.Failed.Add($pkg.DisplayName)
            }
        }
    }
    Add-NotMatched $result $patterns @($packages | ForEach-Object { $_.DisplayName })
    Write-Info "Удалено Appx-пакетов: $($result.Done.Count) из $($packages.Count) в образе."
    return $result
}

function Remove-LunqCapabilities {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Компоненты (Capabilities)' Capabilities
    $patterns = Get-ConfigList $Config 'Capabilities', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info 'Список Capabilities в профиле пуст.'; return $result }

    $installed = @(Get-WindowsCapability -Path $MountPath | Where-Object State -eq 'Installed')
    foreach ($cap in $installed) {
        if (Test-NamePattern -Name $cap.Name -Patterns $patterns) {
            Write-Info "Удаляю компонент $($cap.Name)"
            try {
                Remove-WindowsCapability -Path $MountPath -Name $cap.Name -ErrorAction Stop | Out-Null
                $result.Done.Add($cap.Name)
            }
            catch {
                Write-Warning "Не удалось удалить $($cap.Name): $($_.Exception.Message)"
                $result.Failed.Add($cap.Name)
            }
        }
    }
    Add-NotMatched $result $patterns @($installed | ForEach-Object { $_.Name })
    return $result
}

function Disable-LunqFeatures {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Функции Windows (Optional Features)' Features
    $patterns = Get-ConfigList $Config 'Features', 'Disable'
    if ($patterns.Count -eq 0) { Write-Info 'Список Features в профиле пуст.'; return $result }

    $removePayload = [bool](Get-ConfigValue $Config 'Features', 'RemovePayload')

    $enabled = @(Get-WindowsOptionalFeature -Path $MountPath | Where-Object State -eq 'Enabled')
    foreach ($feature in $enabled) {
        if (Test-NamePattern -Name $feature.FeatureName -Patterns $patterns) {
            Write-Info "Отключаю компонент $($feature.FeatureName)"
            try {
                $params = @{ Path = $MountPath; FeatureName = $feature.FeatureName; NoRestart = $true; ErrorAction = 'Stop' }
                if ($removePayload) { $params.Remove = $true }
                Disable-WindowsOptionalFeature @params | Out-Null
                $result.Done.Add($feature.FeatureName)
            }
            catch {
                Write-Warning "Не удалось отключить $($feature.FeatureName): $($_.Exception.Message)"
                $result.Failed.Add($feature.FeatureName)
            }
        }
    }
    Add-NotMatched $result $patterns @($enabled | ForEach-Object { $_.FeatureName })
    return $result
}

function Remove-LunqPackages {
    # Удаление CBS-пакетов. Может сломать обслуживание образа, поэтому в профиле по умолчанию пусто.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Системные пакеты' Packages
    $patterns = Get-ConfigList $Config 'Packages', 'Remove'
    if ($patterns.Count -eq 0) { return $null }

    Write-Warning 'Удаление системных пакетов может помешать установке обновлений.'
    $packages = @(Get-WindowsPackage -Path $MountPath | Where-Object PackageState -eq 'Installed')
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.PackageName -Patterns $patterns) {
            Write-Info "Удаляю пакет $($pkg.PackageName)"
            try {
                Remove-WindowsPackage -Path $MountPath -PackageName $pkg.PackageName -NoRestart -ErrorAction Stop | Out-Null
                $result.Done.Add($pkg.PackageName)
            }
            catch {
                Write-Warning "Не удалось удалить $($pkg.PackageName): $($_.Exception.Message)"
                $result.Failed.Add($pkg.PackageName)
            }
        }
    }
    Add-NotMatched $result $patterns @($packages | ForEach-Object { $_.PackageName })
    return $result
}

function Mount-OfflineHives {
    param([Parameter(Mandatory)][string]$MountPath)

    foreach ($hive in $script:HiveMap.Values) {
        $file = Join-Path $MountPath $hive.File
        if ((Invoke-Native reg.exe @('load', $hive.Key, $file)) -ne 0) {
            throw "Не удалось загрузить куст $file"
        }
    }
}

function Dismount-OfflineHives {
    # Выгружает кусты; повторяет попытку, если какой-то процесс ещё держит дескриптор.
    foreach ($hive in $script:HiveMap.Values) {
        if ((Invoke-Native reg.exe @('query', $hive.Key)) -ne 0) { continue }

        $unloaded = $false
        for ($attempt = 1; $attempt -le 5 -and -not $unloaded; $attempt++) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $unloaded = ((Invoke-Native reg.exe @('unload', $hive.Key)) -eq 0)
            if (-not $unloaded) { Start-Sleep -Seconds 2 }
        }
        if (-not $unloaded) { Write-Warning "Не удалось выгрузить $($hive.Key). Выгрузите вручную: reg unload $($hive.Key)" }
    }
}

function ConvertTo-RegData {
    # Приводит значение из JSON к строке, которую понимает reg.exe add /d.
    param([Parameter(Mandatory)][string]$Type, $Value)

    switch ($Type) {
        'REG_MULTI_SZ' { return (@($Value) -join '\0') }
        'REG_BINARY'   { return ([string]$Value -replace '[\s,]', '') }
        default        { return [string]$Value }
    }
}

function Invoke-RegistryEntry {
    # Применяет одну запись профиля. Возвращает 'Applied', 'Skipped' или 'Failed'.
    param([Parameter(Mandatory)]$Entry)

    $validTypes = 'REG_SZ', 'REG_EXPAND_SZ', 'REG_MULTI_SZ', 'REG_DWORD', 'REG_QWORD', 'REG_BINARY'
    $key = '{0}\{1}' -f $script:HiveMap[[string]$Entry.Hive].Key, $Entry.Path
    $name = [string](Get-ConfigValue $Entry 'Name')
    # Без Name запись относится к значению «по умолчанию» (ключ /ve у reg.exe).
    $valueArgs = if ($name) { @('/v', $name) } else { @('/ve') }
    if (-not $name) { $name = '(по умолчанию)' }
    $action = Get-ConfigValue $Entry 'Action'
    if (-not $action) { $action = 'Set' }

    switch ($action) {
        'Set' {
            $type = [string](Get-ConfigValue $Entry 'Type')
            if ($validTypes -notcontains $type) {
                Write-Warning "Пропуск ${key}\${name}: неизвестный тип '$type'"
                return 'Failed'
            }
            $arguments = @('add', $key) + $valueArgs + @('/t', $type, '/f')
            $data = ConvertTo-RegData -Type $type -Value (Get-ConfigValue $Entry 'Value')
            # Пустую строку reg.exe получает, если /d не передан вовсе.
            if ($data -ne '') { $arguments += @('/d', $data) }
            $code = Invoke-Native reg.exe $arguments
        }
        'DeleteValue' {
            if ((Invoke-Native reg.exe (@('query', $key) + $valueArgs)) -ne 0) { return 'Skipped' }
            $code = Invoke-Native reg.exe (@('delete', $key) + $valueArgs + @('/f'))
        }
        'DeleteKey' {
            if ((Invoke-Native reg.exe @('query', $key)) -ne 0) { return 'Skipped' }
            $code = Invoke-Native reg.exe @('delete', $key, '/f')
        }
        default {
            Write-Warning "Пропуск ${key}: неизвестное действие '$action'"
            return 'Failed'
        }
    }

    if ($code -eq 0) { return 'Applied' }
    Write-Warning "reg.exe вернул код $code для $key ($action $name)"
    return 'Failed'
}

function Set-LunqRegistry {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $stats = @{ Applied = 0; Skipped = 0; Failed = 0 }
    $entries = Get-ConfigList $Config 'Registry'
    if ($entries.Count -eq 0) { Write-Info 'Список твиков реестра в профиле пуст.'; return $stats }

    Mount-OfflineHives -MountPath $MountPath
    try {
        $stats.ByCategory = @{}
        foreach ($entry in $entries) {
            $status = Invoke-RegistryEntry -Entry $entry
            $stats[$status]++
            $category = Get-ConfigValue $entry 'LunqCategory'
            if ($category) {
                if (-not $stats.ByCategory.ContainsKey($category)) { $stats.ByCategory[$category] = @{ Applied = 0; Skipped = 0; Failed = 0 } }
                $stats.ByCategory[$category][$status]++
            }
        }
        Write-Info ("Реестр: применено {0}, пропущено (уже нет) {1}, ошибок {2}." -f $stats.Applied, $stats.Skipped, $stats.Failed)
        return $stats
    }
    finally {
        Dismount-OfflineHives
    }
}

function Find-Oscdimg {
    param([string]$Path)

    if ($Path) {
        if (Test-Path -LiteralPath $Path) { return $Path }
        throw "oscdimg.exe не найден по пути $Path"
    }

    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $adk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if (Test-Path -LiteralPath $adk) { return $adk }

    throw 'oscdimg.exe не найден. Установите Windows ADK (компонент Deployment Tools) или укажите -OscdimgPath.'
}

function New-BootableIso {
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$Oscdimg,
        [string]$Label = 'LUNQ_WIN11'
    )

    $bios = Join-Path $IsoRoot 'boot\etfsboot.com'
    $uefi = Join-Path $IsoRoot 'efi\microsoft\boot\efisys.bin'
    foreach ($file in $bios, $uefi) {
        if (-not (Test-Path -LiteralPath $file)) { throw "Не найден загрузочный файл $file" }
    }

    $bootData = '2#p0,e,b{0}#pEF,e,b{1}' -f $bios, $uefi
    $code = Invoke-Native $Oscdimg @('-m', '-o', '-u2', '-udfver102', "-l$Label", "-bootdata:$bootData", $IsoRoot, $OutputPath) -ShowOutput
    if ($code -ne 0) { throw "oscdimg завершился с кодом $code" }
}
