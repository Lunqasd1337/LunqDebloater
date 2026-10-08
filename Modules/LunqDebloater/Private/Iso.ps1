function Mount-IsoImage {
    # Подключает ISO и возвращает его корень (Root, например "E:\"). Если ISO уже подключён,
    # например открыт в Проводнике, берётся его буква, и Dismount-IsoImage его не отключит.
    param([Parameter(Mandatory)][string]$IsoPath)

    $attached = $false
    try { $attached = [bool](Get-DiskImage -ImagePath $IsoPath -ErrorAction Stop).Attached } catch { $attached = $false }
    if ($attached) { $image = Get-DiskImage -ImagePath $IsoPath }
    else { $image = Mount-DiskImage -ImagePath $IsoPath -PassThru }
    $iso = [pscustomobject]@{ IsoPath = $IsoPath; Root = $null; Owned = -not $attached }
    # Буква диска иногда назначается с задержкой.
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $volume = $image | Get-Volume -ErrorAction SilentlyContinue
        if ($volume -and $volume.DriveLetter) {
            $iso.Root = "$($volume.DriveLetter):\"
            return $iso
        }
        Start-Sleep -Seconds 1
    }
    Dismount-IsoImage -Iso $iso
    throw 'Не удалось получить букву диска подключённого ISO.'
}

function Dismount-IsoImage {
    # Отключает ISO, только если его подключил сам скрипт.
    param([Parameter(Mandatory)]$Iso)
    if ($Iso.Owned) { Dismount-DiskImage -ImagePath $Iso.IsoPath | Out-Null }
}

function Get-IsoEditions {
    # Список редакций прямо из подключённого ISO, ещё до копирования файлов.
    param([Parameter(Mandatory)][string]$IsoRoot)

    try { $imagePath = Get-InstallImagePath -IsoRoot $IsoRoot }
    catch { throw 'В ISO нет sources\install.wim или install.esd. Похоже, это не установочный образ Windows.' }
    return , @(Get-WindowsImage -ImagePath $imagePath | Sort-Object ImageIndex)
}

function Get-IsoImageInfo {
    # Версия и архитектура выбранной редакции прямо из подключённого ISO, без копирования.
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)][int]$Index
    )

    $image = Get-WindowsImage -ImagePath (Get-InstallImagePath -IsoRoot $IsoRoot) -Index $Index
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

    $iso = Mount-IsoImage -IsoPath $IsoPath
    $source = $iso.Root
    try {
        Write-Info "ISO подключён как $source, копирую файлы..."

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # robocopy возвращает коды < 8 при успехе.
        $code = Invoke-Native robocopy.exe @($source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        if ($code -ge 8) { throw "robocopy завершился с кодом $code" }
    }
    finally {
        Dismount-IsoImage -Iso $iso
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
        Write-Host ("    {0,-4} " -f "[$($img.ImageIndex)]") -ForegroundColor Cyan -NoNewline
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
