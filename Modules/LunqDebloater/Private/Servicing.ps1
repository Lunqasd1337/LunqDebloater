# Имя файла обновления Windows (windows11.0-kb...), а не, например, Office. Обновления .NET
# называются так же, только с ndp в имени, их отсекают отдельно.
$script:WindowsUpdatePattern = '(?i)^windows1[01]\.0-kb'

function Test-LunqEnablementUpdate {
    # Пакеты включения (enablement) переключают версию Windows и ставятся только поверх нужного
    # накопительного обновления. Имя у них такое же, как у накопительных, поэтому их узнают по номеру
    # KB из Data\Releases.psd1.
    param([Parameter(Mandatory)][string]$Name)
    $numbers = @($script:LunqReleases | ForEach-Object { [string]$_.Enablement } | Where-Object { $_ })
    return $Name -match '(?i)kb(\d+)' -and $numbers -contains $Matches[1]
}

function Get-LunqUpdateFiles {
    # Находит .msu и .cab в папке и упорядочивает их, как в инструкции Microsoft по обновлению
    # образа: сначала пакеты без номера KB (языковые пакеты и компоненты по запросу), потом
    # обновления Windows, за ними пакеты включения, последними обновления .NET. Языковой пакет,
    # поставленный после накопительного обновления, остаётся в исходной версии, а пакет включения
    # без накопительного не ставится. Внутри группы порядок по номеру KB:
    # более старые (например, контрольные накопительные обновления) устанавливаются раньше.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return , @() }
    return , (Get-LunqSortedUpdates @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in '.msu', '.cab' }))
}

function Get-LunqSortedUpdates {
    # Порядок установки из Get-LunqUpdateFiles: и для одной папки, и для обновлений из Config вместе со скачанными.
    param($Files)
    # Списки из Get-LunqUpdateFiles приходят одним объектом: ForEach-Object раскрывает их.
    $files = @($Files | ForEach-Object { $_ } | Where-Object { $_ })
    $sorted = $files | Sort-Object @{ Expression = {
            if ($_.Name -notmatch '(?i)kb\d+') { 0 } elseif ($_.Name -match '(?i)ndp') { 3 } elseif (Test-LunqEnablementUpdate $_.Name) { 2 } else { 1 }
        }
    }, @{ Expression = {
            if ($_.Name -match '(?i)kb(\d+)') { [long]$Matches[1] } else { [long]0 }
        }
    }, Name
    return , @($sorted)
}

