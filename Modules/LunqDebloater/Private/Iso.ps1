function Get-LunqIsoStateFile {
    # Список ISO, которые подключил сам скрипт. Если запуск убили, пока ISO был подключён, следующий
    # запуск узнает его по этому списку и отключит, а не примет за открытый пользователем.
    return (Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater\MountedIso.txt')
}

function Set-LunqIsoOwned {
    # Добавляет ISO в список подключённых скриптом или убирает из него.
    param([Parameter(Mandatory)][string]$IsoPath, [switch]$Remove)
    $file = Get-LunqIsoStateFile
    $list = @()
    if (Test-Path -LiteralPath $file -PathType Leaf) { $list = @(Get-Content -LiteralPath $file | Where-Object { $_ -and $_ -ne $IsoPath }) }
    if (-not $Remove) { $list += $IsoPath }
    if ($list.Count -eq 0) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; return }
    New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
    Set-Content -LiteralPath $file -Value $list -Encoding UTF8
}

function Test-LunqIsoOwned {
    # Подключал ли этот ISO сам скрипт (в том числе запуск, который не успел его отключить).
    param([Parameter(Mandatory)][string]$IsoPath)
    $file = Get-LunqIsoStateFile
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    return (@(Get-Content -LiteralPath $file) -contains $IsoPath)
}

function Mount-IsoImage {
    # Подключает ISO и возвращает его корень (Root, например "E:\"). Если ISO уже подключён,
    # например открыт в Проводнике, берётся его буква, и Dismount-IsoImage его не отключит.
    # Исключение: ISO, который подключил прошлый запуск и не отключил, потому что его убили.
    param([Parameter(Mandatory)][string]$IsoPath)

    $attached = $false
    try { $attached = [bool](Get-DiskImage -ImagePath $IsoPath -ErrorAction Stop).Attached } catch { $attached = $false }
    if ($attached) { $image = Get-DiskImage -ImagePath $IsoPath }
    else {
        $image = Mount-DiskImage -ImagePath $IsoPath -PassThru
        Set-LunqIsoOwned -IsoPath $IsoPath
    }
    $owned = (-not $attached) -or (Test-LunqIsoOwned -IsoPath $IsoPath)
    $iso = [pscustomobject]@{ IsoPath = $IsoPath; Root = $null; Owned = $owned }
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
    throw (Get-LunqText 'Iso.NoDriveLetter')
}

function Dismount-IsoImage {
    # Отключает ISO, только если его подключил сам скрипт.
    param([Parameter(Mandatory)]$Iso)
    if (-not $Iso.Owned) { return }
    Dismount-DiskImage -ImagePath $Iso.IsoPath | Out-Null
    Set-LunqIsoOwned -IsoPath $Iso.IsoPath -Remove
}

function Dismount-LunqStateIso {
    # Отключает ISO, который шаги сборки держат подключённым в State.Iso между шагами.
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.Iso) { return }
    $iso = $State.Iso
    $State.Iso = $null
    Dismount-IsoImage -Iso $iso
}

function Get-IsoEditions {
    # Список редакций прямо из подключённого ISO, ещё до копирования файлов.
    param([Parameter(Mandatory)][string]$IsoRoot)

    try { $imagePath = Get-InstallImagePath -IsoRoot $IsoRoot }
    catch { throw (Get-LunqText 'Iso.NotWindowsIso') }
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
    # Числа из перечисления ImageArchitecture модуля DISM: 0 x86, 5 ARM, 9 x64, 12 ARM64.
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
    # Названия берутся из Data\Releases.psd1, там только выпуски начиная с 24H2.
    param([int]$Build)
    $release = @($script:LunqReleases | Where-Object { $_.Build -eq $Build }) | Select-Object -First 1
    if ($release) { return "Windows 11 $($release.Name)" }
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
        $result.Errors.Add((Get-LunqText 'Iso.ArchMismatch' $Info.Architecture $Requirements.Architecture))
    }

    if ($Requirements.Build -gt 0 -and $Info.Build -ne $Requirements.Build) {
        $wanted = [string]$Requirements.Build
        $wantedRelease = Get-WindowsReleaseName -Build $Requirements.Build
        if ($wantedRelease) { $wanted = "$wanted ($wantedRelease)" }
        $result.Errors.Add((Get-LunqText 'Iso.BuildMismatch' $actual $wanted))
    }
    elseif ($Requirements.MinRevision -gt 0 -and $Info.Revision -lt $Requirements.MinRevision) {
        $wanted = '{0}.{1}' -f $Info.Build, $Requirements.MinRevision
        if ($HasCumulativeUpdate) {
            $result.Warnings.Add((Get-LunqText 'Iso.RevisionOldWithUpdate' $actual $wanted))
        }
        else {
            $result.Errors.Add((Get-LunqText 'Iso.RevisionTooOld' $actual $wanted))
        }
    }
    return $result
}

