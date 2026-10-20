# Программы, которые категория профиля удаляет полем Uninstall. Средствами DISM их из образа не
# убрать, поэтому каждую удаляет свой скрипт из папки ThirdParty: в собранной Windows при первом
# входе (Install-LunqFirstLogon кладёт его в образ), на этой Windows (-Online) сразу. -Restore
# ставит программу обратно тем же скриптом.
$script:LunqUninstallers = [ordered]@{
    # EdgeRemover от he3als (https://github.com/he3als/EdgeRemover), без изменений кода: версия, коммит
    # и контрольные суммы в ThirdParty\EdgeRemover\SOURCE.txt. Без параметров он открывает меню и
    # ждёт клавишу, поэтому всегда запускается с -NonInteractive. WebView2 он не трогает: без него
    # не работают многие программы.
    MicrosoftEdge = @{
        Title   = 'Microsoft Edge'
        Script  = 'EdgeRemover\RemoveEdge.ps1'
        Remove  = @('-UninstallEdge', '-NonInteractive')
        Restore = @('-InstallEdge', '-NonInteractive')
    }
}

function Get-LunqUninstallNames {
    return @($script:LunqUninstallers.Keys)
}

function Get-LunqUninstallTitle {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:LunqUninstallers.Contains($Name)) { return $script:LunqUninstallers[$Name].Title }
    return $Name
}

function Get-LunqThirdPartyRoot {
    # Папка ThirdParty рядом с LunqDebloater.ps1: модуль лежит в Modules\LunqDebloater.
    return (Join-Path (Split-Path (Split-Path $script:ModuleRoot -Parent) -Parent) 'ThirdParty')
}

function Invoke-LunqUninstaller {
    # Запускает скрипт удаления (или с -Action Restore установки) на этой Windows. Отдельный
    # powershell.exe: exit и переменные чужого скрипта не задевают LunqDebloater. Возвращает код выхода.
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('Remove', 'Restore')][string]$Action = 'Remove')
    $entry = $script:LunqUninstallers[$Name]
    $path = Join-Path (Get-LunqThirdPartyRoot) $entry.Script
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $entry[$Action]
    return (Invoke-Native -FilePath (Get-LunqWindowsPowerShell) -Arguments $arguments -ShowOutput)
}

function Remove-LunqPrograms {
    # -Online: удаляет программы из поля Uninstall включённых категорий. Удалённое запоминается
    # для -Restore, неудача попадает в итог и не останавливает остальные шаги.
    param([Parameter(Mandatory)]$Config, $Restore)
    $result = New-LunqResult (Get-LunqText 'Uninstall.Title') 'Uninstall'
    foreach ($name in (Get-ConfigList $Config 'Uninstall')) {
        $title = Get-LunqUninstallTitle $name
        Write-Info (Get-LunqText 'Uninstall.Removing' $title)
        $code = Invoke-LunqUninstaller -Name $name
        if ($code -eq 0) {
            $result.Done.Add($title)
            if ($Restore) { Add-LunqRestoreItem -Restore $Restore -Kind Uninstall -Name $name }
        }
        else {
            Write-Warning (Get-LunqText 'Uninstall.Failed' $title $code)
            $result.Failed.Add($title)
        }
    }
    $result.Summary = Get-LunqText 'Uninstall.Summary' $result.Done.Count $result.Failed.Count
    return $result
}

function Copy-LunqUninstallers {
    # Кладёт скрипты удаления в образ вместе с их папками и Uninstall.json со списком: что
    # запустить и с какими параметрами. FirstLogon.ps1 работает без модуля и берёт всё оттуда.
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string[]]$Names)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $programs = foreach ($name in $Names) {
        $entry = $script:LunqUninstallers[$name]
        $folder = Split-Path $entry.Script -Parent
        Copy-Item -LiteralPath (Join-Path (Get-LunqThirdPartyRoot) $folder) -Destination $Destination -Recurse -Force
        [ordered]@{ Name = $name; Title = $entry.Title; Script = $entry.Script; Arguments = @($entry.Remove) }
    }
    $json = [ordered]@{ Programs = @($programs) } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $Destination 'Uninstall.json'), $json, (New-Object Text.UTF8Encoding($false)))
}
