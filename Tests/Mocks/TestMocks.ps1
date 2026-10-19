# Заглушки внутри модуля LunqDebloater для тестов. Тесты копируют этот файл в
# Modules\LunqDebloater\Private\ZZ.TestMocks.ps1 своей копии скрипта: он загружается последним
# и подменяет функции, которым нужна настоящая Windows, права администратора или внешние программы.

function Test-Administrator { return -not $env:LUNQ_TEST_NOT_ADMIN }

function Find-Oscdimg { [CmdletBinding()] param([string]$Path) return 'oscdimg.exe' }

function Get-LunqHostBuild {
    if ($env:LUNQ_TEST_HOST_BUILD) { return [int]$env:LUNQ_TEST_HOST_BUILD }
    return 26300
}

function Get-LunqDriveInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # LUNQ_TEST_NETWORK_DRIVE: рабочая папка на подключённом сетевом диске.
    $type = if ($env:LUNQ_TEST_NETWORK_DRIVE) { 'Network' } else { 'Fixed' }
    return [pscustomobject]@{ Name = 'T:\'; DriveType = $type; DriveFormat = 'NTFS'; AvailableFreeSpace = [long]500GB }
}

function Select-IsoFile { return $env:LUNQ_TEST_ISO }

# Копии для заданий по расписанию: вместо Program Files папка теста.
function Get-LunqScheduleRoot { return (Join-Path $env:LUNQ_TEST_ROOT 'ProgramFiles\LunqDebloater-Schedule') }

# Окно выбора папки: папку задаёт тест, пустое значение означает «Отмена».
function Select-LunqFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Description)
    Write-Host "    [mock] folder dialog: $Description"
    if ($env:LUNQ_TEST_FOLDER) { return $env:LUNQ_TEST_FOLDER }
    return $null
}

function Mount-IsoImage {
    # Подключённый ISO изображает папка с sources\install.esd, а с LUNQ_TEST_ISO_WIM с install.wim.
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
    $root = Join-Path $env:LUNQ_TEST_ROOT 'isoroot'
    New-Item -ItemType Directory -Path (Join-Path $root 'sources') -Force | Out-Null
    if ($env:LUNQ_TEST_ISO_WIM) { Set-Content -LiteralPath (Join-Path $root 'sources\install.wim') -Value 'wim' }
    else { Set-Content -LiteralPath (Join-Path $root 'sources\install.esd') -Value 'esd' }
    return [pscustomobject]@{ IsoPath = $IsoPath; Root = $root; Owned = $true }
}

