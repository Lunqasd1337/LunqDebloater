# Имена, под которыми офлайн-кусты подключаются в HKLM на время работы.
$script:HiveMap = [ordered]@{
    SOFTWARE    = @{ Key = 'HKLM\LUNQ_SOFTWARE'; File = 'Windows\System32\config\SOFTWARE' }
    SYSTEM      = @{ Key = 'HKLM\LUNQ_SYSTEM';   File = 'Windows\System32\config\SYSTEM' }
    DefaultUser = @{ Key = 'HKLM\LUNQ_NTUSER';   File = 'Users\Default\NTUSER.DAT' }
}

function Mount-OfflineHives {
    # -Hives: имена из HiveMap, по умолчанию все. Каждый куст загружается и выгружается секунды,
    # поэтому лишние не трогаются.
    param([Parameter(Mandatory)][string]$MountPath, [string[]]$Hives = @($script:HiveMap.Keys))

    foreach ($name in $Hives) {
        $hive = $script:HiveMap[$name]
        $file = Join-Path $MountPath $hive.File
        if ((Invoke-Native reg.exe @('load', $hive.Key, $file)) -ne 0) {
            throw (Get-LunqText 'Registry.HiveLoadFailed' $file)
        }
    }
}

function Dismount-OfflineHives {
    # Выгружает кусты; повторяет попытку, если какой-то процесс ещё держит дескриптор.
    # -Strict: куст, который так и не выгрузился, останавливает сборку. С подключённым кустом
    # DISM не сохранит и не отключит образ, и сборка потерялась бы на шаге сохранения.
    # Без -Strict только предупреждение: так вызывается при разборе уже случившейся ошибки.
    param([switch]$Strict)
    # Антивирус или индексатор может держать куст десятки секунд. С -Strict на кону вся сборка,
    # поэтому ожидание дольше: паузы растут до 10 секунд, всего около полутора минут на куст.
    $attempts = 5
    if ($Strict) { $attempts = 12 }
    $stuck = @()
    foreach ($hive in $script:HiveMap.Values) {
        # Код 1 значит, что куст не подключён: выгружать нечего.
        if ((Invoke-Native reg.exe @('query', $hive.Key) -SuccessCodes 0, 1) -ne 0) { continue }

        $unloaded = $false
        for ($attempt = 1; $attempt -le $attempts -and -not $unloaded; $attempt++) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $unloaded = ((Invoke-Native reg.exe @('unload', $hive.Key)) -eq 0)
            if (-not $unloaded -and $attempt -lt $attempts) { Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 10)) }
        }
        if (-not $unloaded) {
            Write-Warning (Get-LunqText 'Registry.HiveUnloadFailed' $hive.Key)
            $stuck += $hive.Key
        }
    }
    if ($Strict -and $stuck.Count -gt 0) { throw (Get-LunqText 'Registry.HivesStillLoaded' ($stuck -join ', ')) }
}

function ConvertTo-LunqRegValue {
    # Приводит значение из профиля к типу, который пишется в реестр. Возвращает Kind (имя
    # RegistryValueKind) и Data. Неверное значение даёт исключение с понятным текстом.
    # Пустой Type пропускается сюда, чтобы ошибка была понятной, а не ошибкой привязки параметра.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Type, $Value)

    if (-not $Type) { throw (Get-LunqText 'Registry.NoType') }

    # Число из JSON или строка "0x...". DWORD и QWORD записываются как беззнаковые: 4294967295 это 0xFFFFFFFF.
    $toNumber = {
        param($v, [int]$bits)
        $text = ([string]$v).Trim()
        if (-not $text) { throw (Get-LunqText 'Registry.NeedNumber') }
        if ($text -match '^0[xX]([0-9A-Fa-f]+)$') { $n = [Convert]::ToUInt64($Matches[1], 16) }
        elseif ($text -match '^-\d+$') {
            $signed = [long]$text
            if ($bits -eq 32) { return [int]$signed }
            return $signed
        }
        elseif ($text -match '^\d+$') { $n = [uint64]$text }
        else { throw (Get-LunqText 'Registry.NotNumber' $text) }
        if ($bits -eq 32) {
            if ($n -gt [uint32]::MaxValue) { throw (Get-LunqText 'Registry.DwordOverflow' $text) }
            return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$n), 0)
        }
        return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$n), 0)
    }

    switch ($Type) {
        'REG_SZ'        { return @{ Kind = 'String'; Data = [string]$Value } }
        'REG_EXPAND_SZ' { return @{ Kind = 'ExpandString'; Data = [string]$Value } }
        'REG_MULTI_SZ'  { return @{ Kind = 'MultiString'; Data = [string[]]@($Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) } }
        'REG_DWORD'     { return @{ Kind = 'DWord'; Data = (& $toNumber $Value 32) } }
        'REG_QWORD'     { return @{ Kind = 'QWord'; Data = (& $toNumber $Value 64) } }
        'REG_BINARY' {
            $hex = [string]$Value -replace '[\s,]', ''
            if ($hex -notmatch '^([0-9A-Fa-f]{2})*$') { throw (Get-LunqText 'Registry.NotHex' ([string]$Value)) }
            $bytes = New-Object byte[] ($hex.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
            return @{ Kind = 'Binary'; Data = $bytes }
        }
        default { throw (Get-LunqText 'Registry.UnknownType' $Type) }
    }
}

