# «Чистая копия этого компьютера»: программы и сети Wi-Fi этой Windows для собираемого образа.
# Драйверы этого компьютера выгружает Export-LunqHostDrivers (Servicing.ps1).

# Пакеты, которые winget export выдаёт вместе с программами, хотя это части Windows и среды
# выполнения: они ставятся сами вместе с теми программами, которым нужны.
$script:HostAppsSkip = @('Microsoft.AppInstaller', 'Microsoft.DesktopAppInstaller', 'Microsoft.UI.Xaml.*', 'Microsoft.VCLibs.*', 'Microsoft.WindowsAppRuntime.*', 'Microsoft.WindowsTerminal')

function ConvertFrom-LunqWingetExport {
    # Строки для Apps.txt из файла winget export: Id программы, у программ Microsoft Store
    # с --source msstore (иначе winget ищет Id только в своём каталоге).
    param([Parameter(Mandatory)][string]$Json)
    $data = $Json | ConvertFrom-Json
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($source in @(Get-ConfigValue $data 'Sources')) {
        if (-not $source) { continue }
        $sourceName = [string](Get-ConfigValue $source 'SourceDetails', 'Name')
        foreach ($package in @(Get-ConfigValue $source 'Packages')) {
            $id = [string](Get-ConfigValue $package 'PackageIdentifier')
            if (-not $id -or (Test-NamePattern -Name $id -Patterns $script:HostAppsSkip)) { continue }
            $line = $id
            if ($sourceName -eq 'msstore') { $line = "$id --source msstore" }
            if (-not ($lines | Where-Object { ($_ -split '\s+')[0] -eq $id })) { $lines.Add($line) }
        }
    }
    return , $lines.ToArray()
}

function Export-LunqHostApps {
    # Программы этого компьютера, которые знает winget. Возвращает строки для Apps.txt.
    param([Parameter(Mandatory)][string]$TempDir)
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $json = Join-Path $TempDir 'winget-export.json'
    Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue
    try {
        # Программы, которых нет ни в одном каталоге, winget пропускает с предупреждением и кодом
        # ошибки, поэтому результат проверяется по файлу, а не по коду.
        $null = Invoke-Native -FilePath 'winget.exe' -Arguments @('export', '--output', $json, '--accept-source-agreements', '--disable-interactivity') -SuccessCodes @(0, 1, -1978335212)
    }
    # Чаще всего winget просто не установлен или App Installer ещё не обновился.
    catch { throw (Get-LunqText 'Host.WingetFailed' $_.Exception.Message) }
    if (-not (Test-Path -LiteralPath $json -PathType Leaf)) { throw (Get-LunqText 'Host.AppsExportFailed') }
    try { return , (ConvertFrom-LunqWingetExport -Json (Get-Content -LiteralPath $json -Raw -Encoding UTF8)) }
    finally { Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue }
}

function Merge-LunqAppsList {
    # Apps.txt из Config плюс программы этого компьютера, которых в нём ещё нет. Пишется
    # в отдельный файл: Config\Apps.txt остаётся как был для следующих сборок.
    param([string]$AppsPath, [string[]]$Extra = @(), [Parameter(Mandatory)][string]$Destination)
    $lines = @()
    if ($AppsPath -and (Test-Path -LiteralPath $AppsPath -PathType Leaf)) { $lines = @(Get-Content -LiteralPath $AppsPath -Encoding UTF8) }
    $known = @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { ($_ -split '\s+')[0] })
    $added = @($Extra | Where-Object { $_ -and $known -notcontains ($_ -split '\s+')[0] })
    if ($added.Count -gt 0) { $lines += @('', (Get-LunqText 'Host.AppsComment')) + $added }
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    [IO.File]::WriteAllLines($Destination, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $Destination; Added = $added.Count }
}

function Export-LunqHostWifi {
    # Профили Wi-Fi этой Windows вместе с паролями открытым текстом (netsh wlan export key=clear).
    # Возвращает имена сетей. Нет Wi-Fi или служба WLAN выключена: пустой список.
    param([Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $code = Invoke-Native -FilePath 'netsh.exe' -Arguments @('wlan', 'export', 'profile', 'key=clear', "folder=$Destination")
    if ($code -ne 0) { return , @() }
    $names = foreach ($file in @(Get-ChildItem -LiteralPath $Destination -Filter '*.xml' -File | Where-Object { $_.Extension -eq '.xml' } | Sort-Object Name)) {
        $name = $file.BaseName
        try {
            # XmlDocument.Load сам узнаёт кодировку из файла: Get-Content в 5.1 без BOM читал бы
            # UTF-8 как ANSI и портил русские имена сетей.
            $xml = New-Object Xml.XmlDocument
            $xml.Load($file.FullName)
            if ($xml.WLANProfile.name) { $name = [string]$xml.WLANProfile.name }
        }
        catch { }   # файл не разобрать: остаётся имя файла
        $name
    }
    return , @($names)
}
