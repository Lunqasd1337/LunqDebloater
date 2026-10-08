# Заглушки внутри модуля LunqDebloater для тестов. Тесты копируют этот файл в
# Modules\LunqDebloater\Private\ZZ.TestMocks.ps1 своей копии скрипта: он загружается последним
# и подменяет функции, которым нужна настоящая Windows, права администратора или внешние программы.

function Test-Administrator { return -not $env:LUNQ_TEST_NOT_ADMIN }

function Find-Oscdimg { param([string]$Path) return 'oscdimg.exe' }

function Get-LunqHostBuild {
    if ($env:LUNQ_TEST_HOST_BUILD) { return [int]$env:LUNQ_TEST_HOST_BUILD }
    return 26300
}

function Get-LunqDriveInfo {
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject]@{ Name = 'T:\'; DriveFormat = 'NTFS'; AvailableFreeSpace = [long]500GB }
}

function Select-IsoFile { return $env:LUNQ_TEST_ISO }

function Mount-IsoImage {
    # Подключённый ISO изображает папка с sources\install.esd.
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO не найден: $IsoPath" }
    $root = Join-Path $env:LUNQ_TEST_ROOT 'isoroot'
    New-Item -ItemType Directory -Path (Join-Path $root 'sources') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'sources\install.esd') -Value 'esd'
    return [pscustomobject]@{ IsoPath = $IsoPath; Root = $root; Owned = $true }
}

function Invoke-Native {
    # Внешние программы не запускаются. Вызов записывается в LUNQ_TEST_NATIVE_LOG, а там,
    # где скрипт потом ищет результат, создаются файлы-пустышки.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [switch]$ShowOutput)
    if ($env:LUNQ_TEST_NATIVE_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_NATIVE_LOG -Value ("{0}|{1}|{2}" -f $FilePath, ($Arguments -join '|'), (Get-Location).Path) -Encoding UTF8 }
    switch -Wildcard ($FilePath) {
        'robocopy.exe' {
            $destination = $Arguments[1]
            foreach ($file in 'sources\install.esd', 'sources\boot.wim', 'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin') {
                $path = Join-Path $destination $file
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value 'x'
            }
            return 1
        }
        'reg.exe' { if ($Arguments[0] -eq 'query') { return 1 }; return 0 }
        'dism.exe' { if ($env:LUNQ_TEST_DISM_EXIT) { return [int]$env:LUNQ_TEST_DISM_EXIT }; return 0 }
        '*oscdimg*' { Set-Content -LiteralPath $Arguments[-1] -Value ('i' * 2048); return 0 }
        default { return 0 }
    }
}

# Реестр образа: запись идёт в LUNQ_TEST_REG_LOG вместо настоящих кустов.
function Set-LunqRegistryValue {
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '', [Parameter(Mandatory)][string]$Kind, $Data)
    if ($env:LUNQ_TEST_REG_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_REG_LOG -Value ("set|{0}|{1}|{2}|{3}" -f $Key, $Name, $Kind, (@($Data) -join ',')) -Encoding UTF8 }
}
function Remove-LunqRegistryValue {
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '')
    if ($env:LUNQ_TEST_REG_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_REG_LOG -Value ("deletevalue|{0}|{1}" -f $Key, $Name) -Encoding UTF8 }
    return $true
}
function Remove-LunqRegistryKey {
    param([Parameter(Mandatory)][string]$Key)
    if ($env:LUNQ_TEST_REG_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_REG_LOG -Value ("deletekey|{0}" -f $Key) -Encoding UTF8 }
    return $false
}
