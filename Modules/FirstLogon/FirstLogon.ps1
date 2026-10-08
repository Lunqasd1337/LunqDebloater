# LunqDebloater: первичная настройка после установки Windows.
# Запускается при первом входе (FirstLogonCommands из Windows\System32\Sysprep\unattend.xml).
# Ставит программы из Apps.txt через winget и выполняет скрипты *.ps1 из папки User.
# Пока не всё сделано, повторяет работу при следующих входах (до 5 попыток): если нет
# интернета или winget, если программа не поставилась или окно закрыли на середине.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$userDir = Join-Path $root 'User'
$appsFile = Join-Path $userDir 'Apps.txt'
$log = Join-Path $root 'FirstLogon.log'
$appsInstalledFile = Join-Path $root 'apps.installed'
$scriptsDoneFile = Join-Path $root 'scripts.done'
$attemptsFile = Join-Path $root 'attempts.txt'
$taskName = 'LunqFirstLogon'
$maxAttempts = 5

# winget и установщики программ требуют прав администратора.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") }
    catch { Write-Host 'Первичная настройка пропущена: нужны права администратора.' -ForegroundColor Yellow; Start-Sleep -Seconds 10 }
    return
}

$Host.UI.RawUI.WindowTitle = 'LunqDebloater: первичная настройка'
Start-Transcript -Path $log -Append | Out-Null

function Write-Line([string]$Text, [string]$Color = 'Gray') { Write-Host "    $Text" -ForegroundColor $Color }

function Test-Internet {
    try { return ((Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5).Content -eq 'Microsoft Connect Test') }
    catch { return $false }
}

function Wait-For([scriptblock]$Condition, [int]$Seconds, [string]$Message) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $shown = $false
    while ($true) {
        $value = & $Condition
        if ($value) { return $value }
        if ((Get-Date) -gt $deadline) { return $null }
        if (-not $shown) { Write-Line $Message 'DarkGray'; $shown = $true }
        Start-Sleep -Seconds 5
    }
}

function Find-Winget {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    # Сразу после установки App Installer может быть ещё не зарегистрирован для пользователя.
    # Если регистрация не удалась, winget просто ищется ещё раз в Wait-For.
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { }
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

Write-Host ''
Write-Host 'LunqDebloater: первичная настройка Windows' -ForegroundColor Cyan
Write-Line 'Не закрывайте это окно, оно закроется само.'

$attempt = 1
if (Test-Path -LiteralPath $attemptsFile) { $attempt = [int](Get-Content -LiteralPath $attemptsFile -Raw) + 1 }
Set-Content -LiteralPath $attemptsFile -Value $attempt
$lastAttempt = $attempt -ge $maxAttempts

function Read-Lines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Задание на следующий вход ставится сразу, до работы: если окно закроют или компьютер
# выключится на середине, недоделанное продолжится при следующем входе.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task -and -not $lastAttempt) {
    try {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Force | Out-Null
    }
    catch { Write-Line "Не удалось создать задание для повторной попытки: $($_.Exception.Message)" 'Yellow' }
}

$installed = @()
$failed = @()
$appsPending = $false

$apps = @(Read-Lines $appsFile | Where-Object { -not $_.StartsWith('#') })
# Уже установленные в прошлые попытки программы пропускаются.
$alreadyInstalled = @(Read-Lines $appsInstalledFile)
$todo = @($apps | Where-Object { $alreadyInstalled -notcontains @($_ -split '\s+')[0] })

