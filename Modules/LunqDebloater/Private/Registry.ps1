# Имена, под которыми офлайн-кусты подключаются в HKLM на время работы.
$script:HiveMap = [ordered]@{
    SOFTWARE    = @{ Key = 'HKLM\LUNQ_SOFTWARE'; File = 'Windows\System32\config\SOFTWARE' }
    SYSTEM      = @{ Key = 'HKLM\LUNQ_SYSTEM';   File = 'Windows\System32\config\SYSTEM' }
    DefaultUser = @{ Key = 'HKLM\LUNQ_NTUSER';   File = 'Users\Default\NTUSER.DAT' }
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

function ConvertTo-LunqRegValue {
    # Приводит значение из профиля к типу, который пишется в реестр. Возвращает Kind (имя
    # RegistryValueKind) и Data. Неверное значение даёт исключение с понятным текстом.
    param([Parameter(Mandatory)][string]$Type, $Value)

    # Число из JSON или строка "0x...". DWORD и QWORD записываются как беззнаковые: 4294967295 это 0xFFFFFFFF.
    $toNumber = {
        param($v, [int]$bits)
        $text = ([string]$v).Trim()
        if (-not $text) { throw 'нужно число' }
        if ($text -match '^0[xX]([0-9A-Fa-f]+)$') { $n = [Convert]::ToUInt64($Matches[1], 16) }
        elseif ($text -match '^-\d+$') {
            $signed = [long]$text
            if ($bits -eq 32) { return [int]$signed }
            return $signed
        }
        elseif ($text -match '^\d+$') { $n = [uint64]$text }
        else { throw "'$text' не число" }
        if ($bits -eq 32) {
            if ($n -gt [uint32]::MaxValue) { throw "$text не помещается в REG_DWORD" }
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
            if ($hex -notmatch '^([0-9A-Fa-f]{2})*$') { throw "'$Value' не hex-строка (пары цифр 0-9, A-F)" }
            $bytes = New-Object byte[] ($hex.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
            return @{ Kind = 'Binary'; Data = $bytes }
        }
        default { throw "неизвестный тип '$Type'. Допустимо: REG_SZ, REG_EXPAND_SZ, REG_MULTI_SZ, REG_DWORD, REG_QWORD, REG_BINARY" }
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
        default { throw "Неизвестный корень реестра: $root" }
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
    $action = [string](Get-ConfigValue $Entry 'Action')
    if (-not $action) { $action = 'Set' }
    if ($script:RegistryActions -notcontains $action) {
        return "неизвестное действие '$action'. Допустимо: $($script:RegistryActions -join ', ')"
    }
    if ($action -ne 'Set') { return $null }
    try { $null = ConvertTo-LunqRegValue -Type ([string](Get-ConfigValue $Entry 'Type')) -Value (Get-ConfigValue $Entry 'Value') }
    catch { return $_.Exception.Message }
    return $null
}

function Invoke-RegistryEntry {
    # Применяет одну запись профиля. Возвращает 'Applied', 'Skipped' или 'Failed'.
    param([Parameter(Mandatory)]$Entry)

    $key = '{0}\{1}' -f $script:HiveMap[[string]$Entry.Hive].Key, $Entry.Path
    # Без Name запись относится к значению «по умолчанию».
    $name = [string](Get-ConfigValue $Entry 'Name')
    $shownName = if ($name) { $name } else { '(по умолчанию)' }
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
            default { throw "неизвестное действие '$action'" }
        }
    }
    catch {
        Write-Warning "Не удалось применить $key\$shownName ($action): $($_.Exception.Message)"
        return 'Failed'
    }
}

function Set-LunqBuildStamp {
    # Записывает в образ HKLM\SOFTWARE\LunqDebloater: чем, когда и с какими настройками он собран.
    # Ошибка здесь не срывает сборку: это справочная информация.
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)]$Values)

    $key = "$($script:HiveMap.SOFTWARE.Key)\LunqDebloater"
    try {
        Mount-OfflineHives -MountPath $MountPath
        $failed = @()
        foreach ($name in $Values.Keys) {
            $data = [string]$Values[$name]
            if (-not $data) { $data = 'нет' }
            try { Set-LunqRegistryValue -Key $key -Name $name -Kind 'String' -Data $data }
            catch { $failed += $name }
        }
        if ($failed.Count -gt 0) { Write-Warning "Отметка о сборке записана не полностью: $($failed -join ', ')" }
        else { Write-Info 'Отметка о сборке записана в реестр образа: HKLM\SOFTWARE\LunqDebloater.' }
    }
    catch { Write-Warning "Не удалось записать отметку о сборке: $($_.Exception.Message)" }
    finally { Dismount-OfflineHives }
}

function Set-LunqRegistry {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Реестр' 'Registry'
    $entries = Get-ConfigList $Config 'Registry'
    if ($entries.Count -eq 0) { Write-Info 'Список твиков реестра в профиле пуст.'; return $result }

    try {
        # Внутри try: если не загрузится второй куст, первый всё равно выгрузится.
        Mount-OfflineHives -MountPath $MountPath
        foreach ($entry in $entries) {
            $status = Invoke-RegistryEntry -Entry $entry
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
        Write-Info ("Реестр: применено {0}, пропущено (уже нет) {1}, ошибок {2}." -f $result.Done.Count, $result.Skipped.Count, $result.Failed.Count)
        return $result
    }
    finally {
        Dismount-OfflineHives
    }
}