function Invoke-Native {
    # Внешние программы не запускаются. Вызов записывается в LUNQ_TEST_NATIVE_LOG, а там,
    # где скрипт потом ищет результат, создаются файлы-пустышки.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @(), [switch]$ShowOutput, [int[]]$SuccessCodes = @(0))
    if ($env:LUNQ_TEST_NATIVE_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_NATIVE_LOG -Value ("{0}|{1}|{2}" -f $FilePath, ($Arguments -join '|'), (Get-Location).Path) -Encoding UTF8 }
    switch -Wildcard ($FilePath) {
        'robocopy.exe' {
            $destination = $Arguments[1]
            # Как robocopy с /XF: исключённые файлы не копируются.
            $files = @('sources\install.esd', 'sources\boot.wim', 'sources\setup.exe', 'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin', 'efi\boot\bootx64.efi', 'bootmgr.efi')
            $skip = @()
            $xf = [array]::IndexOf($Arguments, '/XF')
            if ($xf -ge 0) { for ($i = $xf + 1; $i -lt $Arguments.Count -and -not $Arguments[$i].StartsWith('/'); $i++) { $skip += $Arguments[$i] } }
            foreach ($file in @($files | Where-Object { $skip -notcontains ($_ -replace '^.*\\', '') })) {
                $path = Join-Path $destination $file
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value 'x'
            }
            return 1
        }
        'expand.exe' {
            # Проверка вида .cab распаковывает только .mum: что в нём, задаёт текст файла-пустышки.
            if ($Arguments[1] -eq '-F:*.mum') {
                $text = Get-Content -LiteralPath $Arguments[0] -Raw
                if ($text -match 'safeos') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'update.mum') -Value '<assemblyIdentity name="Package_for_SafeOSDU" />' }
                elseif ($text -match 'rollup') { Set-Content -LiteralPath (Join-Path $Arguments[2] 'update.mum') -Value '<assemblyIdentity name="Package_for_RollupFix" />' }
            }
            return 0
        }
        'reg.exe' {
            if ($Arguments[0] -eq 'query') { return 1 }
            # Выгрузка ключа перед DeleteKey: текст .reg, как у настоящего reg export.
            if ($Arguments[0] -eq 'export') { [IO.File]::WriteAllText($Arguments[2], "Windows Registry Editor Version 5.00`r`n`r`n[$($Arguments[1])]`r`n", [Text.Encoding]::Unicode) }
            return 0
        }
        'winget.exe' {
            # winget export: две программы из каталога winget, одна из Microsoft Store и библиотека, которую скрипт отбрасывает.
            $json = '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Git.Git"},{"PackageIdentifier":"7zip.7zip"},{"PackageIdentifier":"Microsoft.VCLibs.Desktop.14"}]},{"SourceDetails":{"Name":"msstore"},"Packages":[{"PackageIdentifier":"9NKSQGP7F2NH"}]}]}'
            if ($Arguments[0] -eq 'export') { [IO.File]::WriteAllText($Arguments[2], $json) }
            return 0
        }
        'netsh.exe' {
            # netsh wlan export profile key=clear folder=...: одна сеть, если тест не убрал Wi-Fi.
            if ($env:LUNQ_TEST_NO_WIFI) { return 1 }
            $folder = ($Arguments | Where-Object { $_ -like 'folder=*' }) -replace '^folder=', ''
            Set-Content -LiteralPath (Join-Path $folder 'Wi-Fi-Home.xml') -Value '<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1"><name>Home</name></WLANProfile>'
            return 0
        }
        'schtasks.exe' { if ($Arguments[0] -eq '/Delete' -and $env:LUNQ_TEST_NO_TASK) { return 1 }; return 0 }
        'dism.exe' {
            # Накопительные обновления одним вызовом: какие .msu лежат в папке рядом с целевым.
            $package = @($Arguments | Where-Object { $_ -like '/PackagePath:*' }) -replace '^/PackagePath:', ''
            if ($package) {
                $folder = @(Get-ChildItem -LiteralPath (Split-Path $package -Parent) -File | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '
                Write-Host "    [mock] dism add package $(Split-Path $package -Leaf) from folder: $folder"
                if ((Split-Path $package -Leaf) -match 'broken') { return 1 }
                return 0
            }
            if ($env:LUNQ_TEST_DISM_EXIT) { return [int]$env:LUNQ_TEST_DISM_EXIT }
            return 0
        }
        '*oscdimg*' { Set-Content -LiteralPath $Arguments[-1] -Value ('i' * 2048); return 0 }
        default { return 0 }
    }
}

# Реестр образа: запись идёт в LUNQ_TEST_REG_LOG вместо настоящих кустов.
function Set-LunqRegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '', [Parameter(Mandatory)][string]$Kind, $Data)
    if ($env:LUNQ_TEST_REG_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_REG_LOG -Value ("set|{0}|{1}|{2}|{3}" -f $Key, $Name, $Kind, (@($Data) -join ',')) -Encoding UTF8 }
}
function Remove-LunqRegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '')
    if ($env:LUNQ_TEST_REG_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_REG_LOG -Value ("deletevalue|{0}|{1}" -f $Key, $Name) -Encoding UTF8 }
    return $true
}
function Remove-LunqRegistryKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    if ($env:LUNQ_TEST_REG_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_REG_LOG -Value ("deletekey|{0}" -f $Key) -Encoding UTF8 }
    return $false
}

# Значения реестра до записи профиля: их нет, поэтому откат удалит записанное.
function Get-LunqRegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '')
    return $null
}
function Test-LunqRegistryKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    return $true
}

# Файл отката этой Windows лежит в папке теста, а не в C:\Windows.
function Get-LunqRestorePath { return (Join-Path $env:LUNQ_TEST_ROOT 'Windows\LunqDebloater\Restore.json') }

# Приложения, установленные у пользователей этой Windows (для -Online).
function Get-LunqInstalledAppx {
    return @([pscustomobject]@{ Name = 'Microsoft.BingNews'; PackageFullName = 'Microsoft.BingNews_4.1.0.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Microsoft.BingNews_8wekyb3d8bbwe' })
}
function Remove-LunqInstalledAppx {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)
    Write-Host "    [mock] remove installed $($Package.PackageFullName)"
}
# Вернуть приложение по имени семейства: файлов на диске нет, если тест так решил.
function Add-LunqAppxBack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageFamilyName)
    if ($env:LUNQ_TEST_APPX_GONE) { throw 'package files not found' }
    Write-Host "    [mock] register $PackageFamilyName"
}