function Get-LunqCabKind {
    # Что за .cab лежит рядом с обычными обновлениями, если папку выбрали целиком (например,
    # «Загрузки») и подпапок SafeOS и Setup в ней нет. Обновления Windows Каталог отдаёт в .msu,
    # а .cab с номером KB обычно оказывается Dynamic Update:
    #   Setup: файлы установщика (setupprep.exe, setuphost.exe), пакета DISM (.mum) в нём нет;
    #   SafeOS: пакет Package_for_SafeOSDU, он ставится только в WinRE.
    # Возвращает 'Setup', 'SafeOS', 'Update' (пакет DISM или не архив CAB) или 'Unknown': архив
    # без пакета и без файлов установщика, например драйвер. Такой нельзя распаковывать в sources.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$TempDir)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $magic = New-Object byte[] 4
        $read = $stream.Read($magic, 0, 4)
    }
    finally { $stream.Dispose() }
    if ($read -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -ne 'MSCF') { return 'Update' }

    $dir = Join-Path $TempDir ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        # Распаковываются только манифесты пакета, остальное содержимое не нужно.
        $code = Invoke-Native expand.exe @($Path, '-F:*.mum', $dir)
        if ($code -ne 0) { return 'Update' }
        $manifests = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.mum')
        if ($manifests.Count -eq 0) {
            $code = Invoke-Native expand.exe @($Path, '-F:setup*.exe', $dir)
            if ($code -ne 0) { return 'Unknown' }
            $setupFiles = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { @('setupprep.exe', 'setuphost.exe') -contains $_.Name.ToLowerInvariant() })
            if ($setupFiles.Count -gt 0) { return 'Setup' }
            return 'Unknown'
        }
        foreach ($manifest in $manifests) {
            if (Select-String -LiteralPath $manifest.FullName -Pattern 'Package_for_SafeOSDU' -SimpleMatch -Quiet) { return 'SafeOS' }
        }
        return 'Update'
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Split-LunqDynamicUpdates {
    # Делит обновления из одной папки на обычные, Safe OS и Setup Dynamic Update.
    # Проверяются только .cab. Cache (путь, размер и время файла) избавляет от повторной
    # распаковки, когда сводка показывается снова.
    param($Files, [Parameter(Mandatory)][string]$TempDir, [hashtable]$Cache = @{})
    $result = [pscustomobject]@{ Updates = @(); SafeOS = @(); Setup = @(); Unknown = @() }
    foreach ($file in @($Files)) {
        $kind = 'Update'
        if ($file.Extension -eq '.cab') {
            $key = '{0}|{1}|{2}' -f $file.FullName, $file.Length, $file.LastWriteTimeUtc.Ticks
            if (-not $Cache.ContainsKey($key)) {
                # Большой .cab проверяется несколько секунд, без строки это выглядело бы как зависание.
                Write-Info (Get-LunqText 'Servicing.CheckingCab' $file.Name)
                $Cache[$key] = Get-LunqCabKind -Path $file.FullName -TempDir $TempDir
                # Один раз, при проверке: сводка показывается заново после каждого действия.
                if ($Cache[$key] -eq 'Unknown') { Write-Warning (Get-LunqText 'Servicing.UnknownCab' $file.Name) }
            }
            $kind = $Cache[$key]
        }
        switch ($kind) {
            'SafeOS' { $result.SafeOS += $file }
            'Setup' { $result.Setup += $file }
            'Unknown' { $result.Unknown += $file }
            default { $result.Updates += $file }
        }
    }
    return $result
}

function Test-CumulativeUpdate {
    # Похоже ли хотя бы одно обновление на накопительное для самой Windows (а не, например, для .NET).
    param($Files)
    return (Select-LunqPEUpdates $Files).Count -gt 0
}

function Write-UpdateList {
    param([Parameter(Mandatory)]$Files)
    foreach ($file in $Files) {
        Write-Info ("  {0} ({1})" -f $file.Name, (Format-Size $file.Length))
    }
}

