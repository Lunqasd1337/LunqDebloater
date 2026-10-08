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
    # Если прошлый запуск прервали на шаге реестра, его кусты остались загружены,
    # и DISM не сможет отключить образ, пока они открыты.
    Dismount-OfflineHives
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

function Test-LunqOutputPath {
    # Можно ли записать итоговый ISO: папка есть, писать в неё можно, и это не исходный ISO.
    # Возвращает текст проблемы или $null.
    param([Parameter(Mandatory)][string]$OutputIso, [Parameter(Mandatory)][string]$IsoPath)

    if ($OutputIso.TrimEnd('\', '/') -eq $IsoPath.TrimEnd('\', '/')) { return 'это исходный ISO, он был бы перезаписан' }
    if (Test-Path -LiteralPath $OutputIso -PathType Container) { return 'это папка, а нужен путь к файлу .iso' }
    $folder = Split-Path $OutputIso -Parent
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { return "папки $folder нет, создайте её" }
    $probe = Join-Path $folder (".lunq_write_test_{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
    catch { return "в папку $folder нельзя записать файл" }
    return $null
}

function Get-LunqHostWarning {
    # Предупреждение, если Windows на этом компьютере старше образа: модуль DISM берётся из
    # системы и со свежими накопительными обновлениями новой версии может не справиться.
    param([int]$ImageBuild, [int]$HostBuild = (Get-LunqHostBuild))
    if ($HostBuild -le 0 -or $ImageBuild -le 0 -or $HostBuild -ge $ImageBuild) { return $null }
    $hostName = Get-WindowsReleaseName -Build $HostBuild
    if (-not $hostName -and $HostBuild -lt 22000) { $hostName = 'Windows 10' }
    if ($hostName) { $hostName = " ($hostName)" }
    return "Windows на этом компьютере (сборка $HostBuild$hostName) старше образа ($ImageBuild). DISM этой системы может не справиться с частью шагов, чаще всего со встраиванием обновлений."
}

function Get-LunqDriveInfo {
    # Диск, на котором лежит путь: имя, файловая система и свободное место.
    param([Parameter(Mandatory)][string]$Path)
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))
    return [pscustomobject]@{ Name = $drive.Name; DriveFormat = $drive.DriveFormat; AvailableFreeSpace = $drive.AvailableFreeSpace }
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
        [switch]$SkipOscdimg,
        [switch]$SkipOutputCheck,
        [string[]]$OwnMountPaths = @()
    )

    $result = [pscustomobject]@{ Oscdimg = $null; Errors = 0; Warnings = 0 }

    $workDirProblem = Test-LunqWorkDir -WorkDir $WorkDir -ProtectedPaths $ProtectedPaths -IsDefault:$DefaultWorkDir
    if ($workDirProblem) {
        Write-Check Fail "Рабочая папка $($WorkDir): $workDirProblem" 'Скрипт полностью очищает рабочую папку. Укажите через -WorkDir новую или пустую папку, например D:\LunqWork.'
        $result.Errors++
    }

    # Итоговый ISO пишется последним шагом, поэтому папку для него лучше проверить сейчас.
    if (-not $SkipOutputCheck) {
        $outputProblem = Test-LunqOutputPath -OutputIso $OutputIso -IsoPath $IsoPath
        if ($outputProblem) {
            Write-Check Fail "Итоговый ISO $($OutputIso): $outputProblem" 'Укажите другой путь через -OutputIso.'
            $result.Errors++
        }
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
    $workDrive = Get-LunqDriveInfo -Path $WorkDir
    $outDrive = $null
    if ($OutputIso.StartsWith('\\')) {
        Write-Info "Итоговый ISO будет сохранён в сетевую папку, свободное место там не проверяется."
    }
    else {
        $outDrive = Get-LunqDriveInfo -Path $OutputIso
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

    # Остатки прерванного запуска в своей рабочей папке скрипт отключит сам, предупреждать стоит только о чужих.
    $mountedPaths = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | ForEach-Object { $_.Path })
    $own = @($mountedPaths | Where-Object { $OwnMountPaths -contains $_ })
    $foreign = @($mountedPaths | Where-Object { $OwnMountPaths -notcontains $_ })
    if ($own.Count -gt 0) {
        Write-Check Ok 'Остался образ от прерванного запуска, он будет отключён без сохранения перед сборкой'
    }
    if ($foreign.Count -gt 0) {
        Write-Check Warn "В системе уже есть смонтированные образы DISM: $($foreign -join ', ')" 'Если это остатки старого запуска в другой папке, выполните: dism /Cleanup-Wim'
        $result.Warnings++
    }

    return $result
}
