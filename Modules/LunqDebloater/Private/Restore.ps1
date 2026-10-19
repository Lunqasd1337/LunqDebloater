# Данные для отката: что LunqDebloater удалил и какие значения реестра были до него. Сборка ISO
# кладёт их в образ (Windows\LunqDebloater\Restore.json), -Online дописывает в тот же файл на этой
# Windows. -Restore возвращает выбранные категории и убирает из файла то, что вернулось.

$script:RestoreKinds = @('Appx', 'Capabilities', 'Features', 'Packages', 'Uninstall')

function Get-LunqRestorePath {
    # Файл данных для отката на этой Windows. В образе он лежит по тому же пути от корня системы.
    return (Join-Path $env:SystemRoot 'LunqDebloater\Restore.json')
}

function New-LunqRestoreCategory {
    # Списки List[psobject], а не List[object]: @() над List[object] в PowerShell 7.6 падает
    # с ошибкой «Argument types do not match».
    param([Parameter(Mandatory)][string]$Id, $Name)
    return [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        Appx         = New-Object System.Collections.Generic.List[psobject]
        Capabilities = New-Object System.Collections.Generic.List[psobject]
        Features     = New-Object System.Collections.Generic.List[psobject]
        Packages     = New-Object System.Collections.Generic.List[psobject]
        Uninstall    = New-Object System.Collections.Generic.List[psobject]
        Registry     = New-Object System.Collections.Generic.List[psobject]
        RegistryKeys = New-Object System.Collections.Generic.List[psobject]
    }
}

function New-LunqRestoreData {
    # Пустые данные для отката. LunqProfile нужен, чтобы удалённое разложить по категориям профиля.
    param($LunqProfile, [ValidateSet('Image', 'Online')][string]$Source = 'Image')
    return [pscustomobject]@{
        Profile    = $LunqProfile
        Source     = $Source
        Categories = New-Object System.Collections.Generic.List[psobject]
    }
}

function Get-LunqRestoreCategory {
    # Категория в данных для отката: существующая или новая с именем из профиля.
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)][string]$Id)
    $existing = @($Restore.Categories | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if ($existing) { return $existing }
    $name = $Id
    $source = @($Restore.Profile.Categories | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if ($source) {
        # Имя с переводами, если профиль его дал: откат может идти на другом языке.
        $name = Get-ConfigValue $source 'NameSource'
        if ($null -eq $name) { $name = $source.Name }
    }
    $category = New-LunqRestoreCategory -Id $Id -Name $name
    $Restore.Categories.Add($category)
    return $category
}

function Find-LunqItemCategory {
    # Категория профиля, шаблон которой подошёл к имени: первая включённая.
    param([Parameter(Mandatory)]$LunqProfile, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Name)
    foreach ($category in @($LunqProfile.Categories | Where-Object { $_.Enabled })) {
        if (Test-NamePattern -Name $Name -Patterns (Get-ConfigList $category $Kind)) { return $category.Id }
    }
    return 'profile'
}

function Add-LunqRestoreItem {
    # Удалённое приложение, компонент, функция или пакет. Extra: дополнительные поля (имя семейства Appx).
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Name, [hashtable]$Extra = @{})
    $id = Find-LunqItemCategory -LunqProfile $Restore.Profile -Kind $Kind -Name $Name
    $category = Get-LunqRestoreCategory -Restore $Restore -Id $id
    $item = [ordered]@{ Name = $Name }
    foreach ($key in $Extra.Keys) { if ($null -ne $Extra[$key]) { $item[$key] = $Extra[$key] } }
    $category.$Kind.Add([pscustomobject]$item)
}

function Add-LunqRestoreRegistry {
    # Прежнее значение реестра в виде записи профиля: Set с прежним значением или DeleteValue.
    # Если значение уже запомнено (его пишут две категории), остаётся первая запись: вторая
    # увидела бы то, что записала первая категория, а не то, что было до сборки.
    param([Parameter(Mandatory)]$Restore, [string]$Category, [Parameter(Mandatory)]$Entry)
    if (-not $Category) { $Category = 'profile' }
    if (Test-LunqRestoreHasItem -Restore $Restore -Kind 'Registry' -Item $Entry) { return }
    (Get-LunqRestoreCategory -Restore $Restore -Id $Category).Registry.Add($Entry)
}

