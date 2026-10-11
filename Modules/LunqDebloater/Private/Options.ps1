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
                Write-Warning (Get-LunqText 'Options.NoSuchNumber' $token)
                continue
            }
            $option = $numbered[$parsed - 1]
            # Действие выполняется после того, как применены остальные номера из ответа.
            if ($option.Action) {
                $action = $option.Key
                continue
            }
            if ($option.Parent -and -not (Test-LunqOption -Options $Options -Key $option.Parent)) {
                Write-Warning (Get-LunqText 'Options.NeedsParent' $parsed ($numbers[$option.Parent]))
                continue
            }
            $option.Enabled = -not $option.Enabled
        }
        if ($action) { return $action }
    }
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
        Write-Warning (Get-LunqText 'Options.FolderNotFound' $path)
        return $null
    }
    return (Resolve-Path -LiteralPath $path).Path
}
