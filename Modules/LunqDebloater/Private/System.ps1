function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LunqVersion { return $script:LunqVersion }

function Enter-LunqRunLock {
    # Два запуска сразу мешают друг другу: подготовка второго отключает образ первого, удаляет его
    # рабочую папку и выгружает его кусты реестра (их имена одни на все запуски). Глобальный мьютекс
    # виден из всех сеансов Windows. Возвращает мьютекс или $null, если другой запуск уже идёт.
    param([string]$Name = 'Global\LunqDebloater')
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    try { $acquired = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }   # прошлый запуск закрыли, не отпустив мьютекс
    if ($acquired) { return $mutex }
    $mutex.Dispose()
    return $null
}

function Exit-LunqRunLock {
    param($Lock)
    if (-not $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { }   # мьютекс уже отпущен: ничего страшного
    $Lock.Dispose()
}

function Start-LunqLog {
    # Начинает лог запуска в папке Logs и направляет туда же подробный лог DISM, чтобы
    # при ошибке была видна её настоящая причина. Хранятся логи последних $Keep запусков,
    # а логи DISM, которые намного больше, только последних $KeepDism. В конце запуска лог DISM
    # сжимается в _dism.zip (Compress-LunqDismLog), удаляются оба вида.
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
        Remove-Item -LiteralPath ($file.FullName -replace '\.log$', '_dism.zip') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($file.FullName -replace '\.log$', '_report.zip') -Force -ErrorAction SilentlyContinue
    }
    $oldDism = @(Get-ChildItem -LiteralPath $Dir -Filter 'LunqDebloater_*_dism.*' -File | Where-Object { $_.Extension -in '.log', '.zip' } |
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

function Compress-LunqDismLog {
    # Сжимает лог DISM в конце запуска: со сборкой обновлений он вырастает до сотен мегабайт, а
    # текст сжимается в десятки раз. Возвращает путь к тому, что осталось на диске: к архиву или,
    # если сжать не удалось, к самому логу.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $zip = $Path -replace '\.log$', '.zip'
    try {
        Compress-Archive -LiteralPath $Path -DestinationPath $zip -Force -ErrorAction Stop
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $zip
    }
    catch {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        return $Path
    }
}

function Write-LunqDismMarker {
    # Метка в логе DISM перед шагом сборки: лог большой, и по ней видно, где начинается нужный шаг.
    # Между шагами DISM файл не держит, но если запись не удалась, сборке это не мешает.
    param([Parameter(Mandatory)][string]$Text)
    if (-not $script:DismLogPath) { return }
    $line = '===== LunqDebloater {0}: {1} =====' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    try { Add-Content -LiteralPath $script:DismLogPath -Value @('', $line) -Encoding ASCII -ErrorAction Stop }
    catch { }
}

function Get-LunqPrivateNames {
    # Что заменить в отчёте об ошибке: путь к профилю, имя пользователя и имя компьютера.
    # Порядок важен: сначала путь целиком, затем имена отдельно.
    $names = [ordered]@{}
    if ($env:USERPROFILE) { $names[$env:USERPROFILE] = '%USERPROFILE%' }
    # Короткое имя могло бы совпасть с обычным словом, поэтому оно заменяется только целиком.
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) { $names[$env:USERNAME] = '<user>' }
    if ($env:COMPUTERNAME -and $env:COMPUTERNAME.Length -ge 3) { $names[$env:COMPUTERNAME] = '<computer>' }
    return $names
}

function Copy-LunqAnonymized {
    # Копирует текстовый файл построчно с заменами. Лог DISM бывает большим, поэтому целиком он
    # в память не читается. Лог DISM записан не в UTF-8 (кодировка ANSI), а копия пишется в UTF-8
    # с BOM: в ней бывают русские строки, которых нет в кодовой странице ANSI, например в английской Windows.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][Collections.IDictionary]$Replace,
        # Больше нуля: вместо всего файла записать строки с ошибками, предупреждениями и метками
        # шагов, а затем последние $KeepTail строк целиком. Так делается для большого лога DISM.
        [int]$KeepTail = 0
    )
    $patterns = @(foreach ($key in $Replace.Keys) {
            # Путь заменяется как есть, имена только целым словом: «User» не трогает «Users».
            $pattern = [regex]::Escape($key)
            if ($key -notmatch '[\\/]') { $pattern = '(?<![\w-])' + $pattern + '(?![\w-])' }
            [pscustomobject]@{ Regex = New-Object regex($pattern, 'IgnoreCase'); Value = ([string]$Replace[$key]).Replace('$', '$$') }
        })
    $hide = {
        param([string]$Text)
        foreach ($p in $patterns) { $Text = $p.Regex.Replace($Text, $p.Value) }
        $Text
    }
    $reader = New-Object IO.StreamReader($Source, [Text.Encoding]::Default, $true)
    try {
        $writer = New-Object IO.StreamWriter($Destination, $false, (New-Object Text.UTF8Encoding($true)))
        try {
            if ($KeepTail -le 0) {
                while ($null -ne ($line = $reader.ReadLine())) { $writer.WriteLine((& $hide $line)) }
            }
            else {
                # В логе DISM миллионы строк, поэтому замены делаются только в тех, что попадут в отчёт.
                $tail = New-Object 'System.Collections.Generic.Queue[string]'
                $important = New-Object regex('^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d, (Error|Warning)\b|^===== LunqDebloater ')
                $writer.WriteLine((Get-LunqText 'System.ReportShortened'))
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($important.IsMatch($line)) { $writer.WriteLine((& $hide $line)) }
                    $tail.Enqueue($line)
                    if ($tail.Count -gt $KeepTail) { $null = $tail.Dequeue() }
                }
                $writer.WriteLine('')
                $writer.WriteLine((Get-LunqText 'System.ReportTail' $tail.Count))
                foreach ($line in $tail) { $writer.WriteLine((& $hide $line)) }
            }
        }
        finally { $writer.Dispose() }
    }
    finally { $reader.Dispose() }
}

