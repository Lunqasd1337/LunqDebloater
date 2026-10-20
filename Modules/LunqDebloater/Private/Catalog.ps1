# Свежие обновления из каталога Центра обновления Майкрософт (catalog.update.microsoft.com).
# У каталога нет официального API, поэтому разбирается та же страница поиска, что видит браузер,
# и окно скачивания. Если разметка изменится, скрипт скажет об этом и предложит скачать вручную.

$script:CatalogBase = 'https://www.catalog.update.microsoft.com'
# Серверы, с которых каталог отдаёт файлы. Ссылка на любой другой адрес значит, что окно скачивания
# подменено или изменилось, и такой файл не скачивается.
$script:CatalogHosts = @('windowsupdate.com', 'delivery.mp.microsoft.com')
# Сколько раз пробовать скачать файл и сколько секунд ждать между попытками: накопительное весит
# 3-4 ГБ, и один обрыв сети не должен останавливать запуск без вопросов.
$script:DownloadAttempts = 3
$script:DownloadRetrySeconds = 15

function Invoke-LunqWebRequest {
    # Запрос к сайту: текст ответа или файл (-OutFile). Обёртка, чтобы тесты могли её подменить.
    param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'Get', $Body, [string]$OutFile)
    # Windows PowerShell 5.1 по умолчанию не включает TLS 1.2, а без него каталог не отвечает.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Индикатор хода в 5.1 замедляет скачивание больших файлов в разы.
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $params = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($null -ne $Body) { $params.Body = $Body; $params.ContentType = 'application/x-www-form-urlencoded' }
        if ($OutFile) {
            Invoke-WebRequest @params -OutFile $OutFile
            return
        }
        return [string](Invoke-WebRequest @params).Content
    }
    finally { $ProgressPreference = $oldProgress }
}

function Get-LunqCatalogTargets {
    # Что искать в каталоге для выпуска (например, 26H2) и архитектуры образа. Include: все эти
    # слова должны быть в названии, Exclude: ни одного из них. Required: без него скачивание
    # не имеет смысла (накопительное обновление).
    param([Parameter(Mandatory)][string]$Release, [Parameter(Mandatory)][string]$Architecture, [switch]$WithDynamic)
    $arch = if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
    $targets = @(
        [pscustomobject]@{
            Kind = 'Update'; Required = $true; Query = "Cumulative Update Windows 11 $Release $arch"
            Include = @('Cumulative Update', 'Windows 11'); Exclude = @('Preview', 'Dynamic', '.NET', 'Framework', 'Server', 'Hotpatch')
        },
        [pscustomobject]@{
            Kind = 'DotNet'; Required = $false; Query = "Cumulative Update .NET Framework Windows 11 $Release $arch"
            Include = @('Cumulative Update', '.NET Framework', 'Windows 11'); Exclude = @('Preview', 'Server')
        }
    )
    if ($WithDynamic) {
        $targets += [pscustomobject]@{
            Kind = 'SafeOS'; Required = $false; Query = "Safe OS Dynamic Update Windows 11 $Release $arch"
            Include = @('Safe OS Dynamic Update', 'Windows 11'); Exclude = @('Server')
        }
        $targets += [pscustomobject]@{
            Kind = 'Setup'; Required = $false; Query = "Setup Dynamic Update Windows 11 $Release $arch"
            Include = @('Setup Dynamic Update', 'Windows 11'); Exclude = @('Server')
        }
    }
    foreach ($t in $targets) { $t | Add-Member -NotePropertyName Release -NotePropertyValue $Release; $t | Add-Member -NotePropertyName Arch -NotePropertyValue $arch }
    return , $targets
}