if ($todo.Count -gt 0) {
    Write-Host ''
    Write-Host "==> Установка программ ($($todo.Count))" -ForegroundColor Cyan
    $online = Wait-For { Test-Internet } 300 'Жду подключения к интернету (до 5 минут)...'
    $winget = $null
    if ($online) { $winget = Wait-For { Find-Winget } 600 'Жду, пока Windows зарегистрирует winget (до 10 минут)...' }

    if (-not $winget) {
        $appsPending = $true
        if (-not $online) { Write-Line 'Нет подключения к интернету.' 'Yellow' } else { Write-Line 'winget не найден.' 'Yellow' }
    }
    else {
        # 0x8A15002B: обновление не требуется, 0x8A150061: программа уже установлена.
        $okCodes = @(0, -1978335189, -1978335135)
        $i = 0
        foreach ($line in $todo) {
            $i++
            $parts = @($line -split '\s+')
            Write-Line ("[{0}/{1}] {2}" -f $i, $todo.Count, $parts[0])
            $arguments = @('install', '--id', $parts[0], '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + @($parts | Select-Object -Skip 1)
            & $winget @arguments
            if ($okCodes -contains $LASTEXITCODE) {
                $installed += $parts[0]
                Add-Content -LiteralPath $appsInstalledFile -Value $parts[0] -Encoding UTF8
            }
            else {
                Write-Line "Не удалось установить $($parts[0]) (код $LASTEXITCODE)" 'Yellow'
                $failed += $parts[0]
                $appsPending = $true
            }
        }
    }
}

# Каждый скрипт отмечается выполненным сразу после завершения: скрипт с ошибкой повторно
# не запускается, а не дошедшие до конца (окно закрыли) выполнятся при следующем входе.
$doneScripts = @(Read-Lines $scriptsDoneFile)
$scripts = @(Get-ChildItem -LiteralPath $userDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.ps1' -and $doneScripts -notcontains $_.Name } | Sort-Object Name)
if ($scripts.Count -gt 0) {
    Write-Host ''
    Write-Host "==> Ваши скрипты ($($scripts.Count))" -ForegroundColor Cyan
    Push-Location $userDir
    foreach ($userScript in $scripts) {
        Write-Line $userScript.Name
        # Неудачей считается и исключение, и ненулевой код выхода (exit 1 в скрипте).
        $global:LASTEXITCODE = 0
        try {
            & $userScript.FullName
            if ($global:LASTEXITCODE -ne 0) {
                Write-Line "$($userScript.Name) завершился с кодом $($global:LASTEXITCODE)" 'Yellow'
                $failed += $userScript.Name
            }
        }
        catch { Write-Line "Ошибка в $($userScript.Name): $($_.Exception.Message)" 'Yellow'; $failed += $userScript.Name }
        Add-Content -LiteralPath $scriptsDoneFile -Value $userScript.Name -Encoding UTF8
    }
    Pop-Location
}

if ($appsPending -and -not $lastAttempt) {
    Write-Line 'Неустановленные программы будут поставлены при следующем входе в Windows.' 'Yellow'
}
else {
    # Всё сделано или попытки кончились: задание больше не нужно.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($appsPending) { Write-Line "Не все программы установлены за $maxAttempts попыток. Поставьте их вручную, список в $appsFile" 'Yellow' }
    # В скриптах и файлах рядом с ними могут быть пароли и ключи, поэтому их копии удаляются.
    # Apps.txt и лог остаются. unattend.xml тоже удаляется, чтобы его не подхватил Sysprep.
    Get-ChildItem -LiteralPath $userDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Apps.txt' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $unattend = Join-Path $env:WINDIR 'System32\Sysprep\unattend.xml'
    if ((Test-Path -LiteralPath $unattend) -and (Select-String -LiteralPath $unattend -SimpleMatch 'Created by LunqDebloater' -Quiet)) {
        Remove-Item -LiteralPath $unattend -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '==> Готово' -ForegroundColor Cyan
if ($installed.Count -gt 0) { Write-Line "Установлено программ: $($installed.Count)" }
if ($failed.Count -gt 0) { Write-Line "С ошибками: $($failed -join ', ')" 'Yellow' }
Write-Line "Подробности в логе: $log"
Stop-Transcript | Out-Null

Write-Host ''
Write-Host '    Окно закроется через 60 секунд или по нажатию любой клавиши.' -ForegroundColor DarkGray
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    try { if ([Console]::KeyAvailable) { break } } catch { break }
    Start-Sleep -Milliseconds 200
}