function Test-LunqNotApplicable {
    # DISM отвечает 0x800f081e (CBS_E_NOT_APPLICABLE), когда пакет предназначен для другого образа.
    # Это не сбой: например, Safe OS Dynamic Update подходит только к WinRE.
    param([Parameter(Mandatory)]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    return ('{0:x8}' -f $exception.HResult) -eq '800f081e' -or $exception.Message -match '(?i)0x800f081e'
}

function Add-LunqUpdates {
    # Встраивает обновления в смонтированный образ. Временные файлы DISM кладёт
    # в рабочую папку, а не в %TEMP%, чтобы не забить системный диск.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Files,
        [Parameter(Mandatory)][string]$ScratchDir,
        [string]$Title = (Get-LunqText 'Servicing.UpdatesTitle'),
        [string]$Kind = 'Updates'
    )

    $result = New-LunqResult $Title $Kind
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null
    # Несколько накопительных обновлений Windows в .msu (в 24H2 это контрольное KB5043080 и
    # целевое) ставятся одним вызовом DISM, как велит Microsoft: целевое из папки, где кроме него
    # только предыдущие накопительные. Контрольное обновление отдельно падает с ошибкой
    # «An error occurred applying the Unattend.xml file from the .msu package».
    # Пакет включения DISM из такой папки не берёт, поэтому он ставится отдельно, после неё.
    $cumulative = @(@($Files) | Where-Object { $_.Extension -eq '.msu' -and $_.Name -match $script:WindowsUpdatePattern -and $_.Name -notmatch '(?i)ndp' -and -not (Test-LunqEnablementUpdate $_.Name) } |
            Sort-Object @{ Expression = { if ($_.Name -match '(?i)kb(\d+)') { [long]$Matches[1] } else { [long]0 } } }, Name)
    $target = $null
    if ($cumulative.Count -gt 1) { $target = $cumulative[-1] }
    $i = 0
    foreach ($file in $Files) {
        $i++
        if ($target -and $file.FullName -ne $target.FullName -and @($cumulative | Where-Object { $_.FullName -eq $file.FullName }).Count -gt 0) {
            Write-Info (Get-LunqText 'Servicing.CumulativeWith' $i $Files.Count $file.Name $target.Name)
            continue
        }
        Write-Info (Get-LunqText 'Servicing.Installing' $i $Files.Count $file.Name (Format-Size $file.Length))
        if ($target -and $file.FullName -eq $target.FullName) {
            $code = Add-LunqCumulativeUpdates -MountPath $MountPath -Files $cumulative -ScratchDir $ScratchDir
            $names = @($cumulative | ForEach-Object { $_.Name })
            if ($code -eq 0 -or $code -eq 3010) { foreach ($name in $names) { $result.Done.Add($name) } }
            elseif ($code -eq -2146498530) {
                # 0x800f081e: обновление не для этого образа, как в Test-LunqNotApplicable.
                Write-Info (Get-LunqText 'Servicing.UpdateNotApplicable' $file.Name)
                foreach ($name in $names) { $result.Skipped.Add($name) }
            }
            else {
                Write-Warning (Get-LunqText 'Servicing.CumulativeFailed' $file.Name ('0x{0:x8}' -f $code))
                foreach ($name in $names) { $result.Failed.Add($name) }
            }
            continue
        }
        try {
            # Свои предупреждения командлет повторяет в тексте ошибки, поэтому они не выводятся дважды.
            Add-WindowsPackage -Path $MountPath -PackagePath $file.FullName -ScratchDirectory $ScratchDir -NoRestart -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            $result.Done.Add($file.Name)
        }
        catch {
            if (Test-LunqNotApplicable $_) {
                Write-Info (Get-LunqText 'Servicing.UpdateNotApplicable' $file.Name)
                $result.Skipped.Add($file.Name)
            }
            else {
                Write-Warning (Get-LunqText 'Servicing.UpdateFailed' $file.Name $_.Exception.Message)
                $result.Failed.Add($file.Name)
            }
        }
    }
    # Dynamic Update из Каталога выглядит как обычное обновление (.cab с номером KB), но ставится
    # не в сам образ: Safe OS только в WinRE, Setup распаковывается в установщик.
    if ($Kind -eq 'Updates' -and @($result.Skipped | Where-Object { $_ -match '(?i)\.cab$' }).Count -gt 0) {
        Write-Info (Get-LunqText 'Servicing.DynamicUpdateHint')
    }
    return $result
}

function Add-LunqCumulativeUpdates {
    # Целевое накопительное обновление (последнее по номеру KB) вместе с предыдущими: DISM находит
    # контрольные обновления в папке целевого и ставит их по порядку. Папка своя, в рабочей папке,
    # потому что других .msu (.NET, языковых пакетов) в ней быть не должно. Файлы в неё не
    # копируются, а связываются жёсткими ссылками, если та же файловая система. Возвращает код dism.exe.
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$ScratchDir)
    $folder = Join-Path (Split-Path $ScratchDir -Parent) 'cumulative'
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    try {
        foreach ($file in @($Files)) {
            $copy = Join-Path $folder $file.Name
            try { New-Item -ItemType HardLink -Path $copy -Target $file.FullName -ErrorAction Stop | Out-Null }
            catch { Copy-Item -LiteralPath $file.FullName -Destination $copy -Force }
        }
        # Через dism.exe, как в инструкции Microsoft: с Add-WindowsPackage контрольные обновления
        # из папки подхватываются не всегда.
        $target = Join-Path $folder (@($Files)[-1]).Name
        $arguments = @("/Image:$MountPath", '/Add-Package', "/PackagePath:$target", "/ScratchDir:$ScratchDir", '/NoRestart')
        if ($script:DismLogPath) { $arguments += "/LogPath:$($script:DismLogPath)" }
        return (Invoke-Native dism.exe $arguments -SuccessCodes @(0, 3010))
    }
    finally { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-LunqDriverFiles {
    # Все .inf в папке и подпапках: так драйверы обычно лежат после распаковки.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return , @() }
    # -Filter в Windows находит и *.inf_loc (из-за коротких имён 8.3), поэтому расширение проверяется явно.
    # autorun.inf к драйверам не относится, хотя часто лежит рядом с ними.
    return , @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.inf' |
            Where-Object { $_.Extension -eq '.inf' -and $_.Name -ne 'autorun.inf' } |
            Sort-Object FullName)
}

