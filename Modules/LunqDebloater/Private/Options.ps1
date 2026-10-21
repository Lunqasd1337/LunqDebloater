function New-LunqOption {
    # Пункт сводки «Что войдёт в образ». Parent: Key пункта, без которого этот не имеет смысла,
    # или несколько Key, если пункту хватает любого из них.
    # Action: пункт не включается и не выключается, а запускает действие (например, выбор папки).
    # Section: раздел сводки, Short: как пункт называется в строке раздела на главном экране.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Enabled = $true,
        [bool]$Available = $true,
        [string[]]$Details = @(),
        [string[]]$Parent,
        [switch]$Action,
        [string]$Section = '',
        [string]$Short = ''
    )
    if (-not $Short) { $Short = $Name }
    return [pscustomobject]@{
        Key = $Key; Name = $Name; Enabled = $Enabled; Available = $Available
        Details = @($Details); Parent = $Parent; Action = [bool]$Action; Section = $Section; Short = $Short
    }
}

function Test-LunqOption {
    # Включён ли пункт с учётом родителя. Из нескольких родителей достаточно одного включённого.
    param([Parameter(Mandatory)]$Options, [Parameter(Mandatory)][string]$Key)
    $option = $Options | Where-Object { $_.Key -eq $Key }
    if (-not $option -or -not $option.Available -or -not $option.Enabled) { return $false }
    if (-not $option.Parent) { return $true }
    foreach ($parent in $option.Parent) {
        if (Test-LunqOption -Options $Options -Key $parent) { return $true }
    }
    return $false
}

function Get-LunqOptionSectionTitle {
    # Заголовок раздела сводки по его ключу (Section у пунктов).
    param([string]$Section)
    switch ($Section) {
        'updates' { return Get-LunqText 'Options.SectionUpdates' }
        'drivers' { return Get-LunqText 'Options.SectionDrivers' }
        'firstLogon' { return Get-LunqText 'Options.SectionFirstLogon' }
        'setup' { return Get-LunqText 'Options.SectionSetup' }
        'extra' { return Get-LunqText 'Options.SectionExtra' }
    }
    return $Section
}

function Select-LunqBuildOptions {
    # Сводка по разделам: на главном экране по строке на раздел с тем, что в нём включено,
    # а номер открывает раздел с его пунктами. Так два десятка пунктов не идут одним списком.
    # Возвращает Key выбранного действия или $null, когда пользователь нажал Enter.
    param([Parameter(Mandatory)]$Options)

    $sections = @($Options | ForEach-Object { $_.Section } | Select-Object -Unique)
    $titles = @($sections | ForEach-Object { Get-LunqOptionSectionTitle $_ })
    $width = ($titles | Measure-Object -Property Length -Maximum).Maximum + 2
    while ($true) {
        Write-Info ''
        for ($i = 0; $i -lt $sections.Count; $i++) {
            $section = $sections[$i]
            $toggles = @($Options | Where-Object { $_.Section -eq $section -and $_.Available -and -not $_.Action })
            $on = @($toggles | Where-Object { Test-LunqOption -Options $Options -Key $_.Key })
            if ($on.Count -gt 0) { $status = ($on | ForEach-Object { $_.Short }) -join '; ' }
            elseif ($toggles.Count -gt 0) { $status = Get-LunqText 'Options.StatusOff' }
            else { $status = Get-LunqText 'Options.StatusNone' }
            Write-Host ('    {0,-4} ' -f "[$($i + 1)]") -ForegroundColor Cyan -NoNewline
            Write-Host $titles[$i].PadRight($width) -NoNewline
            if ($on.Count -gt 0) { Write-Host $status -ForegroundColor Green } else { Write-Host $status -ForegroundColor DarkGray }
        }
        Write-Info ''
        $answer = ([string](Read-Host ('    ' + (Get-LunqText 'Options.MainPrompt')))).Trim()
        if (-not $answer) { return $null }
        $parsed = 0
        if (-not ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $sections.Count)) {
            Write-Warning (Get-LunqText 'Options.NoSuchNumber' $answer)
            continue
        }
        Write-Info ''
        Write-Host ('    ' + $titles[$parsed - 1]) -ForegroundColor Cyan
        $items = @($Options | Where-Object { $_.Section -eq $sections[$parsed - 1] })
        $action = Select-LunqOptionList -Options $Options -Items $items -Prompt (Get-LunqText 'Options.SectionPrompt')
        if ($action) { return $action }
    }
}