function ConvertFrom-LunqCatalogText {
    # Текст ячейки без тегов и лишних пробелов.
    param([string]$Html)
    $text = [regex]::Replace([string]$Html, '<[^>]+>', ' ')
    $text = [Net.WebUtility]::HtmlDecode($text)
    return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

function ConvertFrom-LunqCatalogSearch {
    # Строки таблицы результатов поиска: Id, Title, Products, Classification, Date, Version, Size.
    # Строка результата это <tr id="<guid>_R<n>">, ячейки идут в том же порядке, что и столбцы на странице.
    param([AllowEmptyString()][string]$Html)
    $rows = New-Object System.Collections.Generic.List[object]
    $options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline'
    foreach ($row in [regex]::Matches([string]$Html, '<tr[^>]*\bid\s*=\s*["'']?([0-9a-f]{8}-[0-9a-f-]{27})_R\d+["'']?[^>]*>(.*?)</tr>', $options)) {
        $cells = @([regex]::Matches($row.Groups[2].Value, '<td[^>]*>(.*?)</td>', $options) | ForEach-Object { $_.Groups[1].Value })
        if ($cells.Count -lt 7) { continue }
        $date = [datetime]::MinValue
        $dateText = ConvertFrom-LunqCatalogText $cells[4]
        $null = [datetime]::TryParseExact($dateText, 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)
        # Размер в байтах лежит во втором, скрытом <span> ячейки размера.
        $size = [long]0
        if ($cells[6] -match '(?is)originalSize[^>]*>\s*(\d+)\s*<') { $size = [long]$Matches[1] }
        $rows.Add([pscustomobject]@{
                Id             = $row.Groups[1].Value
                Title          = ConvertFrom-LunqCatalogText $cells[1]
                Products       = ConvertFrom-LunqCatalogText $cells[2]
                Classification = ConvertFrom-LunqCatalogText $cells[3]
                Date           = $date
                Version        = ConvertFrom-LunqCatalogText $cells[5]
                Size           = $size
            })
    }
    return , $rows.ToArray()
}

function ConvertFrom-LunqCatalogDownload {
    # Ссылки на файлы из окна скачивания и их SHA-1 (в окне он в base64, здесь в hex).
    param([AllowEmptyString()][string]$Text)
    $digests = @{}
    foreach ($m in [regex]::Matches([string]$Text, "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.digest\s*=\s*'([^']*)'")) {
        try { $digests["$($m.Groups[1].Value)_$($m.Groups[2].Value)"] = ([BitConverter]::ToString([Convert]::FromBase64String($m.Groups[3].Value)) -replace '-', '').ToLowerInvariant() }
        catch { }   # сумма в неожиданном виде: файл проверится по имени
    }
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches([string]$Text, "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.url\s*=\s*'([^']*)'")) {
        $url = $m.Groups[3].Value
        if (@($files | Where-Object { $_.Url -eq $url }).Count -gt 0) { continue }
        $sha1 = $digests["$($m.Groups[1].Value)_$($m.Groups[2].Value)"]
        $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath)
        # В имени файла из каталога тоже есть его SHA-1: windows11.0-kb...-x64_<40 hex>.msu.
        if (-not $sha1 -and $name -match '_([0-9a-f]{40})\.(msu|cab)$') { $sha1 = $Matches[1] }
        $files.Add([pscustomobject]@{ Url = $url; Name = $name; Sha1 = $sha1 })
    }
    return , $files.ToArray()
}

function ConvertTo-LunqCatalogUrl {
    # Ссылка на файл, если она ведёт на серверы загрузки Microsoft, иначе $null. Старые ссылки на
    # download.windowsupdate.com бывают по http: они переводятся на https, его эти серверы тоже отдают.
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if (@('http', 'https') -notcontains $uri.Scheme) { return $null }
    $hostName = $uri.Host.ToLowerInvariant()
    if (@($script:CatalogHosts | Where-Object { $hostName -eq $_ -or $hostName.EndsWith('.' + $_) }).Count -eq 0) { return $null }
    $builder = New-Object UriBuilder $uri
    $builder.Scheme = 'https'
    $builder.Port = -1
    return $builder.Uri.AbsoluteUri
}

function Test-LunqCatalogTitle {
    # Подходит ли название обновления к цели: все слова Include, выпуск, архитектура и ни одного Exclude.
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)]$Target)
    foreach ($word in $Target.Include) { if ($Title.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false } }
    foreach ($word in $Target.Exclude) { if ($Title.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false } }
    if ($Title -notmatch ('(?i)\b' + [regex]::Escape($Target.Release) + '\b')) { return $false }
    # «x64» не встречается в «arm64», а «arm64» в названиях пишут и как «ARM64».
    if ($Title -notmatch ('(?i)\b' + [regex]::Escape($Target.Arch) + '\b|\b' + [regex]::Escape($Target.Arch) + '-based')) { return $false }
    return $true
}

