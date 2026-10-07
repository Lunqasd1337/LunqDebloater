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
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Профиль не найден: $Path"
    }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $config = $json | ConvertFrom-Json

    foreach ($entry in (Get-ConfigList $config 'Registry')) {
        $hive = [string](Get-ConfigValue $entry 'Hive')
        if (-not $script:HiveMap.Contains($hive)) {
            throw "Неизвестный куст '$hive' в профиле. Допустимо: $($script:HiveMap.Keys -join ', ')"
        }
        if (-not (Get-ConfigValue $entry 'Path')) {
            throw "У записи реестра для куста $hive не указан Path."
        }
    }
    return $config
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
    # Показывает профили из папки Profiles и даёт выбрать один.
    param([Parameter(Mandatory)][string]$ProfileDir)

    $files = @(Get-ChildItem -LiteralPath $ProfileDir -Filter '*.json' -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw "В папке $ProfileDir нет профилей (*.json)." }

    $items = foreach ($file in $files) {
        $config = Read-LunqProfile -Path $file.FullName
        $name = Get-ConfigValue $config 'Name'
        if (-not $name) { $name = $file.BaseName }
        [pscustomobject]@{ Path = $file.FullName; Name = $name; Description = Get-ConfigValue $config 'Description' }
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

function Test-LunqPrerequisites {
    # Проверяет всё, что нужно для сборки, до начала долгой работы.
    # Возвращает путь к oscdimg, ошибки и предупреждения.
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$OutputIso,
        [string]$OscdimgPath
    )

    $result = [pscustomobject]@{ Oscdimg = $null; Errors = 0; Warnings = 0 }

    if (Test-Administrator) { Write-Check Ok 'Права администратора' }
    else {
        Write-Check Fail 'Нет прав администратора' 'Запустите PowerShell через «Запуск от имени администратора».'
        $result.Errors++
    }

    try {
        $result.Oscdimg = Find-Oscdimg -Path $OscdimgPath
        Write-Check Ok "Windows ADK: $($result.Oscdimg)"
    }
    catch {
        Write-Check Fail 'Не найден oscdimg.exe из Windows ADK' 'Установите ADK (достаточно компонента Deployment Tools): https://learn.microsoft.com/windows-hardware/get-started/adk-install'
        $result.Errors++
    }

    # Рабочей папке нужно место под копию ISO, экспорт install.wim и распакованный образ.
    $isoSize = (Get-Item -LiteralPath $IsoPath).Length
    $needWork = [long](25GB)
    $needOut = [long]($isoSize + 1GB)
    $workDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WorkDir)))
    $outDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($OutputIso))

    if ($workDrive.DriveFormat -ne 'NTFS') {
        Write-Check Fail "Диск $($workDrive.Name) для рабочей папки не NTFS ($($workDrive.DriveFormat))" 'DISM монтирует образ только на NTFS. Укажите другую папку через -WorkDir.'
        $result.Errors++
    }

    if ($workDrive.Name -eq $outDrive.Name) { $needWork += $needOut }
    if ($workDrive.AvailableFreeSpace -ge $needWork) {
        Write-Check Ok ("Место на {0} для рабочей папки: свободно {1}, нужно около {2}" -f $workDrive.Name, (Format-Size $workDrive.AvailableFreeSpace), (Format-Size $needWork))
    }
    else {
        Write-Check Warn ("Мало места на {0}: свободно {1}, нужно около {2}" -f $workDrive.Name, (Format-Size $workDrive.AvailableFreeSpace), (Format-Size $needWork)) 'Освободите место или укажите папку на другом диске через -WorkDir.'
        $result.Warnings++
    }
    if ($workDrive.Name -ne $outDrive.Name) {
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

function Get-ProfileStats {
    param([Parameter(Mandatory)]$Config)
    return [pscustomobject]@{
        Appx         = (Get-ConfigList $Config 'Appx', 'Remove').Count
        Capabilities = (Get-ConfigList $Config 'Capabilities', 'Remove').Count
        Features     = (Get-ConfigList $Config 'Features', 'Disable').Count
        Packages     = (Get-ConfigList $Config 'Packages', 'Remove').Count
        Registry     = (Get-ConfigList $Config 'Registry').Count
    }
}

function New-LunqResult {
    # Результат шага удаления: что сделано, что не удалось, какие шаблоны профиля ничего не нашли.
    param([string]$Title)
    return [pscustomobject]@{
        Title      = $Title
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
    # Итог сборки: что сделано по каждому разделу профиля.
    param(
        [object[]]$Results = @(),
        $Registry,
        [string]$OutputIso,
        [TimeSpan]$Elapsed
    )

    Write-Section 'Итог'
    foreach ($r in $Results) {
        if ($null -eq $r) { continue }
        Write-Info ("{0}: выполнено {1}, ошибок {2}" -f $r.Title, $r.Done.Count, $r.Failed.Count)
        if ($r.Failed.Count -gt 0) { Write-Host "        Не удалось: $($r.Failed -join ', ')" -ForegroundColor Yellow }
        if ($r.NotMatched.Count -gt 0) {
            Write-Host "        Нет в образе или уже убрано: $($r.NotMatched -join ', ')" -ForegroundColor DarkGray
        }
    }
    if ($Registry) {
        Write-Info ("Реестр: применено {0}, пропущено (уже нет) {1}, ошибок {2}" -f $Registry.Applied, $Registry.Skipped, $Registry.Failed)
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

function Remove-LunqAppx {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Приложения Appx'
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

    $result = New-LunqResult 'Компоненты (Capabilities)'
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

    $result = New-LunqResult 'Функции Windows (Optional Features)'
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

    $result = New-LunqResult 'Системные пакеты'
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
    $name = Get-ConfigValue $Entry 'Name'
    $action = Get-ConfigValue $Entry 'Action'
    if (-not $action) { $action = 'Set' }

    switch ($action) {
        'Set' {
            $type = [string](Get-ConfigValue $Entry 'Type')
            if ($validTypes -notcontains $type) {
                Write-Warning "Пропуск ${key}\${name}: неизвестный тип '$type'"
                return 'Failed'
            }
            $arguments = @('add', $key, '/v', $name, '/t', $type, '/f')
            $data = ConvertTo-RegData -Type $type -Value (Get-ConfigValue $Entry 'Value')
            # Пустую строку reg.exe получает, если /d не передан вовсе.
            if ($data -ne '') { $arguments += @('/d', $data) }
            $code = Invoke-Native reg.exe $arguments
        }
        'DeleteValue' {
            if ((Invoke-Native reg.exe @('query', $key, '/v', $name)) -ne 0) { return 'Skipped' }
            $code = Invoke-Native reg.exe @('delete', $key, '/v', $name, '/f')
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
        foreach ($entry in $entries) {
            $stats[(Invoke-RegistryEntry -Entry $entry)]++
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