function Export-LunqHostDrivers {
    # Выгружает сторонние драйверы этой Windows (то же, что pnputil /export-driver) в пустую папку.
    # Удобно, когда ISO собирают для этого же компьютера: драйверы не нужно искать у производителя.
    param([Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Export-WindowsDriver -Online -Destination $Destination | Out-Null
    return , @(Get-LunqDriverFiles -Path $Destination)
}

function Get-FolderSize {
    # -Cache (путь): сводка показывается заново после каждого действия, а в драйверах этого
    # компьютера тысячи файлов. Кто меняет папку, убирает её из кэша.
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Cache)
    if ($null -ne $Cache -and $Cache.ContainsKey($Path)) { return $Cache[$Path] }
    $sum = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)) { $sum += $f.Length }
    if ($null -ne $Cache) { $Cache[$Path] = $sum }
    return $sum
}

function Add-LunqDrivers {
    # Добавляет драйверы по одному .inf, чтобы один неподходящий драйвер не срывал остальные.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$InfFiles,
        [Parameter(Mandatory)][string]$Root,
        [string]$Title = (Get-LunqText 'Servicing.DriversTitle'),
        [string]$Kind = 'Drivers'
    )

    $result = New-LunqResult $Title $Kind
    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
    $i = 0
    foreach ($inf in $InfFiles) {
        $i++
        $relative = $inf.FullName
        if ($relative.StartsWith($rootFull)) { $relative = $relative.Substring($rootFull.Length).TrimStart('\', '/') }
        Write-Info ("[{0}/{1}] {2}" -f $i, $InfFiles.Count, $relative)
        try {
            Add-WindowsDriver -Path $MountPath -Driver $inf.FullName -ErrorAction Stop | Out-Null
            $result.Done.Add($relative)
        }
        catch {
            Write-Warning (Get-LunqText 'Servicing.DriverFailed' $relative $_.Exception.Message)
            $result.Failed.Add($relative)
        }
    }
    return $result
}

function Select-LunqPEDrivers {
    # Для установщика и WinRE отбираются только драйверы контроллеров дисков (классы SCSIAdapter
    # и HDC): ради них драйверы туда и добавляют. Все драйверы сразу сильно раздули бы boot.wim,
    # а он при загрузке с флешки целиком распаковывается в память.
    # -Cache (путь, размер и время файла): ответы по уже прочитанным .inf. Сводка показывается
    # заново после каждого действия, и без кэша сотни .inf драйверов этого компьютера читались бы
    # целиком каждый раз.
    param($InfFiles, [hashtable]$Cache = @{})
    $diskClasses = @('SCSIAdapter', 'HDC')
    $selected = foreach ($inf in @($InfFiles)) {
        $key = '{0}|{1}|{2}' -f $inf.FullName, $inf.Length, $inf.LastWriteTimeUtc.Ticks
        if (-not $Cache.ContainsKey($key)) {
            # Get-Content сам распознаёт .inf в UTF-16 по метке BOM.
            $text = Get-Content -LiteralPath $inf.FullName -Raw -ErrorAction SilentlyContinue
            $Cache[$key] = [bool]($text -and $text -match '(?im)^\s*Class\s*=\s*"?([A-Za-z0-9_]+)' -and $diskClasses -contains $Matches[1])
        }
        if ($Cache[$key]) { $inf }
    }
    return , @($selected)
}

function Select-LunqPEUpdates {
    # Для установщика и WinRE подходят только обновления самой Windows (windows11.0-kb...),
    # обновления .NET (ndp) в Windows PE не ставятся.
    param($Files)
    return , @(@($Files) | Where-Object { $_.Name -match $script:WindowsUpdatePattern -and $_.Name -notmatch '(?i)ndp' })
}

function Update-LunqPEImage {
    # Встраивает обновления и драйверы в образ на базе Windows PE: boot.wim или winre.wim.
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$ScratchDir,
        [Parameter(Mandatory)][string]$Where,
        [Parameter(Mandatory)][string]$KindSuffix,
        $Updates = @(),
        $SafeOS = @(),
        $Drivers = @(),
        [string]$DriversRoot,
        [string]$ExportSetupTo,
        [string]$BootFilesTo
    )

    $results = @()
    New-Item -ItemType Directory -Path $MountPath -Force | Out-Null
    $saved = $false
    try {
        # Монтирование внутри try: образ, смонтированный наполовину, тоже отбрасывается.
        Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath | Out-Null
        $updated = 0
        if (@($Updates).Count -gt 0) {
            $r = Add-LunqUpdates -MountPath $MountPath -Files $Updates -ScratchDir $ScratchDir -Title (Get-LunqText 'Servicing.UpdatesIn' $Where) -Kind "Updates$KindSuffix"
            $updated = $r.Done.Count
            $results += $r
        }
        # Safe OS Dynamic Update ставится после накопительного обновления, как в инструкции Microsoft.
        if (@($SafeOS).Count -gt 0) {
            $r = Add-LunqUpdates -MountPath $MountPath -Files $SafeOS -ScratchDir $ScratchDir -Title (Get-LunqText 'Servicing.SafeOSIn' $Where) -Kind "UpdatesSafeOS$KindSuffix"
            $updated += $r.Done.Count
            $results += $r
        }
        if (@($Drivers).Count -gt 0) {
            $results += Add-LunqDrivers -MountPath $MountPath -InfFiles $Drivers -Root $DriversRoot -Title (Get-LunqText 'Servicing.DriversIn' $Where) -Kind "Drivers$KindSuffix"
        }
        if ($updated -gt 0) {
            Write-Info (Get-LunqText 'Servicing.Cleanup')
            $null = Invoke-LunqComponentCleanup -MountPath $MountPath -ScratchDir $ScratchDir
        }
        # setup.exe и загрузчик меняются только обновлениями. После одних драйверов или неудачного
        # обновления в boot.wim лежат старые версии, и setup.exe затёр бы новый из Setup Dynamic Update.
        if ($ExportSetupTo -and $updated -gt 0) { $results += Copy-LunqSetupFiles -MountPath $MountPath -Destination $ExportSetupTo }
        if ($BootFilesTo -and $updated -gt 0) { $results += Copy-LunqBootManager -MountPath $MountPath -IsoRoot $BootFilesTo }
        Dismount-WindowsImage -Path $MountPath -Save | Out-Null
        $saved = $true
    }
    finally {
        # Не catch, а finally: при Ctrl+C catch не выполняется, и образ остался бы смонтированным.
        if (-not $saved) {
            try { Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop | Out-Null }
            catch { Write-Verbose $_.Exception.Message }
        }
    }
    return $results
}

