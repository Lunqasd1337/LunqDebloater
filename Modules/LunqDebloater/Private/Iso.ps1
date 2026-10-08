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
    throw (Get-LunqText 'Iso.NoDriveLetter')
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
    # Монтирует ISO, копирует его содержимое в рабочую папку и снимает атрибут «только чтение».
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $iso = Mount-IsoImage -IsoPath $IsoPath
    $source = $iso.Root
    try {
        Write-Info (Get-LunqText 'Iso.Copying' $source)

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # robocopy возвращает коды < 8 при успехе.
        $code = Invoke-Native robocopy.exe @($source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        if ($code -ge 8) { throw (Get-LunqText 'Iso.RobocopyFailed' $code) }
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
            $path = (Read-Host ('    ' + (Get-LunqText 'Iso.PathPrompt'))).Trim().Trim('"')
        }
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf) -and $path -like '*.iso') {
            return (Resolve-Path -LiteralPath $path).Path
        }
        Write-Warning (Get-LunqText 'Iso.FileNotIso' $path)
    }
}
