# Заглушка модуля DISM (и командлетов Storage для ISO) для тестов. Тесты кладут папку Mocks
# первой в PSModulePath, и Import-Module Dism в LunqDebloater.ps1 загружает этот модуль.
# Ничего не монтирует: пишет в вывод, что было бы сделано, и создаёт файлы-пустышки там,
# где их потом ищет скрипт. Поведение настраивается переменными окружения LUNQ_TEST_*.

function Get-WindowsImage {
    param($ImagePath, $Index, [switch]$Mounted, $LogPath, $ErrorAction)
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
    param($ImagePath, $Index, $Path, [switch]$ReadOnly, $LogPath)
    Write-Host "    [mock] mount $ImagePath index $Index -> $Path"
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($ImagePath -like '*install.wim') {
        $winre = Join-Path $Path 'Windows\System32\Recovery\Winre.wim'
        New-Item -ItemType Directory -Path (Split-Path $winre) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $winre)) { Set-Content -LiteralPath $winre -Value ('r' * 500) }
    }
    if ($ImagePath -like '*boot.wim') {
        # Установщик внутри boot.wim: его setup.exe и setuphost.exe копируются в sources ISO.
        New-Item -ItemType Directory -Path (Join-Path $Path 'sources') -Force | Out-Null
        foreach ($name in 'setup.exe', 'setuphost.exe') { Set-Content -LiteralPath (Join-Path $Path "sources\$name") -Value 'from boot.wim' }
    }
}

function Dismount-WindowsImage { param($Path, [switch]$Save, [switch]$Discard, $LogPath, $ErrorAction) Write-Host "    [mock] dismount $Path save=$Save discard=$Discard" }

function Export-WindowsImage {
    param($SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, [switch]$CheckIntegrity, [switch]$SetBootable, $LogPath)
    Write-Host "    [mock] export $SourceImagePath index $SourceIndex"
    Add-Content -LiteralPath $DestinationImagePath -Value 'wim'
}

function Get-AppxProvisionedPackage {
    param($Path, $LogPath)
    if ($env:LUNQ_TEST_FAIL_APPX) { throw 'DISM failure to test the rollback' }
    @(
        [pscustomobject]@{ DisplayName = 'Microsoft.BingNews'; PackageName = 'Microsoft.BingNews_1.0_x64' },
        [pscustomobject]@{ DisplayName = 'Microsoft.WindowsCalculator'; PackageName = 'Microsoft.WindowsCalculator_1.0_x64' }
    )
}
function Remove-AppxProvisionedPackage { param($Path, $PackageName, $LogPath, $ErrorAction) }

function Get-WindowsCapability {
    param($Path, $LogPath)
    @(
        [pscustomobject]@{ Name = 'Browser.InternetExplorer~~~~0.0.11.0'; State = 'Installed' },
        [pscustomobject]@{ Name = 'Language.Basic~~~ru-RU~0.0.1.0'; State = 'Installed' }
    )
}
function Remove-WindowsCapability { param($Path, $Name, $LogPath, $ErrorAction) }

function Get-WindowsOptionalFeature {
    param($Path, $LogPath)
    @(
        [pscustomobject]@{ FeatureName = 'Recall'; State = 'Enabled' },
        [pscustomobject]@{ FeatureName = 'Microsoft-Hyper-V-All'; State = 'Disabled' }
    )
}
function Disable-WindowsOptionalFeature { param($Path, $FeatureName, [switch]$NoRestart, [switch]$Remove, $LogPath, $ErrorAction) }

function Get-WindowsPackage { param($Path, $LogPath) @() }
function Remove-WindowsPackage { param($Path, $PackageName, [switch]$NoRestart, $LogPath, $ErrorAction) }

function Add-WindowsPackage {
    param($Path, $PackagePath, $ScratchDirectory, [switch]$NoRestart, $LogPath, $ErrorAction)
    Write-Host "    [mock] add package $(Split-Path $PackagePath -Leaf)"
    if ($PackagePath -match 'broken') { throw 'The package does not apply to this image' }
}

function Add-WindowsDriver {
    param($Path, $Driver, $LogPath, $ErrorAction)
    Write-Host "    [mock] add driver $(Split-Path $Driver -Leaf)"
    if ($Driver -match 'bad') { throw 'The driver does not fit this image' }
}

function Repair-WindowsImage { param($Path, [switch]$StartComponentCleanup, [switch]$ResetBase, $LogPath) throw 'Repair-WindowsImage must not be called: cleanup goes through dism.exe' }

function Get-DiskImage { param($ImagePath, $ErrorAction) [pscustomobject]@{ ImagePath = $ImagePath; Attached = [bool]$env:LUNQ_TEST_ISO_ATTACHED } }
function Mount-DiskImage { param($ImagePath, [switch]$PassThru) [pscustomobject]@{ ImagePath = $ImagePath; Attached = $true } }
function Dismount-DiskImage { param($ImagePath) Write-Host "    [mock] dismount ISO $ImagePath" }
function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject, $ErrorAction) [pscustomobject]@{ DriveLetter = 'Q' } }
