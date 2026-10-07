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

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "    $Message"
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

function Copy-IsoContent {
    # Монтирует ISO, копирует его содержимое в рабочую папку и снимает атрибут «только чтение».
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $image = Mount-DiskImage -ImagePath $IsoPath -PassThru
    try {
        # Буква диска иногда назначается с задержкой.
        $volume = $null
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $volume = $image | Get-Volume -ErrorAction SilentlyContinue
            if ($volume -and $volume.DriveLetter) { break }
            Start-Sleep -Seconds 1
        }
        if (-not ($volume -and $volume.DriveLetter)) { throw 'Не удалось получить букву диска смонтированного ISO.' }
        $source = "$($volume.DriveLetter):\"
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

function Resolve-EditionIndex {
    # Определяет индекс редакции по номеру, имени или интерактивному выбору.
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [int]$Index,
        [string]$Edition
    )

    $images = @(Get-WindowsImage -ImagePath $ImagePath)

    if ($Index -gt 0) {
        if (-not ($images | Where-Object ImageIndex -eq $Index)) {
            throw "В образе нет редакции с индексом $Index."
        }
        return $Index
    }

    if ($Edition) {
        $match = @($images | Where-Object { $_.ImageName -eq $Edition })
        if ($match.Count -eq 0) {
            $names = ($images | ForEach-Object { $_.ImageName }) -join '; '
            throw "Редакция '$Edition' не найдена. Доступны: $names"
        }
        return $match[0].ImageIndex
    }

    Write-Info 'Редакции в образе:'
    foreach ($img in $images) { Write-Info ("  [{0}] {1}" -f $img.ImageIndex, $img.ImageName) }
    while ($true) {
        $answer = Read-Host '    Введите номер редакции'
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and ($images | Where-Object ImageIndex -eq $parsed)) {
            return $parsed
        }
        Write-Warning 'Неверный номер, попробуйте ещё раз.'
    }
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

    $patterns = Get-ConfigList $Config 'Appx', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info 'Список Appx в профиле пуст.'; return }

    $packages = @(Get-AppxProvisionedPackage -Path $MountPath)
    $removed = 0
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.DisplayName -Patterns $patterns) {
            Write-Info "Удаляю $($pkg.DisplayName)"
            try {
                Remove-AppxProvisionedPackage -Path $MountPath -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                $removed++
            }
            catch { Write-Warning "Не удалось удалить $($pkg.DisplayName): $($_.Exception.Message)" }
        }
    }
    Write-Info "Удалено Appx-пакетов: $removed из $($packages.Count)."
}

function Remove-LunqCapabilities {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $patterns = Get-ConfigList $Config 'Capabilities', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info 'Список Capabilities в профиле пуст.'; return }

    $installed = @(Get-WindowsCapability -Path $MountPath | Where-Object State -eq 'Installed')
    foreach ($cap in $installed) {
        if (Test-NamePattern -Name $cap.Name -Patterns $patterns) {
            Write-Info "Удаляю компонент $($cap.Name)"
            try { Remove-WindowsCapability -Path $MountPath -Name $cap.Name -ErrorAction Stop | Out-Null }
            catch { Write-Warning "Не удалось удалить $($cap.Name): $($_.Exception.Message)" }
        }
    }
}

function Disable-LunqFeatures {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $patterns = Get-ConfigList $Config 'Features', 'Disable'
    if ($patterns.Count -eq 0) { Write-Info 'Список Features в профиле пуст.'; return }

    $removePayload = [bool](Get-ConfigValue $Config 'Features', 'RemovePayload')

    $enabled = @(Get-WindowsOptionalFeature -Path $MountPath | Where-Object State -eq 'Enabled')
    foreach ($feature in $enabled) {
        if (Test-NamePattern -Name $feature.FeatureName -Patterns $patterns) {
            Write-Info "Отключаю компонент $($feature.FeatureName)"
            try {
                $params = @{ Path = $MountPath; FeatureName = $feature.FeatureName; NoRestart = $true; ErrorAction = 'Stop' }
                if ($removePayload) { $params.Remove = $true }
                Disable-WindowsOptionalFeature @params | Out-Null
            }
            catch { Write-Warning "Не удалось отключить $($feature.FeatureName): $($_.Exception.Message)" }
        }
    }
}

function Remove-LunqPackages {
    # Удаление CBS-пакетов. Может сломать обслуживание образа, поэтому в профиле по умолчанию пусто.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $patterns = Get-ConfigList $Config 'Packages', 'Remove'
    if ($patterns.Count -eq 0) { return }

    Write-Warning 'Удаление системных пакетов может помешать установке обновлений.'
    $packages = @(Get-WindowsPackage -Path $MountPath | Where-Object PackageState -eq 'Installed')
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.PackageName -Patterns $patterns) {
            Write-Info "Удаляю пакет $($pkg.PackageName)"
            try { Remove-WindowsPackage -Path $MountPath -PackageName $pkg.PackageName -NoRestart -ErrorAction Stop | Out-Null }
            catch { Write-Warning "Не удалось удалить $($pkg.PackageName): $($_.Exception.Message)" }
        }
    }
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

    $entries = Get-ConfigList $Config 'Registry'
    if ($entries.Count -eq 0) { Write-Info 'Список твиков реестра в профиле пуст.'; return }

    Mount-OfflineHives -MountPath $MountPath
    try {
        $stats = @{ Applied = 0; Skipped = 0; Failed = 0 }
        foreach ($entry in $entries) {
            $stats[(Invoke-RegistryEntry -Entry $entry)]++
        }
        Write-Info ("Реестр: применено {0}, пропущено (уже нет) {1}, ошибок {2}." -f $stats.Applied, $stats.Skipped, $stats.Failed)
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