function Add-LunqRestoreRegistryKey {
    # Ключ, удалённый целиком: его текст из reg export. Повтор ключа не записывается, как и у значений.
    param([Parameter(Mandatory)]$Restore, [string]$Category, [Parameter(Mandatory)][string]$Hive, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Export)
    if (-not $Category) { $Category = 'profile' }
    $item = [pscustomobject]@{ Hive = $Hive; Path = $Path; Export = $Export }
    # -Online запоминает ключ текущего пользователя отдельно (CurrentUser), а если его не было, не
    # запоминает ничего. Тогда ключ профиля Default при откате не должен попадать и к нему.
    if ($Restore.Source -eq 'Online' -and $Hive -eq 'DefaultUser') { $item | Add-Member -NotePropertyName NoCurrentUser -NotePropertyValue $true }
    if (Test-LunqRestoreHasItem -Restore $Restore -Kind 'RegistryKeys' -Item $item) { return }
    (Get-LunqRestoreCategory -Restore $Restore -Id $Category).RegistryKeys.Add($item)
}

function Test-LunqRestoreHasItem {
    # Есть ли такая запись в любой категории данных для отката.
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)]$Item)
    $key = Get-LunqRestoreItemKey -Kind $Kind -Item $Item
    foreach ($category in $Restore.Categories) {
        foreach ($existing in $category.$Kind) { if ((Get-LunqRestoreItemKey -Kind $Kind -Item $existing) -eq $key) { return $true } }
    }
    return $false
}

function Get-LunqRestoreItemKey {
    # По чему узнаётся одна и та же запись: при слиянии старая запись важнее новой, ведь в ней то,
    # что было до первого запуска LunqDebloater.
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)]$Item)
    switch ($Kind) {
        'Registry' { return ('{0}|{1}|{2}' -f $Item.Hive, $Item.Path, [string](Get-ConfigValue $Item 'Name')).ToLowerInvariant() }
        'RegistryKeys' { return ('{0}|{1}' -f $Item.Hive, $Item.Path).ToLowerInvariant() }
        default { return ([string]$Item.Name).ToLowerInvariant() }
    }
}

function Read-LunqRestoreData {
    # Данные для отката из файла. Нет файла: $null.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $text -or -not $text.Trim()) { throw (Get-LunqText 'Restore.EmptyFile') }
        $json = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        # Файл испорчен (например, запись оборвалась). Он откладывается рядом, чтобы его можно было
        # разобрать вручную, а данные берутся из прошлой версии файла, если она есть. Прошлая версия
        # переносится, а не копируется: если испорчена и она, чтение на ней и закончится.
        $corrupt = '{0}.corrupt-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $Path -Destination $corrupt -Force
        Write-Warning (Get-LunqText 'Restore.Corrupt' $Path $_.Exception.Message $corrupt)
        $backup = "$Path.bak"
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { return $null }
        Move-Item -LiteralPath $backup -Destination $Path -Force
        Write-Warning (Get-LunqText 'Restore.FromBackup' $backup)
        return (Read-LunqRestoreData -Path $Path)
    }
    if ([string](Get-ConfigValue $json 'Kind') -ne 'LunqDebloaterRestore') { throw (Get-LunqText 'Restore.NotRestoreFile' $Path) }
    if ([int](Get-ConfigValue $json 'FormatVersion') -gt 1) { throw (Get-LunqText 'Restore.NewerFormat' $Path (Get-ConfigValue $json 'LunqVersion')) }
    $source = [string](Get-ConfigValue $json 'Source')
    if ($source -ne 'Online') { $source = 'Image' }
    $data = New-LunqRestoreData -Source $source
    # Записи без нужных полей (файл правили вручную) пропускаются: из-за одной такой записи не
    # должен обрываться весь откат.
    $bad = 0
    foreach ($raw in (Get-ConfigList $json 'Categories')) {
        if (-not [string](Get-ConfigValue $raw 'Id')) { $bad++; continue }
        $category = New-LunqRestoreCategory -Id ([string]$raw.Id) -Name (Get-ConfigValue $raw 'Name')
        foreach ($kind in @($script:RestoreKinds + 'Registry', 'RegistryKeys')) {
            foreach ($item in (Get-ConfigList $raw $kind)) {
                if (Test-LunqRestoreItem -Kind $kind -Item $item) { $category.$kind.Add($item) } else { $bad++ }
            }
        }
        $data.Categories.Add($category)
    }
    if ($bad -gt 0) { Write-Warning (Get-LunqText 'Restore.BadItems' $Path $bad) }
    return $data
}

