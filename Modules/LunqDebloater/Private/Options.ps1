function New-LunqOption {
    # Пункт сводки «Что войдёт в образ». Parent: Key пункта, без которого этот не имеет смысла.
    # Action: пункт не включается и не выключается, а запускает действие (например, выбор папки).
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Enabled = $true,
        [bool]$Available = $true,
        [string[]]$Details = @(),
        [string]$Parent,
        [switch]$Action
    )
    return [pscustomobject]@{
        Key = $Key; Name = $Name; Enabled = $Enabled; Available = $Available
        Details = @($Details); Parent = $Parent; Action = [bool]$Action
    }
}

function Test-LunqOption {
    # Включён ли пункт с учётом родителя.
    param([Parameter(Mandatory)]$Options, [Parameter(Mandatory)][string]$Key)
    $option = $Options | Where-Object { $_.Key -eq $Key }
    if (-not $option -or -not $option.Available -or -not $option.Enabled) { return $false }
    if ($option.Parent) { return (Test-LunqOption -Options $Options -Key $option.Parent) }
    return $true
}

function Select-LunqBuildOptions {
    # Одна сводка вместо отдельных вопросов: всё, что найдено в папке Config, с переключением по номерам.
    # Пункты, для которых ничего не найдено, показываются с подсказкой и без номера.
    # Возвращает Key выбранного действия или $null, когда пользователь нажал Enter.
    param([Parameter(Mandatory)]$Options)

    $numbered = @($Options | Where-Object { $_.Available })
    $numbers = @{}
    for ($i = 0; $i -lt $numbered.Count; $i++) { $numbers[$numbered[$i].Key] = $i + 1 }
    while ($true) {
        Write-Info ''
        foreach ($option in $Options) {
            if (-not $option.Available -and $option.Parent) { continue }
            $indent = if ($option.Parent) { '    ' } else { '' }
            $on = Test-LunqOption -Options $Options -Key $option.Key
            if ($option.Available) {
                Write-Host ('    {0,-4} ' -f "[$($numbers[$option.Key])]") -ForegroundColor Cyan -NoNewline
            }
            else { Write-Host '         ' -NoNewline }
            $mark = if ($option.Action) { ' > ' } elseif ($on) { '[x]' } else { '[ ]' }
            $color = if ($option.Action) { 'Cyan' } elseif ($on) { 'Green' } else { 'DarkGray' }
            Write-Host "$indent$mark " -NoNewline -ForegroundColor $color
            if ($option.Available) { Write-Host $option.Name } else { Write-Host $option.Name -ForegroundColor DarkGray }
            foreach ($line in $option.Details) { Write-Host "           $indent$line" -ForegroundColor DarkGray }
        }
        Write-Info ''
        if ($numbered.Count -eq 0) { return $null }
        $answer = Read-Host ('    ' + (Get-LunqText 'Options.Prompt'))
        if (-not $answer -or -not $answer.Trim()) { return $null }
        $action = $null
        foreach ($token in ($answer -split '[\s,;]+' | Where-Object { $_ })) {
            $parsed = 0
            if (-not ([int]::TryParse($token, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $numbered.Count)) {
                Write-LunqWarning (Get-LunqText 'Options.NoSuchNumber' $token)
                continue
            }
            $option = $numbered[$parsed - 1]
            # Действие выполняется после того, как применены остальные номера из ответа.
            if ($option.Action) {
                $action = $option.Key
                continue
            }
            if ($option.Parent -and -not (Test-LunqOption -Options $Options -Key $option.Parent)) {
                Write-LunqWarning (Get-LunqText 'Options.NeedsParent' $parsed ($numbers[$option.Parent]))
                continue
            }
            $option.Enabled = -not $option.Enabled
        }
        if ($action) { return $action }
    }
}

function Get-LunqFilesSize {
    # Общий размер файлов в байтах.
    param($Files)
    $sum = [long]0
    foreach ($file in @($Files)) { if ($file) { $sum += $file.Length } }
    return $sum
}

function Find-LunqBuildInputs {
    # Обновления и драйверы в выбранных папках. Safe OS и Setup Dynamic Update лежат в своих
    # подпапках: они для WinRE и установщика, а не для системы. В папке, выбранной целиком
    # (например, «Загрузки»), подпапок нет, поэтому .cab в корне распознаются по содержимому.
    param(
        [Parameter(Mandatory)][string]$UpdatesDir,
        [Parameter(Mandatory)][string]$DriversDir,
        [Parameter(Mandatory)][string]$CabCheckDir,
        [hashtable]$CabCache = @{}
    )
    $split = Split-LunqDynamicUpdates -Files (Get-LunqUpdateFiles -Path $UpdatesDir) -TempDir $CabCheckDir -Cache $CabCache
    $subSafeOS = Get-LunqUpdateFiles -Path (Join-Path $UpdatesDir 'SafeOS')
    # Get-LunqUpdateFiles отдаёт список одним объектом: фильтр в конвейере увидел бы его целиком.
    $setupFiles = Get-LunqUpdateFiles -Path (Join-Path $UpdatesDir 'Setup')
    $subSetupDU = @($setupFiles | Where-Object { $_.Extension -eq '.cab' })
    $duNames = @($split.SafeOS | ForEach-Object { Get-LunqText 'Main.SafeOSItem' $_.Name }) + @($subSafeOS | ForEach-Object { "SafeOS\$($_.Name)" }) +
        @($split.Setup | ForEach-Object { Get-LunqText 'Main.SetupDUItem' $_.Name }) + @($subSetupDU | ForEach-Object { "Setup\$($_.Name)" })
    return [pscustomobject]@{
        Updates = @($split.Updates)
        SafeOS  = @($split.SafeOS) + @($subSafeOS)
        SetupDU = @($split.Setup) + @($subSetupDU)
        DUNames = @($duNames)
        Drivers = Get-LunqDriverFiles -Path $DriversDir
    }
}

function New-LunqContentOptions {
    # Пункты сводки «Что войдёт в образ» по тому, что нашлось. Use: что включено сейчас (ключи
    # updates, cleanup, updatesToSetup, drivers, driversToSetup, apps, scripts, unattend, oobe, region,
    # bypass, localAccount).
    param(
        [Parameter(Mandatory)]$Found,
        [Parameter(Mandatory)]$FirstLogon,
        [Parameter(Mandatory)][hashtable]$Use,
        $HostRegion,
        [Parameter(Mandatory)][string]$UpdatesDir,
        [Parameter(Mandatory)][string]$DriversDir,
        [hashtable]$PEDriverCache = @{}
    )
    $foundDU = @($Found.SafeOS) + @($Found.SetupDU)
    $hasUpdates = ($Found.Updates.Count + $foundDU.Count) -gt 0
    $hasDrivers = $Found.Drivers.Count -gt 0
    $hasApps = $FirstLogon.Apps.Count -gt 0
    $hasScripts = $FirstLogon.Scripts.Count -gt 0

    if ($hasUpdates) {
        $updatesName = Get-LunqText 'Main.UpdatesFound' ($Found.Updates.Count + $foundDU.Count) (Format-Size (Get-LunqFilesSize (@($Found.Updates) + $foundDU)))
        $updatesDetails = @($Found.Updates | ForEach-Object { $_.Name }) + $Found.DUNames + (Get-LunqText 'Main.FoundIn' $UpdatesDir) + (Get-LunqText 'Main.UpdatesFoundHint')
    }
    else {
        $updatesName = Get-LunqText 'Main.UpdatesNone'
        $updatesDetails = Get-LunqText 'Main.UpdatesNoneHint'
    }
    if ($hasDrivers) {
        $driversName = Get-LunqText 'Main.DriversFound' $Found.Drivers.Count (Format-Size (Get-FolderSize $DriversDir))
        $driversDetails = @((Get-LunqText 'Main.FoundIn' $DriversDir), (Get-LunqText 'Main.DriversFoundHint'))
    }
    else {
        $driversName = Get-LunqText 'Main.DriversNone'
        $driversDetails = Get-LunqText 'Main.DriversNoneHint'
    }
    if ($hasApps) {
        $appsName = Get-LunqText 'Main.AppsFound' $FirstLogon.Apps.Count
        $appsDetails = $FirstLogon.Apps -join ', '
    }
    else {
        $appsName = Get-LunqText 'Main.AppsNone'
        $appsDetails = Get-LunqText 'Main.AppsNoneHint'
    }
    if ($hasScripts) {
        $scriptsName = Get-LunqText 'Main.ScriptsFound' $FirstLogon.Scripts.Count
        $scriptsDetails = ($FirstLogon.Scripts | ForEach-Object { $_.Name }) -join ', '
    }
    else {
        $scriptsName = Get-LunqText 'Main.ScriptsNone'
        $scriptsDetails = Get-LunqText 'Main.ScriptsNoneHint'
    }
    $regionDetails = Get-LunqText 'Main.RegionDetails' $HostRegion.Locale ($HostRegion.Keyboards -join ', ') $HostRegion.TimeZone
    $peDriversCount = (Select-LunqPEDrivers $Found.Drivers -Cache $PEDriverCache).Count
    $updatesToSetupDetails = @(Get-LunqText 'Main.OptUpdatesToSetupHint')
    if ($foundDU.Count -gt 0) { $updatesToSetupDetails += Get-LunqText 'Main.OptUpdatesToSetupDU' $Found.SafeOS.Count $Found.SetupDU.Count }

    return @(
        (New-LunqOption -Key 'updates' -Enabled $Use.updates -Available $hasUpdates -Name $updatesName -Details $updatesDetails),
        (New-LunqOption -Key 'cleanup' -Parent 'updates' -Enabled $Use.cleanup -Available $hasUpdates `
            -Name (Get-LunqText 'Main.OptCleanup') `
            -Details (Get-LunqText 'Main.OptCleanupHint')),
        (New-LunqOption -Key 'updatesToSetup' -Parent 'updates' -Enabled ($Use.updatesToSetup -or $foundDU.Count -gt 0) -Available $hasUpdates `
            -Name (Get-LunqText 'Main.OptUpdatesToSetup') `
            -Details $updatesToSetupDetails),
        (New-LunqOption -Key 'pickUpdates' -Action -Name (Get-LunqText 'Main.OptPickUpdates') -Details (Get-LunqText 'Main.OptPickUpdatesHint')),
        (New-LunqOption -Key 'drivers' -Enabled $Use.drivers -Available $hasDrivers -Name $driversName -Details $driversDetails),
        (New-LunqOption -Key 'driversToSetup' -Parent 'drivers' -Enabled $Use.driversToSetup -Available $hasDrivers `
            -Name (Get-LunqText 'Main.OptDriversToSetup' $peDriversCount) `
            -Details (Get-LunqText 'Main.OptDriversToSetupHint')),
        (New-LunqOption -Key 'pickDrivers' -Action -Name (Get-LunqText 'Main.OptPickDrivers') -Details (Get-LunqText 'Main.OptPickDriversHint')),
        (New-LunqOption -Key 'hostDrivers' -Action -Name (Get-LunqText 'Main.OptHostDrivers') -Details (Get-LunqText 'Main.OptHostDriversHint')),
        (New-LunqOption -Key 'apps' -Enabled $Use.apps -Available $hasApps -Name $appsName -Details $appsDetails),
        (New-LunqOption -Key 'scripts' -Enabled $Use.scripts -Available $hasScripts -Name $scriptsName -Details $scriptsDetails),
        (New-LunqOption -Key 'unattend' -Enabled $Use.unattend -Name (Get-LunqText 'Main.OptUnattend') `
            -Details (Get-LunqText 'Main.OptUnattendHint')),
        (New-LunqOption -Key 'oobe' -Parent 'unattend' -Enabled $Use.oobe -Name (Get-LunqText 'Main.OptOobe') `
            -Details (Get-LunqText 'Main.OptOobeHint')),
        (New-LunqOption -Key 'region' -Parent 'unattend' -Enabled $Use.region -Name (Get-LunqText 'Main.OptRegion') `
            -Details $regionDetails),
        (New-LunqOption -Key 'bypass' -Parent 'unattend' -Enabled $Use.bypass -Name (Get-LunqText 'Main.OptBypass') `
            -Details (Get-LunqText 'Main.OptBypassHint')),
        (New-LunqOption -Key 'localAccount' -Parent 'unattend' -Enabled $Use.localAccount -Name (Get-LunqText 'Main.OptLocalAccount') `
            -Details (Get-LunqText 'Main.OptLocalAccountHint'))
    )
}

function Invoke-LunqContentAction {
    # Пункт-действие сводки: выбор папки с обновлениями или драйверами либо выгрузка драйверов
    # этого компьютера. Возвращает Kind ('Updates' или 'Drivers') и Path новой папки, или $null,
    # если папку не выбрали или в ней ничего нет.
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$HostDriversDir)
    if ($Action -eq 'pickUpdates') {
        $picked = Select-LunqFolder -Description (Get-LunqText 'Main.PickUpdatesTitle')
        if (-not $picked) { return $null }
        $pickedCount = @(Get-LunqUpdateFiles -Path $picked).Count + @(Get-LunqUpdateFiles -Path (Join-Path $picked 'SafeOS')).Count +
            @(Get-LunqUpdateFiles -Path (Join-Path $picked 'Setup')).Count
        if ($pickedCount -eq 0) {
            Write-LunqWarning (Get-LunqText 'Main.UpdatesDirEmpty' $picked)
            return $null
        }
        return [pscustomobject]@{ Kind = 'Updates'; Path = $picked }
    }
    $picked = $null
    if ($Action -eq 'pickDrivers') {
        $picked = Select-LunqFolder -Description (Get-LunqText 'Main.PickDriversTitle')
        if ($picked -and @(Get-LunqDriverFiles -Path $picked).Count -eq 0) {
            Write-LunqWarning (Get-LunqText 'Main.DriversDirEmpty' $picked)
            $picked = $null
        }
    }
    else {
        Write-Info (Get-LunqText 'Main.HostDriversExporting')
        try {
            if (@(Export-LunqHostDrivers -Destination $HostDriversDir).Count -gt 0) { $picked = $HostDriversDir }
            else { Write-LunqWarning (Get-LunqText 'Main.HostDriversNone') }
        }
        catch { Write-LunqWarning (Get-LunqText 'Main.HostDriversFailed' $_.Exception.Message) }
    }
    if (-not $picked) { return $null }
    return [pscustomobject]@{ Kind = 'Drivers'; Path = $picked }
}

function Select-LunqFolder {
    # Окно выбора папки, например с драйверами или обновлениями. Если окно недоступно, путь
    # вводится вручную. Отмена возвращает $null, и сводка просто показывается снова.
    param([Parameter(Mandatory)][string]$Description)
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        $dialogResult = $null
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = $Description
            $dialog.ShowNewFolderButton = $false
            # Невидимое окно-владелец поверх остальных, чтобы диалог не открылся за консолью.
            $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
            $dialogResult = $dialog.ShowDialog($owner)
            $owner.Dispose()
        }
        catch { $dialogResult = $null }
        if ($null -ne $dialogResult) {
            if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
            return $null
        }
    }
    $path = (Read-Host ('    ' + (Get-LunqText 'Options.FolderPrompt' $Description))).Trim().Trim('"')
    if (-not $path) { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-LunqWarning (Get-LunqText 'Options.FolderNotFound' $path)
        return $null
    }
    return (Resolve-Path -LiteralPath $path).Path
}
