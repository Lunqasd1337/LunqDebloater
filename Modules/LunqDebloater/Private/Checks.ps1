function Test-PathInside {
    # $true, если путь совпадает с папкой или лежит внутри неё.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Folder)
    $sep = [IO.Path]::DirectorySeparatorChar
    $p = $Path.TrimEnd('\', '/') + $sep
    $f = $Folder.TrimEnd('\', '/') + $sep
    return $p.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)
}

$script:WorkDirMarker = '.lunqdebloater'
# Что скрипт создаёт в рабочей папке. Папка по умолчанию без метки годится, только если в ней нет
# ничего другого: её мог оставить запуск версии, которая ещё не ставила метку.
$script:WorkDirItems = @('iso', 'mount', 'bootmount', 'remount', 'scratch', 'winre.wim')

function Test-LunqWorkDir {
    # Рабочая папка удаляется целиком, поэтому годится только новая, пустая или уже
    # созданная скриптом (с файлом-меткой) папка. Возвращает текст проблемы или $null.
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [string[]]$ProtectedPaths = @(),
        [switch]$IsDefault
    )

    if ($WorkDir.TrimEnd('\', '/') -eq ([IO.Path]::GetPathRoot($WorkDir)).TrimEnd('\', '/')) {
        return (Get-LunqText 'Checks.WorkDirIsRoot')
    }
    foreach ($path in $ProtectedPaths) {
        if ($path -and (Test-PathInside -Path $path -Folder $WorkDir)) {
            return (Get-LunqText 'Checks.WorkDirContainsPath' $path)
        }
    }
    if ((Test-Path -LiteralPath $WorkDir -PathType Leaf)) { return (Get-LunqText 'Checks.WorkDirIsFile') }
    # Ссылка (junction, symlink) вместо рабочей папки: создание и удаление пошли бы в папку, на которую она указывает.
    if ((Test-Path -LiteralPath $WorkDir) -and (Test-LunqReparsePoint -Path $WorkDir)) { return (Get-LunqText 'Checks.WorkDirIsLink') }
    if ((Test-Path -LiteralPath $WorkDir) -and -not (Test-Path -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker))) {
        $items = @(Get-ChildItem -LiteralPath $WorkDir -Force)
        if ($IsDefault) { $items = @($items | Where-Object { $script:WorkDirItems -notcontains $_.Name }) }
        if ($items.Count -gt 0) {
            return (Get-LunqText 'Checks.WorkDirNotEmpty')
        }
    }
    return $null
}

function Test-LunqReparsePoint {
    # Ссылка ли это (junction, symlink, точка монтирования), а не обычный файл или папка.
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Remove-LunqTree {
    # Удаляет папку, не заходя в ссылки. Remove-Item -Recurse в Windows PowerShell 5.1 проходит
    # по junction и удалил бы содержимое папки, на которую указывает ссылка. Такую ссылку в старой
    # рабочей папке мог заранее оставить обычный пользователь, поэтому удаляется только сама ссылка.
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { Remove-Item -LiteralPath $Path -Force; return }
    if (Test-LunqReparsePoint -Path $Path) { [IO.Directory]::Delete($item.FullName, $false); return }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) { Remove-LunqTree -Path $child.FullName }
    Remove-Item -LiteralPath $Path -Force
}

function Remove-LunqWorkDir {
    # Удаляет рабочую папку после сборки. Файл-метка удаляется последним: если какой-то файл занят
    # антивирусом или Проводником, папка с меткой остаётся своей, и следующий запуск её очистит.
    # Возвращает $true, если папки больше нет.
    param([Parameter(Mandatory)][string]$WorkDir)
    foreach ($item in @(Get-ChildItem -LiteralPath $WorkDir -Force | Where-Object { $_.Name -ne $script:WorkDirMarker })) {
        try { Remove-LunqTree -Path $item.FullName } catch { Write-Verbose $_.Exception.Message }
    }
    $left = @(Get-ChildItem -LiteralPath $WorkDir -Force | Where-Object { $_.Name -ne $script:WorkDirMarker })
    if ($left.Count -eq 0) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    return -not (Test-Path -LiteralPath $WorkDir)
}