function Test-LunqRestoreItem {
    # Есть ли у записи отката поля, без которых её не вернуть.
    param([Parameter(Mandatory)][string]$Kind, $Item)
    if ($Item -isnot [Management.Automation.PSCustomObject]) { return $false }
    $fields = switch ($Kind) {
        'Registry' { @('Hive', 'Path') }
        'RegistryKeys' { @('Hive', 'Path', 'Export') }
        default { @('Name') }
    }
    foreach ($field in $fields) { if (-not [string](Get-ConfigValue $Item $field)) { return $false } }
    if ($Kind -eq 'Registry' -or $Kind -eq 'RegistryKeys') { return (@('SOFTWARE', 'SYSTEM', 'DefaultUser', 'CurrentUser') -contains [string]$Item.Hive) }
    return $true
}

function Save-LunqRestoreData {
    # Записывает данные для отката. С -Merge дописывает к тому, что уже есть в файле: то, что там
    # уже записано, не заменяется.
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)][string]$Path, [switch]$Merge)
    $all = New-LunqRestoreData -Source $Restore.Source
    if ($Merge) {
        $old = Read-LunqRestoreData -Path $Path
        if ($old) { $all = $old }
    }
    foreach ($category in $Restore.Categories) {
        $target = @($all.Categories | Where-Object { $_.Id -eq $category.Id }) | Select-Object -First 1
        if (-not $target) {
            $target = New-LunqRestoreCategory -Id $category.Id -Name $category.Name
            $all.Categories.Add($target)
        }
        foreach ($kind in @($script:RestoreKinds + 'Registry', 'RegistryKeys')) {
            # Значения и ключи реестра сверяются со всеми категориями: одно значение может писать
            # и другая категория, и его исходное состояние уже записано там.
            $scope = if ($kind -eq 'Registry' -or $kind -eq 'RegistryKeys') { @($all.Categories) } else { @($target) }
            $known = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($c in $scope) { foreach ($existing in $c.$kind) { [void]$known.Add((Get-LunqRestoreItemKey -Kind $kind -Item $existing)) } }
            foreach ($item in $category.$kind) {
                if ($known.Add((Get-LunqRestoreItemKey -Kind $kind -Item $item))) { $target.$kind.Add($item) }
            }
        }
    }
    $categories = @($all.Categories | Where-Object { Test-LunqRestoreCategoryHasItems $_ })
    if ($categories.Count -eq 0) {
        foreach ($file in @($Path, "$Path.bak")) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
        return
    }
    $out = [ordered]@{
        Kind          = 'LunqDebloaterRestore'
        FormatVersion = 1
        LunqVersion   = Get-LunqVersion
        Updated       = Get-Date -Format 'yyyy-MM-dd HH:mm'
        Source        = $all.Source
        Categories    = @($categories | ForEach-Object {
                $c = $_
                $o = [ordered]@{ Id = $c.Id; Name = $c.Name }
                foreach ($kind in @($script:RestoreKinds + 'Registry', 'RegistryKeys')) { if ($c.$kind.Count -gt 0) { $o[$kind] = @($c.$kind) } }
                $o
            })
    }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    # Сначала во временный файл, потом подмена: если запись оборвётся, прежний файл останется целым,
    # а его прошлая версия сохраняется в .bak на случай, если испорчен окажется он сам.
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, ($out | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, "$Path.bak") }
    else { [IO.File]::Move($temp, $Path) }
}

function Test-LunqRestoreCategoryHasItems {
    param([Parameter(Mandatory)]$Category)
    foreach ($kind in @($script:RestoreKinds + 'Registry', 'RegistryKeys')) { if ($Category.$kind.Count -gt 0) { return $true } }
    return $false
}

function ConvertTo-LunqRestoreProfile {
    # Данные для отката в виде профиля: категории можно выбрать тем же списком, что и в профиле.
    param([Parameter(Mandatory)]$Restore)
    $categories = foreach ($c in $Restore.Categories) {
        $name = Get-LunqLocalized $c.Name
        if (-not $name) { $name = $c.Id }
        [pscustomobject]@{
            Id           = $c.Id
            Name         = [string]$name
            Description  = ''
            Enabled      = $true
            Appx         = @($c.Appx | ForEach-Object { $_.Name })
            Capabilities = @($c.Capabilities | ForEach-Object { $_.Name })
            Features     = @($c.Features | ForEach-Object { $_.Name })
            Packages     = @($c.Packages | ForEach-Object { $_.Name })
            Uninstall    = @($c.Uninstall | ForEach-Object { $_.Name })
            Registry     = @(@($c.Registry) + @($c.RegistryKeys))
        }
    }
    return [pscustomobject]@{ Name = 'Restore'; Categories = @($categories) }
}

