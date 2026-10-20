# Ежемесячная пересборка по расписанию убрана в 1.14.0. Её задание шло от SYSTEM и запускало свою
# копию программы в Program Files, поэтому после обновления оно продолжало бы работать старой
# версией. Здесь осталась только уборка этих заданий и копий: её делает каждый запуск.

# Папка планировщика, в которую пересборка клала свои задания. Другие задания там не создавались.
$script:ScheduleTaskFolder = '\LunqDebloater\'

function Get-LunqScheduleRoot {
    # Папка копий программы для заданий пересборки.
    $programFiles = $env:ProgramFiles
    if (-not $programFiles) { $programFiles = 'C:\Program Files' }
    return (Join-Path $programFiles 'LunqDebloater-Schedule')
}

function Get-LunqScheduleTasks {
    # Задания пересборки в планировщике: имена вида LunqDebloater\Win11_Lunq-1a2b3c4d.
    # Нет папки LunqDebloater: заданий нет, Get-ScheduledTask тогда отвечает ошибкой.
    try { $tasks = @(Get-ScheduledTask -TaskPath $script:ScheduleTaskFolder -ErrorAction Stop) }
    catch { return , @() }
    return , @($tasks | ForEach-Object { 'LunqDebloater\' + $_.TaskName })
}

function Remove-LunqScheduleTaskFolder {
    # Пустая папка LunqDebloater в планировщике. schtasks папки не удаляет, поэтому через COM.
    try {
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $service.GetFolder('\').DeleteFolder($script:ScheduleTaskFolder.Trim('\'), 0)
    }
    catch { Write-Verbose $_.Exception.Message }   # папки нет или в ней чужое задание: оставить
}

function Remove-LunqScheduleLeftovers {
    # Убирает задания пересборки и их копии программы. Сначала задания, затем копии: задание без
    # копии не запустится, а копия без задания уже ничего не делает. Неудача только предупреждает,
    # и следующий запуск попробует снова.
    $tasks = Get-LunqScheduleTasks
    $root = Get-LunqScheduleRoot
    $hasCopies = Test-Path -LiteralPath $root
    if ($tasks.Count -eq 0 -and -not $hasCopies) { return }
    Write-Info (Get-LunqText 'Schedule.Removing')
    foreach ($task in $tasks) {
        $code = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/Delete', '/TN', $task, '/F')
        if ($code -eq 0) { Write-Info (Get-LunqText 'Schedule.Removed' $task) }
        else { Write-Warning (Get-LunqText 'Schedule.RemoveFailed' $task $code) }
    }
    if ($tasks.Count -gt 0) { Remove-LunqScheduleTaskFolder }
    if ($hasCopies) {
        try {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            Write-Info (Get-LunqText 'Schedule.CopiesRemoved' $root)
        }
        catch { Write-Warning (Get-LunqText 'Schedule.CopiesNotRemoved' $root $_.Exception.Message) }
    }
}
