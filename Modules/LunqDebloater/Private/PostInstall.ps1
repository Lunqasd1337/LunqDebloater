function Get-LunqFirstLogon {
    # Что выполнится при первом входе: программы из Apps.txt и скрипты *.ps1 из папки Scripts.
    # Если файла или папки нет, соответствующий список просто пуст.
    param([Parameter(Mandatory)][string]$AppsPath, [Parameter(Mandatory)][string]$ScriptsPath)
    $apps = @()
    if (Test-Path -LiteralPath $AppsPath -PathType Leaf) {
        $apps = @(Get-Content -LiteralPath $AppsPath -Encoding UTF8 | ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { ($_ -split '\s+')[0] })
    }
    $scripts = @()
    if (Test-Path -LiteralPath $ScriptsPath -PathType Container) {
        $scripts = @(Get-ChildItem -LiteralPath $ScriptsPath -Filter '*.ps1' -File | Where-Object { $_.Extension -eq '.ps1' } | Sort-Object Name)
    }
    return [pscustomobject]@{
        AppsPath    = $AppsPath
        Apps        = $apps
        ScriptsPath = $ScriptsPath
        Scripts     = $scripts
    }
}

function Format-FirstLogonSummary {
    # Одна короткая строка для плана и итога: длинный список программ в ней не нужен.
    param([Parameter(Mandatory)]$FirstLogon)
    $parts = @()
    if ($FirstLogon.Apps.Count -gt 0) { $parts += "программ: $($FirstLogon.Apps.Count) (winget)" }
    if ($FirstLogon.Scripts.Count -gt 0) { $parts += "скриптов: $($FirstLogon.Scripts.Count)" }
    return ($parts -join ', ')
}

# Команда первого входа: и в Sysprep\unattend.xml в образе, и в autounattend.xml в корне ISO.
$script:FirstLogonCommand = 'cmd.exe /c start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Lunq\FirstLogon.ps1"'

function ConvertTo-LunqUtf8Bom {
    # Windows PowerShell 5.1 читает скрипт без BOM в кодировке ANSI. Русские буквы в UTF-8 тогда
    # частично становятся кавычками (байты «Г», «Д» в 1251 это “ ”), и скрипт не разбирается вовсе.
    # Файл в UTF-8 без BOM пересохраняется с BOM. Возвращает $true, если файл изменён.
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return $false }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { return $false }
    # Только латиница: читается одинаково в любой кодировке.
    if (-not ($bytes | Where-Object { $_ -ge 0x80 } | Select-Object -First 1)) { return $false }
    try { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { return $false }   # не UTF-8, скорее всего уже ANSI: оставляем как есть
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
    return $true
}

function Install-LunqFirstLogon {
    # Кладёт в образ скрипт первого входа и unattend.xml, который запускает его через
    # FirstLogonCommands. SetupComplete.cmd не подходит: Windows не запускает его,
    # если в BIOS ноутбука зашит OEM-ключ, а это почти все ноутбуки с Home и Pro.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$FirstLogon,
        [Parameter(Mandatory)][string]$Architecture
    )

    $result = New-LunqResult 'После установки' 'FirstLogon'
    $unattend = Join-Path $MountPath 'Windows\System32\Sysprep\unattend.xml'
    if (Test-Path -LiteralPath $unattend) {
        throw 'В образе уже есть Windows\System32\Sysprep\unattend.xml, скрипт первого входа добавить нельзя.'
    }

    $target = Join-Path $MountPath 'Windows\Setup\Scripts\Lunq'
    $userTarget = Join-Path $target 'User'
    New-Item -ItemType Directory -Path $userTarget -Force | Out-Null
    if ($FirstLogon.Apps.Count -gt 0) {
        Copy-Item -LiteralPath $FirstLogon.AppsPath -Destination (Join-Path $userTarget 'Apps.txt') -Force
    }
    if ($FirstLogon.Scripts.Count -gt 0) {
        # Вместе со скриптами копируется всё, что лежит рядом с ними: скрипты могут этим пользоваться.
        $skip = @('.gitkeep', 'README.txt', 'README.md')
        foreach ($item in @(Get-ChildItem -LiteralPath $FirstLogon.ScriptsPath -Force | Where-Object { $skip -notcontains $_.Name })) {
            Copy-Item -LiteralPath $item.FullName -Destination $userTarget -Recurse -Force
        }
        $converted = @(Get-ChildItem -LiteralPath $userTarget -Recurse -File -Include '*.ps1', '*.psm1' |
                Where-Object { ConvertTo-LunqUtf8Bom -Path $_.FullName })
        if ($converted.Count -gt 0) {
            Write-Info ("Пересохранено в UTF-8 с BOM, чтобы русский текст работал в Windows PowerShell 5.1: {0}" -f (($converted | ForEach-Object { $_.Name }) -join ', '))
        }
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path $script:ModuleRoot -Parent) 'FirstLogon\FirstLogon.ps1') -Destination $target -Force

    $command = $script:FirstLogonCommand
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Created by LunqDebloater: runs the first logon setup script. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>$([Security.SecurityElement]::Escape($command))</CommandLine>
          <Description>LunqDebloater first logon</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
    New-Item -ItemType Directory -Path (Split-Path $unattend -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($unattend, $xml, (New-Object Text.UTF8Encoding($false)))

    foreach ($app in $FirstLogon.Apps) { $result.Done.Add($app) }
    $result.Summary = Format-FirstLogonSummary -FirstLogon $FirstLogon
    Write-Info ("Добавлено: {0}. Запустится при первом входе в Windows." -f $result.Summary)
    return $result
}