# Запись в реестр идёт через .NET, а не через reg.exe: Windows PowerShell 5.1 искажает
# аргументы внешних программ с кавычками и с \ в конце, а значение вида "C:\app.exe" /min
# в профиле вполне обычное. reg.exe остаётся только для загрузки и выгрузки кустов.

function Open-LunqRegistryKey {
    # Открывает ключ по пути вида HKLM\LUNQ_SOFTWARE\Policies\... Возвращает $null, если ключа нет.
    # Корень HKCU нужен тестам, которые пишут во временный ключ.
    param([Parameter(Mandatory)][string]$Path, [switch]$Create, [switch]$Writable)
    $root, $subKey = $Path -split '\\', 2
    $base = switch ($root) {
        'HKLM' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKCU' { [Microsoft.Win32.Registry]::CurrentUser }
        default { throw (Get-LunqText 'Registry.UnknownRoot' $root) }
    }
    if ($Create) { return $base.CreateSubKey($subKey) }
    return $base.OpenSubKey($subKey, [bool]$Writable)
}

function Set-LunqRegistryValue {
    # Создаёт ключ, если его нет, и записывает значение. Пустое Name означает значение «по умолчанию».
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '', [Parameter(Mandatory)][string]$Kind, $Data)
    $handle = Open-LunqRegistryKey -Path $Key -Create
    # Ключ закрывается сразу: открытый дескриптор не дал бы выгрузить куст.
    try { $handle.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind) }
    finally { $handle.Dispose() }
}

function Remove-LunqRegistryValue {
    # Удаляет значение. Возвращает $false, если удалять нечего.
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '')
    $handle = Open-LunqRegistryKey -Path $Key -Writable
    if (-not $handle) { return $false }
    try {
        if (@($handle.GetValueNames()) -notcontains $Name) { return $false }
        $handle.DeleteValue($Name)
        return $true
    }
    finally { $handle.Dispose() }
}

