# Имя файла обновления самой Windows (windows11.0-kb...), а не, например, .NET или Office.
$script:WindowsUpdatePattern = '(?i)^windows1[01]\.0-kb'

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
    return [bool](@($Files) | Where-Object { $_.Name -match $script:WindowsUpdatePattern })
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

function Select-LunqPEDrivers {
    # Для установщика и WinRE отбираются только драйверы контроллеров дисков (классы SCSIAdapter
    # и HDC): ради них драйверы туда и добавляют. Все драйверы сразу сильно раздули бы boot.wim,
    # а он при загрузке с флешки целиком распаковывается в память.
    param($InfFiles)
    $diskClasses = @('SCSIAdapter', 'HDC')
    $selected = foreach ($inf in @($InfFiles)) {
        # Get-Content сам распознаёт .inf в UTF-16 по метке BOM.
        $text = Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -and $text -match '(?im)^\s*Class\s*=\s*"?([A-Za-z0-9_]+)' -and $diskClasses -contains $Matches[1]) { $inf }
    }
    return , @($selected)
}

function Select-LunqPEUpdates {
    # Для установщика и WinRE подходят только обновления самой Windows (windows11.0-kb...),
    # обновления .NET (ndp) в Windows PE не ставятся.
    param($Files)
    return , @(@($Files) | Where-Object { $_.Name -match $script:WindowsUpdatePattern -and $_.Name -notmatch '(?i)ndp' })
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
            $null = Invoke-LunqComponentCleanup -MountPath $MountPath -ScratchDir $ScratchDir
        }
        Dismount-WindowsImage -Path $MountPath -Save | Out-Null
    }
    catch {
        Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }
    return $results
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