function Copy-LunqSetupFiles {
    # setup.exe и setuphost.exe в sources ISO должны совпадать с теми, что внутри boot.wim,
    # иначе установка может не запуститься. Главными считаются версии из boot.wim.
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)][string]$Destination)

    $result = New-LunqResult (Get-LunqText 'Servicing.SetupFilesTitle') 'SetupFiles'
    foreach ($name in 'setup.exe', 'setuphost.exe') {
        $source = Join-Path $MountPath "sources\$name"
        if (-not (Test-Path -LiteralPath $source)) { continue }   # setuphost.exe есть только в сборках 26100 и новее
        try {
            Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $name) -Force -ErrorAction Stop
            $result.Done.Add($name)
        }
        catch {
            Write-Warning (Get-LunqText 'Servicing.SetupFileFailed' $name $_.Exception.Message)
            $result.Failed.Add($name)
        }
    }
    if ($result.Done.Count -gt 0 -and $result.Failed.Count -eq 0) { $result.Summary = Get-LunqText 'Servicing.SetupFilesDone' ($result.Done -join ', ') }
    return $result
}

function Copy-LunqBootManager {
    # Загрузчик UEFI на ISO берётся из обновлённого boot.wim, как в инструкции Microsoft по
    # обновлению носителя: иначе на ISO остаётся загрузчик RTM, который Secure Boot может отозвать
    # (CVE-2023-24932). efisys.bin, из которого oscdimg делает загрузочный образ UEFI, меняется
    # вместе с bootx64.efi: иначе ISO, подключённый напрямую, грузился бы старым загрузчиком, а
    # флешка из него новым. Заменяются только файлы, которые на ISO уже есть.
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)][string]$IsoRoot)

    $pairs = @(
        @('Windows\Boot\EFI\bootmgfw.efi', 'efi\boot\bootx64.efi'),
        @('Windows\Boot\EFI\bootmgfw.efi', 'efi\boot\bootaa64.efi'),
        @('Windows\Boot\EFI\bootmgr.efi', 'bootmgr.efi'),
        @('Windows\Boot\DVD\EFI\en-US\efisys.bin', 'efi\microsoft\boot\efisys.bin'),
        @('Windows\Boot\DVD\EFI\en-US\efisys_noprompt.bin', 'efi\microsoft\boot\efisys_noprompt.bin')
    )
    $result = New-LunqResult (Get-LunqText 'Servicing.BootFilesTitle') 'BootFiles'
    foreach ($pair in $pairs) {
        $source = Join-Path $MountPath $pair[0]
        $target = Join-Path $IsoRoot $pair[1]
        if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $target)) { continue }
        try {
            Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
            $result.Done.Add($pair[1])
        }
        catch {
            Write-Warning (Get-LunqText 'Servicing.BootFileFailed' $pair[1] $_.Exception.Message)
            $result.Failed.Add($pair[1])
        }
    }
    if ($result.Done.Count + $result.Failed.Count -eq 0) { return }
    if ($result.Failed.Count -eq 0) { $result.Summary = Get-LunqText 'Servicing.BootFilesDone' ($result.Done -join ', ') }
    return $result
}