function Initialize-LunqWorkDir {
    # Создаёт рабочую папку с файлом-меткой, по которой скрипт узнаёт свою папку.
    param([Parameter(Mandatory)][string]$WorkDir)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    # Папка в корне диска наследует права, с которыми обычный пользователь может менять файлы.
    # Тогда он подменил бы install.wim или скрипты первого входа, пока идёт сборка, поэтому
    # доступ к папке и всему в ней остаётся только у администраторов и SYSTEM.
    Set-LunqAdminOnlyAccess -Path $WorkDir
    Set-Content -LiteralPath (Join-Path $WorkDir $script:WorkDirMarker) -Value (Get-LunqText 'Checks.WorkDirMarker') -Encoding UTF8
}

function Set-LunqAdminOnlyAccess {
    # Менять папку и всё в ней могут только администраторы и SYSTEM. Владельцем становятся
    # администраторы: владелец всегда может поменять права, и одних прав для папки, которую
    # заранее создал обычный пользователь, было бы мало.
    # Права NTFS есть только в Windows; тесты в Linux подменяют $env:OS, поэтому проверяется сама платформа.
    # Без прав администратора (так идут тесты на обычной учётной записи) папка закрылась бы от самого
    # процесса, а сборка без них всё равно не запускается.
    param([Parameter(Mandatory)][string]$Path)
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $identity = New-Object System.Security.Principal.SecurityIdentifier $sid
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule $identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Reset-LunqWorkDir {
    # Отключает образы, оставшиеся от прошлого запуска, и создаёт рабочую папку заново.
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string[]]$MountPaths)
    # Если прошлый запуск прервали на шаге реестра, его кусты остались загружены,
    # и DISM не сможет отключить образ, пока они открыты.
    Dismount-OfflineHives -Strict
    $mounted = Get-LunqMountedPaths -Paths $MountPaths
    # DISM не ответил: папку нельзя удалять, в ней может быть смонтирован образ.
    if ($null -eq $mounted) { throw (Get-LunqText 'Checks.MountQueryFailed' $WorkDir) }
    foreach ($leftover in $mounted) {
        Write-Info (Get-LunqText 'Checks.LeftoverMount' $leftover)
        Dismount-WindowsImage -Path $leftover -Discard | Out-Null
    }
    if (Test-Path -LiteralPath $WorkDir) { Remove-LunqTree -Path $WorkDir }
    Initialize-LunqWorkDir -WorkDir $WorkDir
}

function Get-LunqMountedPaths {
    # Какие из указанных папок сейчас заняты смонтированным образом DISM. Если DISM не ответил,
    # возвращает $null, а не пустой список: «не знаю» нельзя считать «ничего не смонтировано».
    param([string[]]$Paths)
    try { $mountedImages = @(Get-WindowsImage -Mounted -ErrorAction Stop) }
    catch { return $null }
    return , @($mountedImages | Where-Object { $Paths -contains $_.Path } | ForEach-Object { $_.Path })
}

function Test-LunqAnyMounted {
    # Занята ли хоть одна из папок образом. Если DISM не ответил, считается, что занята:
    # так рабочая папка остаётся на диске, а не удаляется вместе со смонтированным образом.
    param([string[]]$Paths)
    $mounted = Get-LunqMountedPaths -Paths $Paths
    return ($null -eq $mounted) -or ($mounted.Count -gt 0)
}

