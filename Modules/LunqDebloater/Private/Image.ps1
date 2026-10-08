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

function Invoke-LunqComponentCleanup {
    # Очистка хранилища компонентов (StartComponentCleanup /ResetBase). Через dism.exe, а не
    # Repair-WindowsImage: в модуле DISM старых Windows 10 у него нет этих параметров.
    # Возвращает $true, если очистка прошла. Ошибка не срывает сборку: образ просто больше.
    param([Parameter(Mandatory)][string]$MountPath, [string]$ScratchDir)
    $arguments = @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
    if ($ScratchDir) {
        New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
        $arguments += "/ScratchDir:$ScratchDir"
    }
    if ($script:DismLogPath) { $arguments += "/LogPath:$($script:DismLogPath)" }
    $code = Invoke-Native dism.exe $arguments
    if ($code -eq 0) { return $true }
    Write-Warning "Очистка хранилища компонентов не удалась (dism.exe вернул код $code), образ будет больше. Подробности в логе DISM."
    return $false
}

function Find-Oscdimg {
    param([string]$Path)

    if ($Path) {
        if (Test-Path -LiteralPath $Path) { return $Path }
        throw "oscdimg.exe не найден по пути $Path"
    }

    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    # В ADK oscdimg лежит в папке под архитектуру компьютера: amd64, arm64 или x86.
    $tools = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
    $folders = @()
    if ($env:PROCESSOR_ARCHITECTURE) { $folders += $env:PROCESSOR_ARCHITECTURE.ToLower() }
    $folders += 'amd64', 'x86'
    foreach ($folder in ($folders | Select-Object -Unique)) {
        $adk = Join-Path $tools "$folder\Oscdimg\oscdimg.exe"
        if (Test-Path -LiteralPath $adk) { return $adk }
    }

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

    # Путь с пробелом внутри -bootdata пришлось бы брать в кавычки, а Windows PowerShell 5.1
    # передаёт такие аргументы искажёнными. Тогда oscdimg запускается из папки над IsoRoot,
    # и загрузочные файлы указываются относительным путём без пробелов.
    $source = $IsoRoot
    $location = $null
    if ($IsoRoot -match '\s') {
        $location = Split-Path $IsoRoot -Parent
        $source = Split-Path $IsoRoot -Leaf
        if ($source -match '\s') { throw "В имени папки $source есть пробел, oscdimg не сможет собрать ISO." }
        $bios = Join-Path $source 'boot\etfsboot.com'
        $uefi = Join-Path $source 'efi\microsoft\boot\efisys.bin'
    }
    $bootData = '2#p0,e,b{0}#pEF,e,b{1}' -f $bios, $uefi
    if ($location) { Push-Location -LiteralPath $location }
    try { $code = Invoke-Native $Oscdimg @('-m', '-o', '-u2', '-udfver102', "-l$Label", "-bootdata:$bootData", $source, $OutputPath) -ShowOutput }
    finally { if ($location) { Pop-Location } }
    if ($code -ne 0) { throw "oscdimg завершился с кодом $code" }
}
