# Заглушка модуля DISM (и командлетов Storage для ISO) для тестов. Тесты кладут папку Mocks
# первой в PSModulePath, и Import-Module Dism в LunqDebloater.ps1 загружает этот модуль.
# Ничего не монтирует: пишет в вывод, что было бы сделано, и создаёт файлы-пустышки там,
# где их потом ищет скрипт. Поведение настраивается переменными окружения LUNQ_TEST_*.

function Get-WindowsImage {
    [CmdletBinding()]
    param($ImagePath, $Index, [switch]$Mounted, $LogPath)
    if ($Mounted) {
        if (-not $env:LUNQ_TEST_MOUNTED) { return @() }
        return @($env:LUNQ_TEST_MOUNTED -split ';' | ForEach-Object { [pscustomobject]@{ Path = $_ } })
    }
    $version = if ($env:LUNQ_TEST_IMAGE_VERSION) { $env:LUNQ_TEST_IMAGE_VERSION } else { '10.0.26300.9457' }
    if ($Index) {
        return [pscustomobject]@{
            ImageIndex = [int]$Index; ImageName = 'Windows 11 Pro'; Version = $version; Architecture = 9
            Languages = @('ru-RU (Default)'); DefaultLanguageIndex = 0
        }
    }
    return @(
        [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' },
        [pscustomobject]@{ ImageIndex = 5; ImageName = 'Windows 11 Pro' }
    )
}

function Mount-WindowsImage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ImagePath, [Parameter(Mandatory)]$Index, [Parameter(Mandatory)]$Path, [switch]$ReadOnly, $LogPath)
    Write-Host "    [mock] mount $ImagePath index $Index -> $Path"
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($ImagePath -like '*install.wim') {
        $winre = Join-Path $Path 'Windows\System32\Recovery\Winre.wim'
        New-Item -ItemType Directory -Path (Split-Path $winre) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $winre)) { Set-Content -LiteralPath $winre -Value ('r' * 500) }
        # Образ, в который кто-то уже положил свой Sysprep\unattend.xml.
        if ($env:LUNQ_TEST_SYSPREP_UNATTEND) {
            New-Item -ItemType Directory -Path (Join-Path $Path 'Windows\System32\Sysprep') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'Windows\System32\Sysprep\unattend.xml') -Value '<unattend />'
        }
        # Загрузчик, подписанный Windows UEFI CA 2023 (-BootCA2023). LUNQ_TEST_NO_BOOTEX: образ без него.
        if (-not $env:LUNQ_TEST_NO_BOOTEX) {
            $files = @{
                'Windows\Boot\EFI_EX\bootmgfw_EX.efi'           = 'bootmgfw_EX.efi from install.wim'
                'Windows\Boot\EFI_EX\bootmgr_EX.efi'            = 'bootmgr_EX.efi from install.wim'
                'Windows\Boot\DVD_EX\EFI\en-US\efisys_EX.bin' = 'efisys_EX.bin from install.wim'
                'Windows\Boot\Fonts_EX\wgl4_boot_EX.ttf'        = 'wgl4_boot_EX.ttf from install.wim'
            }
            foreach ($name in $files.Keys) {
                $file = Join-Path $Path $name
                New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
                Set-Content -LiteralPath $file -Value $files[$name]
            }
        }
        # LUNQ_TEST_BOOT_MAIN_CA2023: основной загрузчик уже подписан Windows UEFI CA 2023.
        if ($env:LUNQ_TEST_BOOT_MAIN_CA2023) {
            $files = @{
                'Windows\Boot\EFI\bootmgfw.efi'           = 'bootmgfw.efi CA 2023 from install.wim'
                'Windows\Boot\EFI\bootmgr.efi'            = 'bootmgr.efi CA 2023 from install.wim'
                'Windows\Boot\DVD\EFI\en-US\efisys.bin' = 'efisys.bin CA 2023 from install.wim'
                'Windows\Boot\Fonts\wgl4_boot.ttf'        = 'wgl4_boot.ttf CA 2023 from install.wim'
            }
            foreach ($name in $files.Keys) {
                $file = Join-Path $Path $name
                New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
                Set-Content -LiteralPath $file -Value $files[$name]
            }
        }
    }
    if ($ImagePath -like '*boot.wim') {
        # Установщик внутри boot.wim: его setup.exe и setuphost.exe копируются в sources ISO.
        New-Item -ItemType Directory -Path (Join-Path $Path 'sources') -Force | Out-Null
        foreach ($name in 'setup.exe', 'setuphost.exe') { Set-Content -LiteralPath (Join-Path $Path "sources\$name") -Value 'from boot.wim' }
        # Загрузчик UEFI из WinPE: после обновления boot.wim он заменяет загрузчик на ISO.
        New-Item -ItemType Directory -Path (Join-Path $Path 'Windows\Boot\EFI') -Force | Out-Null
        foreach ($name in 'bootmgfw.efi', 'bootmgr.efi') { Set-Content -LiteralPath (Join-Path $Path "Windows\Boot\EFI\$name") -Value "$name from boot.wim" }
        New-Item -ItemType Directory -Path (Join-Path $Path 'Windows\Boot\DVD\EFI\en-US') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Path 'Windows\Boot\DVD\EFI\en-US\efisys.bin') -Value 'efisys.bin from boot.wim'
    }
}