function ConvertTo-LunqImportText {
    # Текст .reg из образа или с этой Windows для reg import сюда: кусты образа подключались под
    # своими именами (LUNQ_SOFTWARE), а на этой Windows это HKLM\SOFTWARE. Профиль Default при
    # откате подключается под тем же именем, что и при сборке, поэтому его путь не меняется.
    param([Parameter(Mandatory)][string]$Text, [switch]$ToCurrentUser)
    $text = $Text -replace '(?im)^(\[-?)HKEY_LOCAL_MACHINE\\LUNQ_SOFTWARE(\\|\])', '$1HKEY_LOCAL_MACHINE\SOFTWARE$2'
    $text = $text -replace '(?im)^(\[-?)HKEY_LOCAL_MACHINE\\LUNQ_SYSTEM(\\|\])', '$1HKEY_LOCAL_MACHINE\SYSTEM$2'
    if ($ToCurrentUser) { $text = $text -replace '(?im)^(\[-?)HKEY_LOCAL_MACHINE\\LUNQ_NTUSER(\\|\])', '$1HKEY_CURRENT_USER$2' }
    return $text
}

function Import-LunqRegistryText {
    # reg import текста .reg. Возвращает $true, если получилось.
    param([Parameter(Mandatory)][string]$Text)
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'LunqDebloater\RegImport'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ('{0}.reg' -f [guid]::NewGuid().ToString('N'))
    try {
        # reg import понимает UTF-16 с меткой BOM, как его и выгружает reg export.
        [IO.File]::WriteAllText($file, $Text, [Text.Encoding]::Unicode)
        return ((Invoke-Native reg.exe @('import', $file)) -eq 0)
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Add-LunqAppxBack {
    # Возвращает приложение: регистрирует его текущему пользователю, если файлы пакета ещё на диске,
    # и снова подготавливает (provisioning) для новых пользователей: -Online снимал и то, и другое.
    # $true: приложение вернулось и новым пользователям, $false: только текущему. Обёртка для тестов.
    param([Parameter(Mandatory)][string]$PackageFamilyName)
    Add-AppxPackage -RegisterByFamilyName -MainPackage $PackageFamilyName -ErrorAction Stop
    $package = @(Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $PackageFamilyName }) | Select-Object -First 1
    if (-not $package -or -not $package.InstallLocation) { return $false }
    try {
        Add-AppxProvisionedPackage -Online -FolderPath $package.InstallLocation -SkipLicense -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Verbose $_.Exception.Message
        return $false
    }
}

function Restore-LunqCategory {
    # Возвращает одну категорию. Возвращает результат и оставляет в категории только то, что
    # вернуть не удалось: оно останется в файле для следующей попытки.
    param([Parameter(Mandatory)]$Category)

    $title = Get-LunqLocalized $Category.Name
    if (-not $title) { $title = $Category.Id }
    $result = New-LunqResult $title 'Restore'
    $storeLinks = New-Object System.Collections.Generic.List[string]

    $keepAppx = New-Object System.Collections.Generic.List[psobject]
    foreach ($app in $Category.Appx) {
        $family = [string](Get-ConfigValue $app 'PackageFamilyName')
        Write-Info (Get-LunqText 'Restore.Appx' $app.Name)
        $back = $false
        $everyone = $false
        if ($family) {
            try { $everyone = [bool](Add-LunqAppxBack -PackageFamilyName $family); $back = $true }
            catch { Write-Verbose $_.Exception.Message }   # файлов пакета на диске нет: остаётся Microsoft Store
        }
        if ($back) {
            $result.Done.Add($app.Name)
            # Запись всё равно убирается: повтор вернул бы его опять только этому пользователю.
            if (-not $everyone) { Write-Warning (Get-LunqText 'Restore.AppxOnlyYou' $app.Name "ms-windows-store://pdp/?PFN=$family") }
        }
        else {
            # Приложение из образа удалено вместе с файлами. Microsoft Store находит его по имени семейства.
            if ($family) { $storeLinks.Add("ms-windows-store://pdp/?PFN=$family") }
            $result.Skipped.Add($app.Name)
            $keepAppx.Add($app)
        }
    }

    $keepCaps = New-Object System.Collections.Generic.List[psobject]
    foreach ($cap in $Category.Capabilities) {
        Write-Info (Get-LunqText 'Restore.Capability' $cap.Name)
        try {
            # Компонент скачивается из Центра обновления Windows: нужен интернет.
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            $result.Done.Add($cap.Name)
        }
        catch {
            Write-Warning (Get-LunqText 'Restore.Failed' $cap.Name $_.Exception.Message)
            $result.Failed.Add($cap.Name)
            $keepCaps.Add($cap)
        }
    }

    $keepFeatures = New-Object System.Collections.Generic.List[psobject]
    foreach ($feature in $Category.Features) {
        Write-Info (Get-LunqText 'Restore.Feature' $feature.Name)
        try {
            # -All включает и родительские функции, без которых эта не включится.
            Enable-WindowsOptionalFeature -Online -FeatureName $feature.Name -All -NoRestart -ErrorAction Stop | Out-Null
            $result.Done.Add($feature.Name)
        }
        catch {
            Write-Warning (Get-LunqText 'Restore.Failed' $feature.Name $_.Exception.Message)
            $result.Failed.Add($feature.Name)
            $keepFeatures.Add($feature)
        }
    }

    # Системные пакеты штатно не возвращаются: только переустановкой Windows.
    foreach ($pkg in $Category.Packages) { $result.Skipped.Add($pkg.Name) }

    $keepUninstall = New-Object System.Collections.Generic.List[psobject]
    foreach ($program in $Category.Uninstall) {
        # Программа, которую эта версия LunqDebloater не знает (файл от более новой версии): её не
        # вернуть, но и остальной откат из-за неё не обрывается.
        if ((Get-LunqUninstallNames) -notcontains $program.Name) {
            Write-Warning (Get-LunqText 'Restore.UnknownProgram' $program.Name)
            $result.Failed.Add([string]$program.Name)
            $keepUninstall.Add($program)
            continue
        }
        $programTitle = Get-LunqUninstallTitle $program.Name
        Write-Info (Get-LunqText 'Restore.Uninstall' $programTitle)
        # Программу ставит обратно тот же скрипт, что удалял. Ему нужен интернет.
        $code = Invoke-LunqUninstaller -Name $program.Name -Action Restore
        if ($code -eq 0) { $result.Done.Add($programTitle) }
        else {
            Write-Warning (Get-LunqText 'Restore.Failed' $programTitle (Get-LunqText 'Restore.ExitCode' $code))
            $result.Failed.Add($programTitle)
            $keepUninstall.Add($program)
        }
    }

    $keepRegistry = New-Object System.Collections.Generic.List[psobject]
    # Записи текущего пользователя по тому же ключу, что у профиля Default: «DefaultUser|путь|имя».
    $currentUser = @($Category.Registry | Where-Object { $_.Hive -eq 'CurrentUser' } |
            ForEach-Object { ('DefaultUser|{0}|{1}' -f $_.Path, [string](Get-ConfigValue $_ 'Name')).ToLowerInvariant() })
    foreach ($entry in $Category.Registry) {
        $roots = Get-LunqRegistryRoots -Hive ([string]$entry.Hive) -Online
        # Данные из образа знают только профиль Default, а текущий пользователь создан из него
        # и получил те же значения. Своё значение текущего пользователя записывает только -Online.
        if ($entry.Hive -eq 'DefaultUser' -and $currentUser -contains (Get-LunqRestoreItemKey -Kind Registry -Item $entry)) { $roots = @($roots | Where-Object { $_ -ne 'HKCU' }) }
        $statuses = @(foreach ($root in $roots) { Invoke-RegistryEntry -Entry $entry -Root $root })
        $label = '{0}\{1}' -f $entry.Hive, $entry.Path
        $name = [string](Get-ConfigValue $entry 'Name')
        if ($name) { $label = "$label\$name" }
        if ($statuses -contains 'Failed') { $result.Failed.Add($label); $keepRegistry.Add($entry) }
        else { $result.Done.Add($label) }
    }

    $keepKeys = New-Object System.Collections.Generic.List[psobject]
    foreach ($key in $Category.RegistryKeys) {
        $label = '{0}\{1}' -f $key.Hive, $key.Path
        $ok = Import-LunqRegistryText -Text (ConvertTo-LunqImportText -Text $key.Export)
        # Ключ профиля Default из образа достаётся и текущему пользователю: он создан из этого профиля.
        # Ключ, удалённый -Online, у текущего пользователя возвращается своей записью CurrentUser.
        if ($ok -and $key.Hive -eq 'DefaultUser' -and -not (Get-ConfigValue $key 'NoCurrentUser')) { $ok = Import-LunqRegistryText -Text (ConvertTo-LunqImportText -Text $key.Export -ToCurrentUser) }
        if ($ok) { $result.Done.Add($label) }
        else { $result.Failed.Add($label); $keepKeys.Add($key) }
    }

    $Category.Appx.Clear(); foreach ($i in $keepAppx) { $Category.Appx.Add($i) }
    $Category.Capabilities.Clear(); foreach ($i in $keepCaps) { $Category.Capabilities.Add($i) }
    $Category.Features.Clear(); foreach ($i in $keepFeatures) { $Category.Features.Add($i) }
    $Category.Uninstall.Clear(); foreach ($i in $keepUninstall) { $Category.Uninstall.Add($i) }
    $Category.Registry.Clear(); foreach ($i in $keepRegistry) { $Category.Registry.Add($i) }
    $Category.RegistryKeys.Clear(); foreach ($i in $keepKeys) { $Category.RegistryKeys.Add($i) }
    $result | Add-Member -NotePropertyName StoreLinks -NotePropertyValue @($storeLinks)
    return $result
}

function Invoke-LunqRestore {
    # Откат выбранных категорий на этой Windows. Ids: Id категорий из файла для отката.
    # Что не вернулось, остаётся в файле. Возвращает результаты по категориям.
    param([Parameter(Mandatory)]$Restore, [Parameter(Mandatory)][string[]]$Ids, [Parameter(Mandatory)][string]$Path)
    $results = @()
    $completed = $false
    try {
        # Профиль Default подключается под тем же именем, что и при сборке и при -Online.
        Mount-OfflineHives -MountPath (Get-LunqSystemDrive) -Hives DefaultUser
        $selected = @($Restore.Categories | Where-Object { $Ids -contains $_.Id })
        Initialize-LunqSteps -Total $selected.Count
        foreach ($category in $selected) {
            $name = Get-LunqLocalized $category.Name
            if (-not $name) { $name = $category.Id }
            Write-Step (Get-LunqText 'Restore.Category' $name)
            Write-LunqDismMarker ('restore: {0}' -f $category.Id)
            $results += Restore-LunqCategory -Category $category
        }
        $completed = $true
    }
    finally {
        # Вернувшееся убирается из файла и тогда, когда откат прервался на середине. Файл пишется до
        # выгрузки кустов: куст, который не выгрузился, не должен помешать его записать.
        try { Save-LunqRestoreData -Restore $Restore -Path $Path }
        finally { Dismount-OfflineHives -Strict:$completed }
    }
    return , $results
}

function Write-LunqRestoreReport {
    # Итог отката: что вернулось, что не удалось и что осталось вернуть вручную через Microsoft Store.
    param([object[]]$Results = @())
    Write-Section (Get-LunqText 'Restore.ReportSection')
    foreach ($r in $Results) {
        $color = if ($r.Failed.Count -gt 0) { 'Yellow' } else { 'Gray' }
        Write-Host ('    ' + (Get-LunqText 'Restore.ReportLine' $r.Title $r.Done.Count $r.Failed.Count)) -ForegroundColor $color
        if ($r.Failed.Count -gt 0) { Write-Host ('        ' + (Get-LunqText 'Report.Failed' ($r.Failed -join ', '))) -ForegroundColor Yellow }
        if ($r.Skipped.Count -gt 0) { Write-Host ('        ' + (Get-LunqText 'Restore.ReportManual' ($r.Skipped -join ', '))) -ForegroundColor DarkGray }
    }
    $links = @($Results | ForEach-Object { $_.StoreLinks } | Where-Object { $_ })
    if ($links.Count -gt 0) {
        Write-Info ''
        Write-Info (Get-LunqText 'Restore.StoreLinks')
        foreach ($link in $links) { Write-Info "  $link" }
    }
    Write-Info ''
    Write-Info (Get-LunqText 'Restore.Reboot')
}