# Подпись Microsoft: у файлов-пустышек её нет, поэтому неподписанным считается только файл со словом unsigned.
function Get-LunqSignatureError {
    param([Parameter(Mandatory)][string]$Path)
    if ((Get-Content -LiteralPath $Path -Raw) -match 'unsigned') { return 'NotSigned' }
    return $null
}

# Каталог Центра обновления: страницы поиска и окна скачивания строятся здесь же по запросу,
# а скачанный файл содержит текст, контрольная сумма которого стоит в окне скачивания.
function Invoke-LunqWebRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'Get', $Body, [string]$OutFile)
    if ($env:LUNQ_TEST_NATIVE_LOG) { Add-Content -LiteralPath $env:LUNQ_TEST_NATIVE_LOG -Value "web|$Method|$Uri" -Encoding UTF8 }
    if ($env:LUNQ_TEST_OFFLINE) { throw 'The remote name could not be resolved' }
    $kbs = [ordered]@{ Cumulative = '5090000'; Framework = '5090001'; SafeOS = '5090002'; Setup = '5090003' }
    if ($OutFile) {
        [IO.File]::WriteAllText($OutFile, ('update ' + [IO.Path]::GetFileName(([uri]$Uri).AbsolutePath)))
        return
    }
    if ($Uri -like '*Search.aspx*') {
        $q = [uri]::UnescapeDataString(($Uri -split 'q=')[1])
        $rows = @()
        if ($q -like '*.NET*') { $rows += , @('2', "2026-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB$($kbs.Framework))", '10/14/2026') }
        elseif ($q -like '*Safe OS*') { $rows += , @('3', "2026-10 Safe OS Dynamic Update for Windows 11, version 26H2 for x64-based Systems (KB$($kbs.SafeOS))", '10/14/2026') }
        elseif ($q -like '*Setup Dynamic*') { $rows += , @('4', "2026-10 Setup Dynamic Update for Windows 11, version 26H2 for x64-based Systems (KB$($kbs.Setup))", '10/14/2026') }
        else {
            # Предварительное обновление новее, но скрипт его не берёт.
            $rows += , @('5', '2026-10 Cumulative Update Preview for Windows 11, version 26H2 for x64-based Systems (KB5090099) (26300.7100)', '10/28/2026')
            $rows += , @('1', "2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB$($kbs.Cumulative)) (26300.7000)", '10/14/2026')
            $rows += , @('6', '2026-09 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5080000) (26300.6000)', '9/9/2026')
        }
        $html = '<table id="ctl00_catalogBody_updateMatches"><tr id="headerRow"><td>x</td></tr>'
        foreach ($r in $rows) {
            $id = '00000000-0000-0000-0000-00000000000{0}' -f $r[0]
            $html += '<tr id="{0}_R1"><td></td><td><a>{1}</a></td><td>Windows 11</td><td>Updates</td><td>{2}</td><td>n/a</td><td><span>1 MB</span><span id="x_originalSize" style="display:none">1000</span></td><td><input id="{0}" class="flatBlueButtonDownload" type="button" value="Download" /></td></tr>' -f $id, $r[1], $r[2]
        }
        return ($html + '</table>')
    }
    if ($Uri -like '*DownloadDialog.aspx*') {
        $id = [regex]::Match([string]$Body.updateIDs, '"updateID":"([^"]+)"').Groups[1].Value
        $kb = @($kbs.Values)[[int]$id.Substring($id.Length - 1) - 1]
        $ext = if ($kb -in $kbs.SafeOS, $kbs.Setup) { 'cab' } else { 'msu' }
        $name = if ($kb -eq $kbs.Framework) { "windows11.0-kb$kb-x64-ndp481.$ext" } else { "windows11.0-kb$kb-x64.$ext" }
        $sha1 = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("update $name"))
        if ($env:LUNQ_TEST_BAD_HASH) { $sha1 = [byte[]](1..20) }
        return ("downloadInformation[0].files[0].url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/x/public/$name';`r`ndownloadInformation[0].files[0].digest = '{0}';" -f [Convert]::ToBase64String($sha1))
    }
    throw "unexpected request: $Uri"
}