function Dismount-WindowsImage {
    # Настоящий DISM требует ровно одно из -Save и -Discard.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Path, [switch]$Save, [switch]$Discard, $LogPath)
    if ($Save -eq $Discard) { throw 'Dismount-WindowsImage: exactly one of -Save and -Discard is required' }
    Write-Host "    [mock] dismount $Path save=$Save discard=$Discard"
}

function Export-WindowsImage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SourceImagePath, [Parameter(Mandatory)]$SourceIndex, [Parameter(Mandatory)]$DestinationImagePath, $CompressionType, [switch]$CheckIntegrity, [switch]$SetBootable, $LogPath)
    Write-Host "    [mock] export $SourceImagePath index $SourceIndex compression $CompressionType"
    Add-Content -LiteralPath $DestinationImagePath -Value 'wim'
}

function Get-AppxProvisionedPackage {
    [CmdletBinding()]
    param($Path, [switch]$Online, $LogPath)
    if ($env:LUNQ_TEST_FAIL_APPX) { throw 'DISM failure to test the rollback' }
    @(
        [pscustomobject]@{ DisplayName = 'Microsoft.BingNews'; PackageName = 'Microsoft.BingNews_1.0_x64' },
        [pscustomobject]@{ DisplayName = 'Microsoft.WindowsCalculator'; PackageName = 'Microsoft.WindowsCalculator_1.0_x64' }
    )
}
function Remove-AppxProvisionedPackage {
    [CmdletBinding()]
    param($Path, [switch]$Online, [Parameter(Mandatory)]$PackageName, $LogPath)
    Write-Host "    [mock] remove provisioned $PackageName online=$Online"
}

function Get-WindowsCapability {
    [CmdletBinding()]
    param($Path, [switch]$Online, $LogPath)
    @(
        [pscustomobject]@{ Name = 'App.StepsRecorder~~~~0.0.1.0'; State = 'Installed' },
        [pscustomobject]@{ Name = 'Language.Basic~~~ru-RU~0.0.1.0'; State = 'Installed' }
    )
}
function Remove-WindowsCapability {
    [CmdletBinding()]
    param($Path, [switch]$Online, [Parameter(Mandatory)]$Name, $LogPath)
    Write-Host "    [mock] remove capability $Name online=$Online"
}
# Возврат компонента и функции на этой Windows (-Restore).
function Add-WindowsCapability {
    [CmdletBinding()]
    param([switch]$Online, [Parameter(Mandatory)]$Name, $LogPath)
    Write-Host "    [mock] add capability $Name online=$Online"
}

function Get-WindowsOptionalFeature {
    [CmdletBinding()]
    param($Path, [switch]$Online, $LogPath)
    @(
        [pscustomobject]@{ FeatureName = 'Recall'; State = 'Enabled' },
        [pscustomobject]@{ FeatureName = 'Microsoft-Hyper-V-All'; State = 'Disabled' }
    )
}
function Disable-WindowsOptionalFeature {
    [CmdletBinding()]
    param($Path, [switch]$Online, [Parameter(Mandatory)]$FeatureName, [switch]$NoRestart, [switch]$Remove, $LogPath)
    Write-Host "    [mock] disable feature $FeatureName online=$Online"
}
function Enable-WindowsOptionalFeature {
    [CmdletBinding()]
    param([switch]$Online, [Parameter(Mandatory)]$FeatureName, [switch]$All, [switch]$NoRestart, $LogPath)
    Write-Host "    [mock] enable feature $FeatureName online=$Online"
}