function Export-LunqBootCA2023 {
    # Загрузчик, подписанный Windows UEFI CA 2023 (файлы _EX), берётся из install.wim, пока он
    # смонтирован после обновлений: в полном образе эти папки есть, и в нём самое свежее
    # накопительное обновление. На ISO файлы кладёт шаг Iso, потому что шаг Setup ещё заменит
    # загрузчик версией из boot.wim. Возвращает $true, если всё нужное нашлось.
    param([Parameter(Mandatory)][string]$MountPath, [Parameter(Mandatory)][string]$Destination)

    $boot = Join-Path $MountPath 'Windows\Boot'
    $required = 'EFI_EX\bootmgfw_EX.efi', 'EFI_EX\bootmgr_EX.efi', 'DVD_EX\EFI\en-US\efisys_EX.bin'
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $boot $_)) })
    if ($missing.Count -gt 0) {
        Write-Warning (Get-LunqText 'Servicing.BootCA2023Missing' ($missing -join ', '))
        return $false
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($folder in 'EFI_EX', 'DVD_EX', 'Fonts_EX') {
        $source = Join-Path $boot $folder
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $Destination $folder) -Recurse -Force }
    }
    return $true
}

function Install-LunqBootCA2023 {
    # Кладёт на ISO загрузчик Windows UEFI CA 2023 из файлов, которые взял Export-LunqBootCA2023:
    # bootmgfw_EX.efi вместо efi\boot\bootx64.efi, bootmgr_EX.efi вместо bootmgr.efi, efisys_EX.bin
    # вместо efisys.bin и шрифты. Имена берутся без _EX, как их пишет bcdboot /bootex. Без файлов
    # на ISO остаётся обычный загрузчик, и итог об этом говорит.
    param([Parameter(Mandatory)][string]$IsoRoot, [Parameter(Mandatory)][string]$From)

    $result = New-LunqResult (Get-LunqText 'Servicing.BootCA2023Title') 'BootCA2023'
    if (-not (Test-Path -LiteralPath (Join-Path $From 'EFI_EX\bootmgfw_EX.efi'))) {
        $result.Failed.Add('bootmgfw_EX.efi')
        $result.Summary = Get-LunqText 'Servicing.BootCA2023Fallback'
        return $result
    }
    # Третье значение: заменять, только если файл на ISO уже есть (bootaa64.efi есть только на ARM64).
    $pairs = @(
        @('EFI_EX\bootmgfw_EX.efi', 'efi\boot\bootx64.efi', $true),
        @('EFI_EX\bootmgfw_EX.efi', 'efi\boot\bootaa64.efi', $true),
        @('EFI_EX\bootmgr_EX.efi', 'bootmgr.efi', $true),
        @('DVD_EX\EFI\en-US\efisys_EX.bin', 'efi\microsoft\boot\efisys.bin', $true),
        @('DVD_EX\EFI\en-US\efisys_noprompt_EX.bin', 'efi\microsoft\boot\efisys_noprompt.bin', $true)
    )
    $fontsDir = Join-Path $From 'Fonts_EX'
    $fonts = @()
    if (Test-Path -LiteralPath $fontsDir) { $fonts = @(Get-ChildItem -LiteralPath $fontsDir -File) }
    foreach ($font in $fonts) {
        $pairs += , @("Fonts_EX\$($font.Name)", ('efi\microsoft\boot\fonts\' + ($font.Name -replace '(?i)_EX(?=\.[^.]+$)', '')), $false)
    }
    $fontsDone = 0
    foreach ($pair in $pairs) {
        $source = Join-Path $From $pair[0]
        $target = Join-Path $IsoRoot $pair[1]
        if (-not (Test-Path -LiteralPath $source)) { continue }
        if ($pair[2] -and -not (Test-Path -LiteralPath $target)) { continue }
        try {
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
            if ($pair[0] -like 'Fonts_EX\*') { $fontsDone++ }
            else { $result.Done.Add($pair[1]) }
        }
        catch {
            Write-Warning (Get-LunqText 'Servicing.BootCA2023Failed' $pair[1] $_.Exception.Message)
            $result.Failed.Add($pair[1])
        }
    }
    if ($result.Failed.Count -eq 0) { $result.Summary = Get-LunqText 'Servicing.BootCA2023Done' ($result.Done -join ', ') $fontsDone }
    return $result
}

function Get-LunqSignatureError {
    # Что не так с подписью Microsoft на файле, или $null, если она в порядке. expand.exe ничего не
    # проверяет, а файлы Setup Dynamic Update выполняются при установке Windows. Пакеты .msu и .cab,
    # которые ставит DISM, он проверяет сам.
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { return [string]$signature.Status }
    $subject = [string]$signature.SignerCertificate.Subject
    if ($subject -notmatch '(?i)(^|,\s*)O=Microsoft Corporation(,|$)') { return $subject }
    return $null
}

function Add-LunqSetupDynamicUpdate {
    # Setup Dynamic Update: .cab, который распаковывается в sources ISO поверх файлов установщика.
    param([Parameter(Mandatory)][string]$IsoRoot, [Parameter(Mandatory)]$Files)

    $result = New-LunqResult (Get-LunqText 'Servicing.SetupDUTitle') 'UpdatesSetupDU'
    $sources = Join-Path $IsoRoot 'sources'
    $i = 0
    foreach ($file in $Files) {
        $i++
        Write-Info (Get-LunqText 'Servicing.Expanding' $i $Files.Count $file.Name (Format-Size $file.Length))
        $signatureError = Get-LunqSignatureError -Path $file.FullName
        if ($signatureError) {
            Write-Warning (Get-LunqText 'Servicing.NotSigned' $file.Name $signatureError)
            $result.Failed.Add($file.Name)
            continue
        }
        $code = Invoke-Native expand.exe @($file.FullName, '-F:*', $sources)
        if ($code -eq 0) { $result.Done.Add($file.Name) }
        else {
            Write-Warning (Get-LunqText 'Servicing.ExpandFailed' $file.Name $code)
            $result.Failed.Add($file.Name)
        }
    }
    return $result
}

function Update-LunqRecovery {
    # Среда восстановления лежит внутри системы: Windows\System32\Recovery\Winre.wim.
    # Её копируют в рабочую папку, обслуживают, пересжимают и возвращают на место.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$PEMountPath,
        $Updates = @(),
        $SafeOS = @(),
        $Drivers = @(),
        [string]$DriversRoot
    )

    $inImage = Join-Path $MountPath 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $inImage)) {
        Write-Warning (Get-LunqText 'Servicing.NoWinre')
        return
    }
    $original = Get-Item -LiteralPath $inImage -Force
    $attributes = $original.Attributes
    $work = Join-Path $WorkDir 'winre.wim'
    Copy-Item -LiteralPath $inImage -Destination $work -Force
    (Get-Item -LiteralPath $work -Force).Attributes = 'Normal'

    $results = Update-LunqPEImage -ImagePath $work -Index 1 -MountPath $PEMountPath -ScratchDir (Join-Path $WorkDir 'scratch') `
        -Where 'WinRE' -KindSuffix 'Recovery' -Updates $Updates -SafeOS $SafeOS -Drivers $Drivers -DriversRoot $DriversRoot
    Write-Info (Get-LunqText 'Servicing.Recompressing' 'Winre.wim')
    Optimize-LunqWim -Path $work
    Write-Info (Get-LunqText 'Servicing.SizeChange' 'Winre.wim' (Format-Size $original.Length) (Format-Size (Get-Item -LiteralPath $work).Length))

    $original.Attributes = 'Normal'
    Copy-Item -LiteralPath $work -Destination $inImage -Force
    (Get-Item -LiteralPath $inImage -Force).Attributes = $attributes
    Remove-Item -LiteralPath $work -Force
    return $results
}

function Update-LunqSetup {
    # Установщик: boot.wim, образ 2 («Установка Windows»), с которого загружается флешка.
    # Setup Dynamic Update распаковывается в sources, затем setup.exe и setuphost.exe
    # копируются туда же из обновлённого boot.wim, чтобы версии совпадали. Этот порядок взят
    # из инструкции Microsoft. Если для boot.wim нет ни обновлений, ни драйверов, он не трогается,
    # чтобы не пересжимать его впустую. Если обновления в boot.wim не встали, setup.exe не копируется.
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$PEMountPath,
        $Updates = @(),
        $SetupUpdates = @(),
        $Drivers = @(),
        [string]$DriversRoot
    )

    $bootWim = Join-Path $IsoRoot 'sources\boot.wim'
    if (-not (Test-Path -LiteralPath $bootWim)) { throw (Get-LunqText 'Servicing.NoBootWim') }
    $results = @()
    if (@($SetupUpdates).Count -gt 0) { $results += Add-LunqSetupDynamicUpdate -IsoRoot $IsoRoot -Files $SetupUpdates }
    if (@($Updates).Count + @($Drivers).Count -eq 0) { return $results }
    $before = (Get-Item -LiteralPath $bootWim).Length
    $results += Update-LunqPEImage -ImagePath $bootWim -Index 2 -MountPath $PEMountPath -ScratchDir (Join-Path $WorkDir 'scratch') `
        -Where (Get-LunqText 'Servicing.WhereSetup') -KindSuffix 'Setup' -Updates $Updates -Drivers $Drivers -DriversRoot $DriversRoot `
        -ExportSetupTo (Join-Path $IsoRoot 'sources') -BootFilesTo $IsoRoot
    Write-Info (Get-LunqText 'Servicing.Recompressing' 'boot.wim')
    Optimize-LunqWim -Path $bootWim -BootIndex 2
    Write-Info (Get-LunqText 'Servicing.SizeChange' 'boot.wim' (Format-Size $before) (Format-Size (Get-Item -LiteralPath $bootWim).Length))
    return $results
}
