function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LunqVersion { return $script:LunqVersion }

function Start-LunqLog {
    # Начинает лог запуска в папке Logs и направляет туда же подробный лог DISM, чтобы
    # при ошибке была видна её настоящая причина. Хранятся логи последних $Keep запусков,
    # а логи DISM, которые намного больше, только последних $KeepDism.
    param([Parameter(Mandatory)][string]$Dir, [int]$Keep = 10, [int]$KeepDism = 3)

    try { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
    catch {
        # Например, скрипт запущен с носителя только для чтения.
        $Dir = Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater\Logs'
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $old = @(Get-ChildItem -LiteralPath $Dir -Filter 'LunqDebloater_*.log' -File |
            Where-Object { $_.Name -notlike '*_dism.log' } | Sort-Object Name -Descending | Select-Object -Skip ([Math]::Max($Keep - 1, 0)))
    foreach ($file in $old) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($file.FullName -replace '\.log$', '_dism.log') -Force -ErrorAction SilentlyContinue
    }
    $oldDism = @(Get-ChildItem -LiteralPath $Dir -Filter 'LunqDebloater_*_dism.log' -File |
            Sort-Object Name -Descending | Select-Object -Skip ([Math]::Max($KeepDism - 1, 0)))
    foreach ($file in $oldDism) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $log = [pscustomobject]@{
        Path     = Join-Path $Dir "LunqDebloater_$stamp.log"
        DismPath = Join-Path $Dir "LunqDebloater_${stamp}_dism.log"
    }
    Start-Transcript -Path $log.Path -Force | Out-Null
    # Командлеты DISM вызываются и из скрипта, и из модуля. У модуля своя переменная
    # PSDefaultParameterValues, глобальная на него не действует, поэтому путь задаётся в обеих
    # и убирается в Stop-LunqLog. Командлеты без параметра LogPath его просто не получают.
    foreach ($key in $script:DismLogKeys) {
        $global:PSDefaultParameterValues[$key] = $log.DismPath
        $script:PSDefaultParameterValues[$key] = $log.DismPath
    }
    # Тот же лог получает и dism.exe, который вызывается напрямую (Invoke-LunqDismExe).
    $script:DismLogPath = $log.DismPath
    return $log
}

$script:DismLogKeys = @('*-Windows*:LogPath', '*-AppxProvisionedPackage:LogPath')
$script:DismLogPath = $null

function Stop-LunqLog {
    foreach ($key in $script:DismLogKeys) {
        $global:PSDefaultParameterValues.Remove($key)
        $script:PSDefaultParameterValues.Remove($key)
    }
    $script:DismLogPath = $null
    # Транскрипта может не быть, если лог не удалось начать: тогда и останавливать нечего.
    try { Stop-Transcript | Out-Null } catch { }
}

function Write-LunqRunInfo {
    # Первые строки лога: версия, система и параметры запуска. По ним видно, в каких
    # условиях запускался скрипт, даже если ошибка случилась в самом начале.
    param($BoundParameters, [string]$DismLog)

    $lines = @()
    $lines += (Get-LunqText 'System.RunStart' (Get-LunqVersion) (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $system = Get-LunqText 'System.Unknown'
    try {
        $nt = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $product = [string]$nt.ProductName
        # В ProductName у Windows 11 по-прежнему написано «Windows 10».
        if ([int]$nt.CurrentBuild -ge 22000) { $product = $product -replace 'Windows 10', 'Windows 11' }
        $display = if ($nt.PSObject.Properties['DisplayVersion']) { " $($nt.DisplayVersion)" } else { '' }
        $system = '{0}{1} ({2}.{3})' -f $product, $display, $nt.CurrentBuild, $nt.UBR
    }
    catch { }   # версия системы нужна только для лога
    $lines += (Get-LunqText 'System.RunSystem' $system $PSVersionTable.PSVersion)
    $params = @()
    if ($BoundParameters) { $params = ConvertTo-LunqArgumentList -BoundParameters $BoundParameters }
    if ($params.Count -eq 0) { $params = @(Get-LunqText 'System.NoParameters') }
    $lines += (Get-LunqText 'System.RunParameters' ($params -join ' '))
    if ($DismLog) { $lines += (Get-LunqText 'System.DismLog' $DismLog) }
    # Приглушённым цветом: это нужно для разбора лога, а не для работы со скриптом.
    foreach ($line in $lines) { Write-Host "    $line" -ForegroundColor DarkGray }
}

function Get-LunqHostBuild {
    # Номер сборки Windows, на которой запущен скрипт, или 0, если его не удалось узнать.
    try { return [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild }
    catch { return 0 }
}

function ConvertTo-LunqArgumentList {
    # Превращает параметры запуска обратно в аргументы командной строки: для перезапуска
    # в Windows PowerShell 5.1, для перезапуска с правами администратора и для строки в логе.
    # -PathParameters: эти значения приводятся к полному пути, ведь новое окно открывается в System32.
    # -Quote: каждое значение берётся в кавычки, потому что Start-Process склеивает аргументы через пробел.
    param(
        [Parameter(Mandatory)]$BoundParameters,
        [string[]]$PathParameters = @(),
        [switch]$Quote
    )
    $arguments = @()
    foreach ($param in $BoundParameters.GetEnumerator()) {
        if ($param.Value -is [switch] -or $param.Value -is [bool]) {
            if ($param.Value) { $arguments += "-$($param.Key)" }
            continue
        }
        # Списки (-SkipCategory) передаются одной строкой через запятую, скрипт сам их делит.
        $value = @($param.Value) -join ','
        if ($value -and $PathParameters -contains $param.Key) {
            $value = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($value)
        }
        $arguments += "-$($param.Key)"
        if ($Quote) {
            # Обратная косая черта перед закрывающей кавычкой экранировала бы её, поэтому она удваивается.
            if ($value.EndsWith('\')) { $value += '\' }
            $value = '"{0}"' -f $value
        }
        $arguments += $value
    }
    return , $arguments
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