function Select-LunqCatalogUpdate {
    # Самое свежее подходящее обновление: по дате в каталоге, затем по ревизии сборки в названии.
    param($Rows, [Parameter(Mandatory)]$Target)
    $matching = @(@($Rows) | Where-Object { $_ -and (Test-LunqCatalogTitle -Title $_.Title -Target $Target) })
    if ($matching.Count -eq 0) { return $null }
    return @($matching | Sort-Object @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = {
                if ($_.Title -match '\(\d{5}\.(\d+)\)') { [int]$Matches[1] } else { 0 }
            }; Descending = $true
        }) | Select-Object -First 1
}

function Get-LunqCatalogFolder {
    # Куда класть скачанное: обычные обновления в корень, Dynamic Update в подпапки, как в Config\Updates.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'SafeOS' { return (Join-Path $Root 'SafeOS') }
        'Setup' { return (Join-Path $Root 'Setup') }
        default { return $Root }
    }
}

function Test-LunqFileSha1 {
    # Каталог Microsoft даёт для файлов только SHA-1: другой суммы сверить не с чем. Это проверка
    # целостности скачанного файла, а подпись Microsoft на .msu проверяет DISM, на Setup Dynamic
    # Update сам скрипт перед распаковкой. Без суммы файл проверенным не считается.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'The catalog publishes SHA-1 only')]
    param([Parameter(Mandatory)][string]$Path, [string]$Sha1)
    if (-not $Sha1) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash -eq $Sha1.ToUpperInvariant())
}

