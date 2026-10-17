function Export-SingleEdition {
    # Экспортирует одну редакцию в новый install.wim (заодно конвертирует ESD в WIM).
    # -CompressionType Fast для первого экспорта: после обслуживания образ всё равно пересжимается
    # в Max, и первое сжатие Max только тратило бы минуты. -KeepSource: источник на подключённом
    # ISO, удалять его нельзя.
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [Parameter(Mandatory)][int]$SourceIndex,
        [Parameter(Mandatory)][string]$DestinationImage,
        [ValidateSet('Max', 'Fast')][string]$CompressionType = 'Max',
        [switch]$KeepSource
    )

    $temp = "$DestinationImage.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }

    Export-WindowsImage -SourceImagePath $SourceImage -SourceIndex $SourceIndex `
        -DestinationImagePath $temp -CompressionType $CompressionType -CheckIntegrity | Out-Null

    if (-not $KeepSource) { Remove-Item -LiteralPath $SourceImage -Force }
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
    Write-Warning (Get-LunqText 'Image.CleanupFailed' $code)
    return $false
}

function Find-Oscdimg {
    param([string]$Path)

    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $Path }
        # Вместо файла часто указывают папку Oscdimg из ADK: тогда oscdimg.exe ищется в ней.
        # Без этого папка проходила проверку и ошибка всплывала только на последнем шаге.
        $inFolder = Join-Path $Path 'oscdimg.exe'
        if ((Test-Path -LiteralPath $Path -PathType Container) -and (Test-Path -LiteralPath $inFolder -PathType Leaf)) { return $inFolder }
        throw (Get-LunqText 'Image.OscdimgNotFoundAt' $Path)
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

    throw (Get-LunqText 'Image.OscdimgNotFound')
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
    if (-not (Test-Path -LiteralPath $uefi)) { throw (Get-LunqText 'Image.BootFileMissing' $uefi) }
    # На ISO для ARM64 нет загрузчика BIOS: такой образ грузится только через UEFI.
    $hasBios = Test-Path -LiteralPath $bios

    # Путь с пробелом внутри -bootdata пришлось бы брать в кавычки, а Windows PowerShell 5.1
    # передаёт такие аргументы искажёнными. Тогда oscdimg запускается из папки над IsoRoot,
    # и загрузочные файлы указываются относительным путём без пробелов.
    $source = $IsoRoot
    $location = $null
    if ($IsoRoot -match '\s') {
        $location = Split-Path $IsoRoot -Parent
        $source = Split-Path $IsoRoot -Leaf
        if ($source -match '\s') { throw (Get-LunqText 'Image.FolderNameHasSpace' $source) }
        $bios = Join-Path $source 'boot\etfsboot.com'
        $uefi = Join-Path $source 'efi\microsoft\boot\efisys.bin'
    }
    if ($hasBios) { $bootData = '2#p0,e,b{0}#pEF,e,b{1}' -f $bios, $uefi }
    else { $bootData = '1#pEF,e,b{0}' -f $uefi }
    # oscdimg пишет во временный файл рядом: при сбое прошлый ISO остаётся целым, а недописанный
    # файл не выглядит готовым образом.
    $partial = [IO.Path]::ChangeExtension($OutputPath, '.partial.iso')
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    if ($location) { Push-Location -LiteralPath $location }
    try { $code = Invoke-Native $Oscdimg @('-m', '-o', '-u2', '-udfver102', "-l$Label", "-bootdata:$bootData", $source, $partial) -ShowOutput }
    finally { if ($location) { Pop-Location } }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw (Get-LunqText 'Image.OscdimgFailed' $code)
    }
    try { Move-Item -LiteralPath $partial -Destination $OutputPath -Force -ErrorAction Stop }
    catch { throw (Get-LunqText 'Image.IsoReplaceFailed' $OutputPath $_.Exception.Message $partial) }
}