function Select-LunqOptionList {
    # Список пунктов с переключением по номерам. Items: показываемые пункты (раздел сводки),
    # номера идут по ним. Options: все пункты, чтобы проверять родителей из других разделов.
    # Пункты, для которых ничего не найдено, показываются с подсказкой и без номера.
    # Возвращает Key выбранного действия или $null, когда пользователь нажал Enter.
    param([Parameter(Mandatory)]$Options, $Items, [Parameter(Mandatory)][string]$Prompt)
    if ($null -eq $Items) { $Items = $Options }

    $numbered = @($Items | Where-Object { $_.Available })
    $numbers = @{}
    for ($i = 0; $i -lt $numbered.Count; $i++) { $numbers[$numbered[$i].Key] = $i + 1 }
    while ($true) {
        Write-Info ''
        foreach ($option in $Items) {
            if (-not $option.Available -and $option.Parent) { continue }
            $indent = if ($option.Parent -and ($Items | Where-Object { $option.Parent -contains $_.Key })) { '    ' } else { '' }
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
        $answer = Read-Host ('    ' + $Prompt)
        if (-not $answer -or -not $answer.Trim()) { return $null }
        $action = $null
        foreach ($token in ($answer -split '[\s,;]+' | Where-Object { $_ })) {
            $parsed = 0
            if (-not ([int]::TryParse($token, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $numbered.Count)) {
                Write-Warning (Get-LunqText 'Options.NoSuchNumber' $token)
                continue
            }
            $option = $numbered[$parsed - 1]
            # Действие выполняется после того, как применены остальные номера из ответа.
            if ($option.Action) {
                $action = $option.Key
                continue
            }
            $parentOn = -not $option.Parent
            foreach ($parent in $option.Parent) {
                if (Test-LunqOption -Options $Options -Key $parent) { $parentOn = $true }
            }
            if (-not $parentOn) {
                # Родитель без номера (например, обновлений в папке нет) включить нельзя, его не называем.
                # Родителя из другого раздела называем по имени: его номер здесь не виден.
                $parents = @($option.Parent | ForEach-Object { $numbers[$_] } | Where-Object { $_ })
                $parents += @($Options | Where-Object { $option.Parent -contains $_.Key -and $_.Available -and -not $numbers.ContainsKey($_.Key) } |
                        ForEach-Object { Get-LunqText 'Options.ParentIn' $_.Name (Get-LunqOptionSectionTitle $_.Section) })
                if ($parents.Count -gt 1) { Write-Warning (Get-LunqText 'Options.NeedsAnyParent' $parsed ($parents -join ', ')) }
                else { Write-Warning (Get-LunqText 'Options.NeedsParent' $parsed ($parents -join '')) }
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
    # updates, cleanup, updatesToSetup, download, drivers, driversToSetup, apps, hostApps, scripts, wifi,
    # unattend, oobe, region, bypass, localAccount, bootCA2023, defender).
    param(
        [Parameter(Mandatory)]$Found,
        [Parameter(Mandatory)]$FirstLogon,
        [Parameter(Mandatory)][hashtable]$Use,
        $HostRegion,
        [Parameter(Mandatory)][string]$UpdatesDir,
        [Parameter(Mandatory)][string]$DriversDir,
        [hashtable]$PEDriverCache = @{},
        [hashtable]$SizeCache = @{}
    )
    $foundDU = @($Found.SafeOS) + @($Found.SetupDU)
    $hasUpdates = ($Found.Updates.Count + $foundDU.Count) -gt 0
    $hasDrivers = $Found.Drivers.Count -gt 0
    $hasApps = $FirstLogon.Apps.Count -gt 0
    $hasScripts = $FirstLogon.Scripts.Count -gt 0

    $updatesShort = ''
    $driversShort = ''
    if ($hasUpdates) {
        $updatesSize = Format-Size (Get-LunqFilesSize (@($Found.Updates) + $foundDU))
        $updatesName = Get-LunqText 'Main.UpdatesFound' ($Found.Updates.Count + $foundDU.Count) $updatesSize
        $updatesShort = Get-LunqText 'Main.ShortUpdates' ($Found.Updates.Count + $foundDU.Count) $updatesSize
        $updatesDetails = @($Found.Updates | ForEach-Object { $_.Name }) + $Found.DUNames + (Get-LunqText 'Main.FoundIn' $UpdatesDir) + (Get-LunqText 'Main.UpdatesFoundHint')
    }
    else {
        $updatesName = Get-LunqText 'Main.UpdatesNone'
        $updatesDetails = Get-LunqText 'Main.UpdatesNoneHint'
    }
    if ($hasDrivers) {
        $driversSize = Format-Size (Get-FolderSize $DriversDir -Cache $SizeCache)
        $driversName = Get-LunqText 'Main.DriversFound' $Found.Drivers.Count $driversSize
        $driversShort = Get-LunqText 'Main.ShortDrivers' $Found.Drivers.Count $driversSize
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

    # Порядок пунктов задаёт и порядок разделов. Редкие пункты собраны в разделе «Дополнительно».
    return @(
        (New-LunqOption -Key 'updates' -Section 'updates' -Enabled $Use.updates -Available $hasUpdates -Name $updatesName -Details $updatesDetails -Short $updatesShort),
        (New-LunqOption -Key 'updatesToSetup' -Section 'updates' -Parent 'updates' -Enabled ($Use.updatesToSetup -or $foundDU.Count -gt 0) -Available $hasUpdates `
            -Name (Get-LunqText 'Main.OptUpdatesToSetup') -Short (Get-LunqText 'Main.ShortUpdatesToSetup') `
            -Details $updatesToSetupDetails),
        (New-LunqOption -Key 'pickUpdates' -Section 'updates' -Action -Name (Get-LunqText 'Main.OptPickUpdates') -Details (Get-LunqText 'Main.OptPickUpdatesHint')),
        (New-LunqOption -Key 'download' -Section 'updates' -Enabled $Use.download -Name (Get-LunqText 'Main.OptDownload') -Short (Get-LunqText 'Main.ShortDownload') `
            -Details (Get-LunqText 'Main.OptDownloadHint')),
        (New-LunqOption -Key 'drivers' -Section 'drivers' -Enabled $Use.drivers -Available $hasDrivers -Name $driversName -Details $driversDetails -Short $driversShort),
        (New-LunqOption -Key 'driversToSetup' -Section 'drivers' -Parent 'drivers' -Enabled $Use.driversToSetup -Available $hasDrivers `
            -Name (Get-LunqText 'Main.OptDriversToSetup' $peDriversCount) -Short (Get-LunqText 'Main.ShortDriversToSetup') `
            -Details (Get-LunqText 'Main.OptDriversToSetupHint')),
        (New-LunqOption -Key 'pickDrivers' -Section 'drivers' -Action -Name (Get-LunqText 'Main.OptPickDrivers') -Details (Get-LunqText 'Main.OptPickDriversHint')),
        (New-LunqOption -Key 'hostDrivers' -Section 'drivers' -Action -Name (Get-LunqText 'Main.OptHostDrivers') -Details (Get-LunqText 'Main.OptHostDriversHint')),
        (New-LunqOption -Key 'apps' -Section 'firstLogon' -Enabled $Use.apps -Available $hasApps -Name $appsName -Details $appsDetails `
            -Short (Get-LunqText 'Main.ShortApps' $FirstLogon.Apps.Count)),
        (New-LunqOption -Key 'hostApps' -Section 'firstLogon' -Enabled $Use.hostApps -Name (Get-LunqText 'Main.OptHostApps') -Short (Get-LunqText 'Main.ShortHostApps') `
            -Details (Get-LunqText 'Main.OptHostAppsHint')),
        (New-LunqOption -Key 'scripts' -Section 'firstLogon' -Enabled $Use.scripts -Available $hasScripts -Name $scriptsName -Details $scriptsDetails `
            -Short (Get-LunqText 'Main.ShortScripts' $FirstLogon.Scripts.Count)),
        (New-LunqOption -Key 'wifi' -Section 'firstLogon' -Enabled $Use.wifi -Name (Get-LunqText 'Main.OptHostWifi') -Short (Get-LunqText 'Main.ShortHostWifi') `
            -Details @((Get-LunqText 'Main.OptHostWifiHint'), (Get-LunqText 'Main.OptHostWifiWarning'))),
        (New-LunqOption -Key 'unattend' -Section 'setup' -Enabled $Use.unattend -Name (Get-LunqText 'Main.OptUnattend') -Short (Get-LunqText 'Main.ShortUnattend') `
            -Details (Get-LunqText 'Main.OptUnattendHint')),
        (New-LunqOption -Key 'oobe' -Section 'setup' -Parent 'unattend' -Enabled $Use.oobe -Name (Get-LunqText 'Main.OptOobe') -Short (Get-LunqText 'Main.ShortOobe') `
            -Details (Get-LunqText 'Main.OptOobeHint')),
        (New-LunqOption -Key 'region' -Section 'setup' -Parent 'unattend' -Enabled $Use.region -Name (Get-LunqText 'Main.OptRegion') -Short (Get-LunqText 'Main.ShortRegion') `
            -Details $regionDetails),
        (New-LunqOption -Key 'bypass' -Section 'setup' -Parent 'unattend' -Enabled $Use.bypass -Name (Get-LunqText 'Main.OptBypass') -Short (Get-LunqText 'Main.ShortBypass') `
            -Details (Get-LunqText 'Main.OptBypassHint')),
        (New-LunqOption -Key 'localAccount' -Section 'setup' -Parent 'unattend' -Enabled $Use.localAccount -Name (Get-LunqText 'Main.OptLocalAccount') `
            -Short (Get-LunqText 'Main.ShortLocalAccount') -Details (Get-LunqText 'Main.OptLocalAccountHint')),
        # Очистка нужна и обновлениям из папки, и скачанным, поэтому у неё два родителя.
        (New-LunqOption -Key 'cleanup' -Section 'extra' -Parent 'updates', 'download' -Enabled $Use.cleanup `
            -Name (Get-LunqText 'Main.OptCleanup') -Short (Get-LunqText 'Main.ShortCleanup') `
            -Details (Get-LunqText 'Main.OptCleanupHint')),
        (New-LunqOption -Key 'bootCA2023' -Section 'extra' -Enabled ([bool]$Use.bootCA2023) -Name (Get-LunqText 'Main.OptBootCA2023') -Short (Get-LunqText 'Main.ShortBootCA2023') `
            -Details @((Get-LunqText 'Main.OptBootCA2023Hint'), (Get-LunqText 'Main.BootCA2023Warning'))),
        (New-LunqOption -Key 'defender' -Section 'extra' -Enabled ([bool]$Use.defender) -Name (Get-LunqText 'Main.OptDefender') -Short (Get-LunqText 'Main.ShortDefender') `
            -Details (Get-LunqText 'Main.OptDefenderHint'))
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
            Write-Warning (Get-LunqText 'Main.UpdatesDirEmpty' $picked)
            return $null
        }
        return [pscustomobject]@{ Kind = 'Updates'; Path = $picked }
    }
    $picked = $null
    if ($Action -eq 'pickDrivers') {
        $picked = Select-LunqFolder -Description (Get-LunqText 'Main.PickDriversTitle')
        if ($picked -and @(Get-LunqDriverFiles -Path $picked).Count -eq 0) {
            Write-Warning (Get-LunqText 'Main.DriversDirEmpty' $picked)
            $picked = $null
        }
    }
    else {
        Write-Info (Get-LunqText 'Main.HostDriversExporting')
        try {
            if (@(Export-LunqHostDrivers -Destination $HostDriversDir).Count -gt 0) { $picked = $HostDriversDir }
            else { Write-Warning (Get-LunqText 'Main.HostDriversNone') }
        }
        catch { Write-Warning (Get-LunqText 'Main.HostDriversFailed' $_.Exception.Message) }
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
    $path = ([string](Read-Host ('    ' + (Get-LunqText 'Options.FolderPrompt' $Description)))).Trim().Trim('"')
    if (-not $path) { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Warning (Get-LunqText 'Options.FolderNotFound' $path)
        return $null
    }
    return (Resolve-Path -LiteralPath $path).Path
}