function New-LunqBugReport {
    # Архив для отчёта об ошибке рядом с логом: лог запуска, лог DISM и профиль. Путь к профилю
    # пользователя и имена заменены, чтобы их не приходилось вычищать вручную перед отправкой.
    # Лог DISM больше $MaxDismBytes сокращается: иначе архив не пролезет в issue на GitHub.
    # Вызывается после Stop-LunqLog: пока идёт транскрипт, лог ещё не дописан.
    param(
        [Parameter(Mandatory)]$Log,
        [string]$ProfilePath,
        [Collections.IDictionary]$Replace = (Get-LunqPrivateNames),
        [long]$MaxDismBytes = 20MB,
        [int]$DismTail = 20000
    )
    $files = @(@($Log.Path, $Log.DismPath, $ProfilePath) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($files.Count -eq 0) { return $null }
    $zip = $Log.Path -replace '\.log$', '_report.zip'
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('LunqDebloater-report-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        foreach ($file in $files) {
            $keepTail = 0
            if ($file -eq $Log.DismPath -and (Get-Item -LiteralPath $file).Length -gt $MaxDismBytes) { $keepTail = $DismTail }
            Copy-LunqAnonymized -Source $file -Destination (Join-Path $temp (Split-Path $file -Leaf)) -Replace $Replace -KeepTail $keepTail
        }
        Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zip -Force
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    return $zip
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
    # -SuccessCodes: коды выхода, которые для этой программы значат успех (robocopy возвращает 1-7).
    # При другом коде скрытый вывод программы попадает в лог: без него по коду не понять причину.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$ShowOutput,
        [int[]]$SuccessCodes = @(0)
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @()
        if ($ShowOutput) { & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host "    $_" } }
        else { $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }) }
        $code = $LASTEXITCODE
        $lines = @($output | Where-Object { $_.Trim() } | Select-Object -Last 30)
        if ($SuccessCodes -notcontains $code -and $lines.Count -gt 0) {
            Write-Host ('    ' + (Get-LunqText 'System.NativeOutput' (Split-Path $FilePath -Leaf) $code)) -ForegroundColor DarkGray
            foreach ($line in $lines) { Write-Host "      $line" -ForegroundColor DarkGray }
        }
        return $code
    }
    finally { $ErrorActionPreference = $old }
}
