function New-LunqOption {
    # Пункт сводки «Что войдёт в образ». Parent: Key пункта, без которого этот не имеет смысла.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Enabled = $true,
        [bool]$Available = $true,
        [string[]]$Details = @(),
        [string]$Parent
    )
    return [pscustomobject]@{
        Key = $Key; Name = $Name; Enabled = $Enabled; Available = $Available
        Details = @($Details); Parent = $Parent
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
            $mark = if ($on) { '[x]' } else { '[ ]' }
            $color = if ($on) { 'Green' } else { 'DarkGray' }
            Write-Host "$indent$mark " -NoNewline -ForegroundColor $color
            if ($option.Available) { Write-Host $option.Name } else { Write-Host $option.Name -ForegroundColor DarkGray }
            foreach ($line in $option.Details) { Write-Host "           $indent$line" -ForegroundColor DarkGray }
        }
        Write-Info ''
        if ($numbered.Count -eq 0) { return }
        $answer = Read-Host '    Номера пунктов, чтобы включить или выключить их (через пробел), или Enter, чтобы продолжить'
        if (-not $answer -or -not $answer.Trim()) { return }
        foreach ($token in ($answer -split '[\s,;]+' | Where-Object { $_ })) {
            $parsed = 0
            if (-not ([int]::TryParse($token, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $numbered.Count)) {
                Write-Warning "Номера $token нет в списке."
                continue
            }
            $option = $numbered[$parsed - 1]
            if ($option.Parent -and -not (Test-LunqOption -Options $Options -Key $option.Parent)) {
                Write-Warning "Пункт $parsed работает только вместе с пунктом $($numbers[$option.Parent]). Сначала включите его."
                continue
            }
            $option.Enabled = -not $option.Enabled
        }
    }
}