function Get-WindowsPackage {
    # Пакеты CBS образа. Staged-пакеты не установлены, их удалять не нужно.
    [CmdletBinding()]
    param($Path, [switch]$Online, $LogPath)
    @(
        [pscustomobject]@{ PackageName = 'Microsoft-Windows-Foundation-Package~31bf3856ad364e35~amd64~~10.0.26300.1'; PackageState = 'Installed' },
        [pscustomobject]@{ PackageName = 'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35~amd64~~10.0.26300.1'; PackageState = 'Installed' },
        [pscustomobject]@{ PackageName = 'Microsoft-Windows-Broken-Package~31bf3856ad364e35~amd64~~10.0.26300.1'; PackageState = 'Installed' },
        [pscustomobject]@{ PackageName = 'Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35~wow64~~10.0.26300.1'; PackageState = 'Staged' }
    )
}
function Remove-WindowsPackage {
    [CmdletBinding()]
    param($Path, [switch]$Online, [Parameter(Mandatory)]$PackageName, [switch]$NoRestart, $LogPath)
    Write-Host "    [mock] remove package $PackageName"
    if ($PackageName -match 'Broken') { throw 'The package is permanent and cannot be removed' }
}

function Add-WindowsPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Path, [Parameter(Mandatory)]$PackagePath, $ScratchDirectory, [switch]$NoRestart, $LogPath)
    Write-Host "    [mock] add package $(Split-Path $PackagePath -Leaf)"
    if ((Split-Path $PackagePath -Leaf) -match 'broken') { throw 'The package does not apply to this image' }
    # Так DISM отвечает на пакет для другого образа, например Safe OS Dynamic Update вне WinRE.
    if ((Split-Path $PackagePath -Leaf) -match 'notapplicable') {
        Write-Warning "Не удалось добавить пакет $PackagePath"
        throw 'Сбой Add-WindowsPackage. Код ошибки: 0x800f081e'
    }
}

function Add-WindowsDriver {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Path, [Parameter(Mandatory)]$Driver, $LogPath)
    Write-Host "    [mock] add driver $(Split-Path $Driver -Leaf)"
    # Проверяется только имя файла: путь к временной папке теста содержит GUID, а в нём бывает «bad».
    if ((Split-Path $Driver -Leaf) -match '^bad') { throw 'The driver does not fit this image' }
}

function Export-WindowsDriver {
    # Драйверы этого компьютера: один сетевой драйвер, если тест не попросил пустой результат.
    [CmdletBinding()]
    param([switch]$Online, $Destination, $LogPath)
    if (-not $Online) { throw 'Export-WindowsDriver: only -Online is expected' }
    if ($env:LUNQ_TEST_NO_HOST_DRIVERS) { return }
    $folder = Join-Path $Destination 'oem1.inf_amd64'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $folder 'hostnet.inf') -Value "[Version]`r`nClass=Net"
    [pscustomobject]@{ Driver = 'oem1.inf'; OriginalFileName = (Join-Path $folder 'hostnet.inf') }
}

function Repair-WindowsImage { [CmdletBinding()] param($Path, [switch]$StartComponentCleanup, [switch]$ResetBase, $LogPath) throw 'Repair-WindowsImage must not be called: cleanup goes through dism.exe' }

function Get-DiskImage { [CmdletBinding()] param($ImagePath) [pscustomobject]@{ ImagePath = $ImagePath; Attached = [bool]$env:LUNQ_TEST_ISO_ATTACHED } }
function Mount-DiskImage { [CmdletBinding()] param($ImagePath, [switch]$PassThru) [pscustomobject]@{ ImagePath = $ImagePath; Attached = $true } }
function Dismount-DiskImage { [CmdletBinding()] param($ImagePath) Write-Host "    [mock] dismount ISO $ImagePath" }
function Get-Volume { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) [pscustomobject]@{ DriveLetter = 'Q' } }