function Save-LunqCatalogUpdates {
    # Находит в каталоге свежие обновления для выпуска и архитектуры образа и скачивает их в
    # Destination: накопительное и .NET в корень, Safe OS и Setup Dynamic Update в подпапки.
    # Уже скачанные файлы с верной суммой не скачиваются снова, а старые удаляются.
    # Возвращает найденные обновления (Kind, Title, Date, Files).
    param(
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$WithDynamic
    )
    $kindKeys = @{ Update = 'Catalog.KindUpdate'; DotNet = 'Catalog.KindDotNet'; SafeOS = 'Catalog.KindSafeOS'; Setup = 'Catalog.KindSetup' }
    # Поиск отдаёт одну страницу (25 строк), и свежее обновление могло на неё не попасть. Поэтому
    # сначала ищутся обновления этого месяца (их названия начинаются с 2026-10), потом прошлого
    # (в начале месяца выходят только предварительные), и только потом без месяца.
    $now = Get-Date
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $months = @($now.ToString('yyyy-MM', $culture), $now.AddMonths(-1).ToString('yyyy-MM', $culture), '')
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($target in (Get-LunqCatalogTargets -Release $Release -Architecture $Architecture -WithDynamic:$WithDynamic)) {
        $what = Get-LunqText $kindKeys[$target.Kind]
        Write-Info (Get-LunqText 'Catalog.Searching' $what)
        $pick = $null
        foreach ($month in $months) {
            $query = ('{0} {1}' -f $month, $target.Query).Trim()
            try {
                $html = Invoke-LunqWebRequest -Uri ('{0}/Search.aspx?q={1}' -f $script:CatalogBase, [uri]::EscapeDataString($query))
            }
            catch { throw (Get-LunqText 'Catalog.Unreachable' $_.Exception.Message) }
            $pick = Select-LunqCatalogUpdate -Rows (ConvertFrom-LunqCatalogSearch $html) -Target $target
            if ($pick) { break }
        }
        if (-not $pick) {
            if ($target.Required) { throw (Get-LunqText 'Catalog.NothingFound' $what $Release $target.Arch) }
            Write-Warning (Get-LunqText 'Catalog.NotFoundOptional' $what)
            continue
        }
        Write-Info ('  ' + (Get-LunqText 'Catalog.Found' $pick.Title ($pick.Date.ToString('yyyy-MM-dd'))))
        $post = '[{{"size":0,"languages":"","uidInfo":"{0}","updateID":"{0}"}}]' -f $pick.Id
        $dialog = Invoke-LunqWebRequest -Uri "$script:CatalogBase/DownloadDialog.aspx" -Method Post -Body @{ updateIDs = $post }
        # Список приходит одним объектом: в конвейер он идёт из переменной, тогда Where-Object видит каждый файл.
        $links = ConvertFrom-LunqCatalogDownload $dialog
        $files = @($links | Where-Object { $_.Name -match '(?i)\.(msu|cab)$' })
        if ($files.Count -eq 0) {
            if ($target.Required) { throw (Get-LunqText 'Catalog.NoLinks' $pick.Title) }
            Write-Warning (Get-LunqText 'Catalog.NoLinks' $pick.Title)
            continue
        }
        # Проверяется до скачивания: без суммы файл нечем проверить, а чужая ссылка значит подмену.
        foreach ($file in $files) {
            if (-not $file.Sha1) { throw (Get-LunqText 'Catalog.NoHash' $file.Name) }
            $url = ConvertTo-LunqCatalogUrl -Url $file.Url
            if (-not $url) { throw (Get-LunqText 'Catalog.BadUrl' $file.Name $file.Url) }
            $file.Url = $url
        }
        $found.Add([pscustomobject]@{ Kind = $target.Kind; Title = $pick.Title; Date = $pick.Date; Files = $files })
    }

    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($update in $found) {
        $folder = Get-LunqCatalogFolder -Root $Destination -Kind $update.Kind
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        foreach ($file in $update.Files) {
            $path = Join-Path $folder $file.Name
            $keep.Add($path)
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Test-LunqFileSha1 -Path $path -Sha1 $file.Sha1)) {
                Write-Info ('  ' + (Get-LunqText 'Catalog.AlreadyHere' $file.Name))
                continue
            }
            Write-Info ('  ' + (Get-LunqText 'Catalog.Downloading' $file.Name))
            Save-LunqCatalogFile -Url $file.Url -Path $path -Sha1 $file.Sha1
        }
    }
    # Обновления прошлого месяца больше не нужны: накопительное включает всё предыдущее. Убираются
    # только папки того, что скачано сейчас: Dynamic Update, которые в этот раз не искали или не
    # нашли, остаются от прошлого раза.
    $folders = @($found | ForEach-Object { Get-LunqCatalogFolder -Root $Destination -Kind $_.Kind } | Select-Object -Unique)
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($old in @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Extension -in '.msu', '.cab', '.partial' -and $keep -notcontains $_.FullName })) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return , $found.ToArray()
}

function Save-LunqCatalogFile {
    # Скачивает файл с проверкой SHA-1 и повторами. Сначала во временный файл: оборванная
    # загрузка не выглядит готовым обновлением. Неверная сумма тоже повод для повтора: файл
    # мог прийти испорченным.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sha1)
    $name = Split-Path $Path -Leaf
    $partial = "$Path.partial"
    for ($attempt = 1; $attempt -le $script:DownloadAttempts; $attempt++) {
        $reason = $null
        try {
            Invoke-LunqWebRequest -Uri $Url -OutFile $partial
            if (Test-LunqFileSha1 -Path $partial -Sha1 $Sha1) {
                Move-Item -LiteralPath $partial -Destination $Path -Force
                return
            }
        }
        catch { $reason = $_.Exception.Message }
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        if ($attempt -ge $script:DownloadAttempts) {
            if ($reason) { throw (Get-LunqText 'Catalog.DownloadFailed' $name $reason) }
            throw (Get-LunqText 'Catalog.BadHash' $name)
        }
        if (-not $reason) { $reason = Get-LunqText 'Catalog.RetryBadHash' }
        Write-Warning (Get-LunqText 'Catalog.Retry' $name $reason ($attempt + 1) $script:DownloadAttempts)
        Start-Sleep -Seconds $script:DownloadRetrySeconds
    }
}

function Get-LunqCatalogRelease {
    # Выпуск для поиска в каталоге (26H2) по номеру сборки. Неизвестная сборка: $null.
    param([int]$Build)
    $name = Get-WindowsReleaseName -Build $Build
    if (-not $name) { return $null }
    return ($name -split ' ')[-1]
}