function Test-LunqWritableFolder {
    # Можно ли создать файл в папке. Атрибут «только чтение» у папки в Windows запись не запрещает,
    # поэтому надёжнее всего записать пробный файл.
    param([Parameter(Mandatory)][string]$Folder)
    $probe = Join-Path $Folder (".lunq_write_test_{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

function Test-LunqOutputPath {
    # Можно ли записать итоговый ISO: папка есть, писать в неё можно, и это не исходный ISO.
    # Возвращает текст проблемы или $null.
    param([Parameter(Mandatory)][string]$OutputIso, [Parameter(Mandatory)][string]$IsoPath)

    if ($OutputIso.TrimEnd('\', '/') -eq $IsoPath.TrimEnd('\', '/')) { return (Get-LunqText 'Checks.OutputIsSource') }
    if (Test-Path -LiteralPath $OutputIso -PathType Container) { return (Get-LunqText 'Checks.OutputIsFolder') }
    $folder = Split-Path $OutputIso -Parent
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { return (Get-LunqText 'Checks.OutputNoFolder' $folder) }
    if (-not (Test-LunqWritableFolder -Folder $folder)) { return (Get-LunqText 'Checks.OutputNotWritable' $folder) }
    # Прошлый ISO, подключённый в Проводнике как диск, не даст его заменить. Без этой проверки
    # сборка узнала бы об этом только на последнем шаге, через час работы.
    if (Test-Path -LiteralPath $OutputIso -PathType Leaf) {
        try { [IO.File]::Open($OutputIso, 'Open', 'ReadWrite', 'None').Dispose() }
        catch { return (Get-LunqText 'Checks.OutputLocked' $OutputIso) }
    }
    return $null
}

function Get-LunqDefaultOutputName {
    # Имя итогового ISO по умолчанию, без версии: <имя исходного ISO>_Lunq.
    param([Parameter(Mandatory)][string]$IsoPath)
    return ('{0}_Lunq' -f [IO.Path]::GetFileNameWithoutExtension($IsoPath))
}

function Get-LunqOutputIsoPath {
    # Итоговый ISO рядом с исходным: имя и версия LunqDebloater, по ней видно, какой версией собран
    # образ. Версия подставляется при каждой сборке, поэтому в рецепт пишется имя без неё.
    param([Parameter(Mandatory)][string]$IsoPath, [string]$Name)
    if (-not $Name) { $Name = Get-LunqDefaultOutputName -IsoPath $IsoPath }
    return (Join-Path (Split-Path $IsoPath -Parent) ('{0}_{1}.iso' -f $Name, (Get-LunqVersion)))
}

function Test-LunqOutputName {
    # Что не так с именем итогового ISO, или $null. Правила имён файлов Windows: без \ / : * ? " < > |,
    # не зарезервированное имя устройства и без точки или пробела в конце.
    param([AllowEmptyString()][string]$Name)
    if (-not $Name -or -not $Name.Trim()) { return Get-LunqText 'Checks.OutputNameEmpty' }
    if ($Name.Length -gt 100) { return Get-LunqText 'Checks.OutputNameTooLong' $Name }
    if ($Name -match '[\\/:*?"<>|]' -or $Name -match '[\x00-\x1F]') { return Get-LunqText 'Checks.OutputNameBadChars' $Name }
    if ($Name -ne $Name.Trim() -or $Name.EndsWith('.') -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return Get-LunqText 'Checks.OutputNameBadForm' $Name }
    return $null
}

function Read-LunqOutputName {
    # Имя итогового ISO в пошаговом режиме. Enter оставляет имя по умолчанию, .iso в конце можно
    # не писать: версия и расширение добавляются сами.
    param([Parameter(Mandatory)][string]$Default)
    while ($true) {
        $answer = ([string](Read-Host ('    ' + (Get-LunqText 'Checks.AskOutputName' $Default (Get-LunqVersion))))).Trim()
        if (-not $answer) { return $Default }
        $answer = $answer -replace '\.iso$', ''
        $problem = Test-LunqOutputName -Name $answer
        if (-not $problem) { return $answer }
        Write-Warning $problem
    }
}

function Get-LunqHostWarning {
    # Предупреждение, если Windows на этом компьютере старше образа: модуль DISM берётся из
    # системы и со свежими накопительными обновлениями новой версии может не справиться.
    param([int]$ImageBuild, [int]$HostBuild = (Get-LunqHostBuild))
    if ($HostBuild -le 0 -or $ImageBuild -le 0 -or $HostBuild -ge $ImageBuild) { return $null }
    $hostName = Get-WindowsReleaseName -Build $HostBuild
    # Выпуски старше 24H2 в таблице не названы: для предупреждения хватает «Windows 10» или «Windows 11».
    if (-not $hostName -and $HostBuild -lt 22000) { $hostName = 'Windows 10' }
    elseif (-not $hostName) { $hostName = 'Windows 11' }
    if ($hostName) { $hostName = " ($hostName)" }
    return (Get-LunqText 'Checks.HostOlder' $HostBuild $hostName $ImageBuild)
}

function Get-LunqDriveInfo {
    # Диск, на котором лежит путь: имя, тип (Fixed, Removable, Network), файловая система и свободное место.
    param([Parameter(Mandatory)][string]$Path)
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))
    return [pscustomobject]@{ Name = $drive.Name; DriveType = [string]$drive.DriveType; DriveFormat = $drive.DriveFormat; AvailableFreeSpace = $drive.AvailableFreeSpace }
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

    $result = [pscustomobject]@{ Oscdimg = $null; Errors = 0; Warnings = 0; SpaceLow = $false }

    $workDirProblem = Test-LunqWorkDir -WorkDir $WorkDir -ProtectedPaths $ProtectedPaths -IsDefault:$DefaultWorkDir
    if ($workDirProblem) {
        Write-Check Fail (Get-LunqText 'Checks.WorkDirProblem' $WorkDir $workDirProblem) (Get-LunqText 'Checks.WorkDirProblemHint')
        $result.Errors++
    }

    # Итоговый ISO пишется последним шагом, поэтому папку для него лучше проверить сейчас.
    if (-not $SkipOutputCheck) {
        $outputProblem = Test-LunqOutputPath -OutputIso $OutputIso -IsoPath $IsoPath
        if ($outputProblem) {
            Write-Check Fail (Get-LunqText 'Checks.OutputProblem' $OutputIso $outputProblem) (Get-LunqText 'Checks.OutputProblemHint')
            $result.Errors++
        }
    }

    if (-not $SkipOscdimg) {
        try {
            $result.Oscdimg = Find-Oscdimg -Path $OscdimgPath
            Write-Check Ok (Get-LunqText 'Checks.Adk' $result.Oscdimg)
        }
        catch {
            Write-Check Fail (Get-LunqText 'Checks.AdkMissing') (Get-LunqText 'Checks.AdkMissingHint')
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
        Write-Check Fail (Get-LunqText 'Checks.WorkDirNetwork' $WorkDir) (Get-LunqText 'Checks.WorkDirNetworkHint')
        $result.Errors++
        return $result
    }
    $workDrive = Get-LunqDriveInfo -Path $WorkDir
    # Подключённый сетевой диск (Z:\Work) отвечает, что он NTFS, но DISM на нём образ не монтирует.
    if ($workDrive.DriveType -eq 'Network') {
        Write-Check Fail (Get-LunqText 'Checks.WorkDirNetwork' $WorkDir) (Get-LunqText 'Checks.WorkDirNetworkHint')
        $result.Errors++
        return $result
    }
    $outDrive = $null
    if ($OutputIso.StartsWith('\\')) {
        Write-Info (Get-LunqText 'Checks.OutputNetwork')
    }
    else {
        $outDrive = Get-LunqDriveInfo -Path $OutputIso
    }

    if ($workDrive.DriveFormat -ne 'NTFS') {
        Write-Check Fail (Get-LunqText 'Checks.WorkDirNotNtfs' $workDrive.Name $workDrive.DriveFormat) (Get-LunqText 'Checks.WorkDirNotNtfsHint')
        $result.Errors++
    }

    if ($outDrive -and $workDrive.Name -eq $outDrive.Name) { $needWork += $needOut }
    if ($workDrive.AvailableFreeSpace -ge $needWork) {
        Write-Check Ok (Get-LunqText 'Checks.WorkSpaceOk' $workDrive.Name (Format-Size $workDrive.AvailableFreeSpace) (Format-Size $needWork))
    }
    else {
        Write-Check Warn (Get-LunqText 'Checks.WorkSpaceLow' $workDrive.Name (Format-Size $workDrive.AvailableFreeSpace) (Format-Size $needWork)) (Get-LunqText 'Checks.WorkSpaceLowHint')
        $result.Warnings++
        $result.SpaceLow = $true
    }
    if ($outDrive -and $workDrive.Name -ne $outDrive.Name) {
        if ($outDrive.AvailableFreeSpace -ge $needOut) {
            Write-Check Ok (Get-LunqText 'Checks.OutputSpaceOk' $outDrive.Name (Format-Size $outDrive.AvailableFreeSpace))
        }
        else {
            Write-Check Warn (Get-LunqText 'Checks.OutputSpaceLow' $outDrive.Name (Format-Size $outDrive.AvailableFreeSpace) (Format-Size $needOut))
            $result.Warnings++
            $result.SpaceLow = $true
        }
    }

    # Остатки прерванного запуска в своей рабочей папке скрипт отключит сам, предупреждать стоит только о чужих.
    $mountedPaths = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | ForEach-Object { $_.Path })
    $own = @($mountedPaths | Where-Object { $OwnMountPaths -contains $_ })
    $foreign = @($mountedPaths | Where-Object { $OwnMountPaths -notcontains $_ })
    if ($own.Count -gt 0) {
        Write-Check Ok (Get-LunqText 'Checks.OwnMount')
    }
    if ($foreign.Count -gt 0) {
        Write-Check Warn (Get-LunqText 'Checks.ForeignMount' ($foreign -join ', ')) (Get-LunqText 'Checks.ForeignMountHint')
        $result.Warnings++
    }

    return $result
}