function Copy-IsoContent {
    # Копирует содержимое подключённого ISO в рабочую папку и снимает атрибут «только чтение».
    # install.wim и install.esd (4-7 ГБ) не копируются: шаг Export берёт редакцию прямо с ISO.
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    Write-Info (Get-LunqText 'Iso.Copying' $IsoRoot)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    # robocopy возвращает коды < 8 при успехе.
    $code = Invoke-Native robocopy.exe @($IsoRoot, $Destination, '/E', '/XF', 'install.wim', 'install.esd', '/A-:R', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1') -SuccessCodes (0..7)
    if ($code -ge 8) { throw (Get-LunqText 'Iso.RobocopyFailed' $code) }
}

function Get-InstallImagePath {
    param([Parameter(Mandatory)][string]$IsoRoot)

    foreach ($name in 'install.wim', 'install.esd') {
        $path = Join-Path $IsoRoot "sources\$name"
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw (Get-LunqText 'Iso.NoInstallImage')
}

function Get-EditionHint {
    # Короткое пояснение к редакции для тех, кто выбирает впервые.
    param([Parameter(Mandatory)][string]$Name)

    # Названия редакций в ISO зависят от языка, поэтому шаблоны на английском и русском.
    $hint = switch -Regex ($Name) {
        'for Workstations|для рабочих станций'     { Get-LunqText 'Iso.HintProWorkstations'; break }
        'Pro.*(Education|образовательных)'         { Get-LunqText 'Iso.HintProEducation'; break }
        'Education|образовательных'                { Get-LunqText 'Iso.HintEducation'; break }
        'Enterprise|Корпоративная'                 { Get-LunqText 'Iso.HintEnterprise'; break }
        'Single Language|для одного языка'         { Get-LunqText 'Iso.HintSingleLanguage'; break }
        'Pro'                                      { Get-LunqText 'Iso.HintPro'; break }
        'Home|Домашняя'                            { Get-LunqText 'Iso.HintHome'; break }
        default                                    { '' }
    }
    if ($Name -match '(^|\s)N(\s|$)') { $hint = (Get-LunqText 'Iso.HintN' $hint).TrimStart('. ') }
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
            Write-Info (Get-LunqText 'Iso.AvailableEditions')
            Write-EditionList -Images $Images
            throw (Get-LunqText 'Iso.NoEditionIndex' $Index)
        }
        return $Index
    }

    if ($Edition) {
        $match = @($Images | Where-Object { $_.ImageName -eq $Edition })
        if ($match.Count -eq 0) {
            Write-Info (Get-LunqText 'Iso.AvailableEditions')
            Write-EditionList -Images $Images
            throw (Get-LunqText 'Iso.EditionNotFound' $Edition)
        }
        return $match[0].ImageIndex
    }

    if ($Images.Count -eq 1) {
        Write-Info (Get-LunqText 'Iso.SingleEdition' $Images[0].ImageName)
        return $Images[0].ImageIndex
    }

    Write-Info (Get-LunqText 'Iso.ChooseEdition')
    Write-Info (Get-LunqText 'Iso.ChooseEditionHint')
    Write-Info ''
    Write-EditionList -Images $Images
    Write-Info ''
    while ($true) {
        $answer = Read-Host ('    ' + (Get-LunqText 'Iso.EditionPrompt'))
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and ($Images | Where-Object ImageIndex -eq $parsed)) {
            return $parsed
        }
        Write-Warning (Get-LunqText 'Iso.NoSuchNumber')
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
                $dialog.Title = Get-LunqText 'Iso.DialogTitle'
                $dialog.Filter = Get-LunqText 'Iso.DialogFilter'
                # Невидимое окно-владелец поверх остальных, чтобы диалог не открылся за консолью.
                $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
                $dialogResult = $dialog.ShowDialog($owner)
                $owner.Dispose()
            }
            catch { $useDialog = $false }

            if ($null -ne $dialogResult) {
                if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK) { throw (Get-LunqText 'Iso.SelectCancelled') }
                $path = $dialog.FileName
            }
        }
        if (-not $path) {
            $path = ([string](Read-Host ('    ' + (Get-LunqText 'Iso.PathPrompt')))).Trim().Trim('"')
        }
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf) -and $path -like '*.iso') {
            return (Resolve-Path -LiteralPath $path).Path
        }
        Write-Warning (Get-LunqText 'Iso.FileNotIso' $path)
    }
}