function Remove-LunqRegistryKey {
    # Удаляет ключ со всеми подключами. Возвращает $false, если ключа нет.
    param([Parameter(Mandatory)][string]$Key)
    $existing = Open-LunqRegistryKey -Path $Key
    if (-not $existing) { return $false }
    $existing.Dispose()
    $parentPath = $Key.Substring(0, $Key.LastIndexOf('\'))
    $leaf = $Key.Substring($Key.LastIndexOf('\') + 1)
    $parent = Open-LunqRegistryKey -Path $parentPath -Writable
    try { $parent.DeleteSubKeyTree($leaf) }
    finally { $parent.Dispose() }
    return $true
}

$script:RegistryActions = 'Set', 'DeleteValue', 'DeleteKey'

function Test-LunqRegistryEntry {
    # Проверяет запись профиля ещё при чтении, а не через полчаса сборки. Возвращает текст проблемы или $null.
    param([Parameter(Mandatory)]$Entry)
    # Ключ с HKLM\ в начале или CurrentControlSet в офлайн-кусте записался бы, но никогда бы не сработал.
    $path = [string](Get-ConfigValue $Entry 'Path')
    if ($path -match '^(?i)(HKLM|HKCU|HKU|HKCR|HKCC|HKEY_[A-Z_]+)(\\|:|$)') { return (Get-LunqText 'Registry.PathHasHive' $Matches[1]) }
    # Ключ «X\» или «X/Y» записался бы не туда, а DeleteKey для «X\» получил бы пустое имя подключа.
    if ($path -match '/|\\\\|^\\|\\$') { return (Get-LunqText 'Registry.PathMalformed') }
    if ([string](Get-ConfigValue $Entry 'Hive') -eq 'SYSTEM' -and $path -match '^(?i)CurrentControlSet(\\|$)') { return (Get-LunqText 'Registry.PathCurrentControlSet') }
    $action = [string](Get-ConfigValue $Entry 'Action')
    if (-not $action) { $action = 'Set' }
    if ($script:RegistryActions -notcontains $action) {
        return (Get-LunqText 'Registry.UnknownActionAllowed' $action ($script:RegistryActions -join ', '))
    }
    if ($action -ne 'Set') { return $null }
    try { $null = ConvertTo-LunqRegValue -Type ([string](Get-ConfigValue $Entry 'Type')) -Value (Get-ConfigValue $Entry 'Value') }
    catch { return $_.Exception.Message }
    return $null
}

function Get-LunqRegistryRoots {
    # Куда пишется запись профиля. В образе кусты подключены под своими именами (HiveMap). На этой
    # Windows (-Online) SOFTWARE и SYSTEM открыты и так, а DefaultUser это профиль Default (новые
    # пользователи, он подключается как в образе) и текущий пользователь. CurrentUser встречается
    # только в данных для отката: то, что было у текущего пользователя до -Online.
    param([Parameter(Mandatory)][string]$Hive, [switch]$Online)
    if (-not $Online) { return , @($script:HiveMap[$Hive].Key) }
    switch ($Hive) {
        'SOFTWARE' { return , @('HKLM\SOFTWARE') }
        'SYSTEM' { return , @('HKLM\SYSTEM') }
        'DefaultUser' { return , @($script:HiveMap.DefaultUser.Key, 'HKCU') }
        'CurrentUser' { return , @('HKCU') }
    }
    throw (Get-LunqText 'Registry.UnknownRoot' $Hive)
}

function Get-LunqRegistryValue {
    # Текущее значение в виде записи профиля (Type и Value) или $null, если значения нет.
    # Так его можно записать обратно той же функцией, что и запись профиля.
    param([Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Name = '')
    $handle = Open-LunqRegistryKey -Path $Key
    if (-not $handle) { return $null }
    try {
        if (@($handle.GetValueNames()) -notcontains $Name) { return $null }
        $kind = [string]$handle.GetValueKind($Name)
        # Переменные в REG_EXPAND_SZ не раскрываются: значение возвращается как записано.
        $data = $handle.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally { $handle.Dispose() }
    switch ($kind) {
        'String' { return @{ Type = 'REG_SZ'; Value = [string]$data } }
        'ExpandString' { return @{ Type = 'REG_EXPAND_SZ'; Value = [string]$data } }
        'MultiString' { return @{ Type = 'REG_MULTI_SZ'; Value = @($data) } }
        # Число записывается без знака: так его прочитает ConvertTo-LunqRegValue.
        'DWord' { return @{ Type = 'REG_DWORD'; Value = [string][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$data), 0) } }
        'QWord' { return @{ Type = 'REG_QWORD'; Value = [string][BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$data), 0) } }
        'Binary' { return @{ Type = 'REG_BINARY'; Value = (@($data | ForEach-Object { '{0:x2}' -f $_ }) -join ' ') } }
    }
    # Тип, которого нет в профиле (например, REG_NONE): вернуть его скрипт не сможет.
    return @{ Type = $kind; Value = $null; Unsupported = $true }
}

function Test-LunqRegistryKey {
    param([Parameter(Mandatory)][string]$Key)
    $handle = Open-LunqRegistryKey -Path $Key
    if (-not $handle) { return $false }
    $handle.Dispose()
    return $true
}

function Export-LunqRegistryKey {
    # Ключ целиком в виде текста .reg (reg export): так его можно вернуть после DeleteKey.
    # Возвращает текст или $null, если выгрузить не удалось.
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$TempDir)
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $file = Join-Path $TempDir ('{0}.reg' -f [guid]::NewGuid().ToString('N'))
    try {
        if ((Invoke-Native reg.exe @('export', $Key, $file, '/y')) -ne 0 -or -not (Test-Path -LiteralPath $file)) { return $null }
        # reg export пишет в UTF-16 с меткой BOM, Get-Content распознаёт её сам.
        return (Get-Content -LiteralPath $file -Raw)
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Save-LunqRegistryOriginal {
    # Запоминает, что было в реестре до записи профиля: значение (или его отсутствие), а для
    # DeleteKey весь ключ. Записывает это в данные для отката под категорией записи.
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Hive)
    $category = [string](Get-ConfigValue $Entry 'LunqCategory')
    $action = [string](Get-ConfigValue $Entry 'Action')
    if (-not $action) { $action = 'Set' }
    if ($action -eq 'DeleteKey') {
        if (-not (Test-LunqRegistryKey -Key $Key)) { return }
        $export = Export-LunqRegistryKey -Key $Key -TempDir (Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater\RegExport')
        if ($null -eq $export) { Write-Warning (Get-LunqText 'Registry.ExportFailed' $Key); return }
        Add-LunqRestoreRegistryKey -Restore $Restore -Category $category -Hive $Hive -Path ([string]$Entry.Path) -Export $export
        return
    }
    $name = [string](Get-ConfigValue $Entry 'Name')
    $old = Get-LunqRegistryValue -Key $Key -Name $name
    $backup = [ordered]@{ Hive = $Hive; Path = [string]$Entry.Path }
    if ($name) { $backup.Name = $name }
    if ($null -eq $old) { $backup.Action = 'DeleteValue' }
    elseif (Get-ConfigValue ([pscustomobject]$old) 'Unsupported') { Write-Warning (Get-LunqText 'Registry.BackupUnsupported' $Key $old.Type); return }
    else { $backup.Type = $old.Type; $backup.Value = $old.Value }
    Add-LunqRestoreRegistry -Restore $Restore -Category $category -Entry ([pscustomobject]$backup)
}

function Invoke-RegistryEntry {
    # Применяет одну запись профиля. Возвращает 'Applied', 'Skipped' или 'Failed'.
    # -Root: ключ, под которым лежит путь записи; по умолчанию куст образа из HiveMap.
    param([Parameter(Mandatory)]$Entry, [string]$Root)

    if (-not $Root) { $Root = $script:HiveMap[[string]$Entry.Hive].Key }
    $key = '{0}\{1}' -f $Root, $Entry.Path
    # Без Name запись относится к значению «по умолчанию».
    $name = [string](Get-ConfigValue $Entry 'Name')
    $shownName = if ($name) { $name } else { Get-LunqText 'Registry.DefaultValueName' }
    $action = [string](Get-ConfigValue $Entry 'Action')
    if (-not $action) { $action = 'Set' }

    try {
        switch ($action) {
            'Set' {
                $value = ConvertTo-LunqRegValue -Type ([string](Get-ConfigValue $Entry 'Type')) -Value (Get-ConfigValue $Entry 'Value')
                Set-LunqRegistryValue -Key $key -Name $name -Kind $value.Kind -Data $value.Data
                return 'Applied'
            }
            'DeleteValue' { if (Remove-LunqRegistryValue -Key $key -Name $name) { return 'Applied' } else { return 'Skipped' } }
            'DeleteKey' { if (Remove-LunqRegistryKey -Key $key) { return 'Applied' } else { return 'Skipped' } }
            default { throw (Get-LunqText 'Registry.UnknownAction' $action) }
        }
    }
    catch {
        Write-Warning (Get-LunqText 'Registry.ApplyFailed' $key $shownName $action $_.Exception.Message)
        return 'Failed'
    }
}

function Set-LunqBuildStamp {
    # Записывает в образ HKLM\SOFTWARE\LunqDebloater: чем, когда и с какими настройками он собран.
    # Ошибка здесь не срывает сборку: это справочная информация.
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)]$Values)

    $key = "$($script:HiveMap.SOFTWARE.Key)\LunqDebloater"
    try {
        Mount-OfflineHives -MountPath $MountPath -Hives SOFTWARE
        $failed = @()
        foreach ($name in $Values.Keys) {
            $data = [string]$Values[$name]
            if (-not $data) { $data = Get-LunqText 'Registry.StampNone' }
            try { Set-LunqRegistryValue -Key $key -Name $name -Kind 'String' -Data $data }
            catch { $failed += $name }
        }
        if ($failed.Count -gt 0) { Write-Warning (Get-LunqText 'Registry.StampPartial' ($failed -join ', ')) }
        else { Write-Info (Get-LunqText 'Registry.StampWritten') }
    }
    catch { Write-Warning (Get-LunqText 'Registry.StampFailed' $_.Exception.Message) }
    finally { Dismount-OfflineHives -Strict }
}

function Set-LunqRegistry {
    # Записи профиля в реестр образа или, с -Online, этой Windows. -Restore: перед записью
    # запомнить, что было, чтобы потом вернуть.
    param(
        [string]$MountPath,
        [switch]$Online,
        [Parameter(Mandatory)]$Config,
        $Restore
    )

    $result = New-LunqResult (Get-LunqText 'Registry.Title') 'Registry'
    $entries = Get-ConfigList $Config 'Registry'
    if ($entries.Count -eq 0) { Write-Info (Get-LunqText 'Registry.ListEmpty'); return $result }

    # Если шаг уже упал, невыгруженный куст только предупреждает: иначе его исключение заменило бы
    # настоящую причину ошибки. Образ после ошибки всё равно отключается без сохранения.
    $completed = $false
    try {
        # Внутри try: если не загрузится второй куст, первый всё равно выгрузится. На этой Windows
        # подключается только профиль Default: SOFTWARE и SYSTEM и так открыты.
        if ($Online) { Mount-OfflineHives -MountPath (Get-LunqSystemDrive) -Hives DefaultUser }
        else { Mount-OfflineHives -MountPath $MountPath }
        foreach ($entry in $entries) {
            $hive = [string]$entry.Hive
            $statuses = foreach ($root in (Get-LunqRegistryRoots -Hive $hive -Online:$Online)) {
                if ($Restore) {
                    # Текущий пользователь отличается от профиля Default, поэтому его прежнее значение отдельное.
                    $backupHive = if ($root -eq 'HKCU') { 'CurrentUser' } else { $hive }
                    $key = '{0}\{1}' -f $root, $entry.Path
                    try { Save-LunqRegistryOriginal -Restore $Restore -Entry $entry -Key $key -Hive $backupHive }
                    catch { Write-Warning (Get-LunqText 'Registry.BackupFailed' $key $_.Exception.Message) }
                }
                Invoke-RegistryEntry -Entry $entry -Root $root
            }
            # Запись в два места (профиль Default и текущий пользователь) считается одной: важен худший итог.
            $status = 'Skipped'
            if (@($statuses) -contains 'Failed') { $status = 'Failed' }
            elseif (@($statuses) -contains 'Applied') { $status = 'Applied' }
            $label = '{0}\{1}' -f $entry.Hive, $entry.Path
            if ($entry.PSObject.Properties['Name'] -and $entry.Name) { $label = "$label\$($entry.Name)" }
            switch ($status) {
                'Applied' { $result.Done.Add($label) }
                'Skipped' { $result.Skipped.Add($label) }
                default { $result.Failed.Add($label) }
            }
            $category = Get-ConfigValue $entry 'LunqCategory'
            if ($category) {
                if (-not $result.ByCategory.ContainsKey($category)) { $result.ByCategory[$category] = @{ Applied = 0; Skipped = 0; Failed = 0 } }
                $result.ByCategory[$category][$status]++
            }
        }
        Write-Info (Get-LunqText 'Registry.Summary' $result.Done.Count $result.Skipped.Count $result.Failed.Count)
        $completed = $true
        return $result
    }
    finally {
        Dismount-OfflineHives -Strict:$completed
    }
}

function Get-LunqSystemDrive {
    # Корень системного диска этой Windows: от него берётся профиль Default (Users\Default\NTUSER.DAT).
    return ($env:SystemDrive.TrimEnd('\') + '\')
}
