# LunqDebloater: первичная настройка после установки Windows.
# Запускается один раз при первом входе (FirstLogonCommands из Windows\System32\Sysprep\unattend.xml).
# Ставит программы из Apps.txt через winget и выполняет скрипты *.ps1 из папки User.
# Если нет интернета или winget, программы ставятся при следующем входе (до 5 попыток).

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$userDir = Join-Path $root 'User'
$appsFile = Join-Path $userDir 'Apps.txt'
$log = Join-Path $root 'FirstLogon.log'
$appsDone = Join-Path $root 'apps.done'
$scriptsDone = Join-Path $root 'scripts.done'
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

$installed = @()
$failed = @()
$deferred = $false

$apps = @()
if (Test-Path -LiteralPath $appsFile) {
    $apps = @(Get-Content -LiteralPath $appsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

if ($apps.Count -gt 0 -and -not (Test-Path -LiteralPath $appsDone)) {
    Write-Host ''
    Write-Host "==> Установка программ ($($apps.Count))" -ForegroundColor Cyan
    $online = Wait-For { Test-Internet } 300 'Жду подключения к интернету (до 5 минут)...'
    $winget = $null
    if ($online) { $winget = Wait-For { Find-Winget } 600 'Жду, пока Windows зарегистрирует winget (до 10 минут)...' }

    if (-not $winget) {
        $deferred = $true
        if (-not $online) { Write-Line 'Нет подключения к интернету.' 'Yellow' } else { Write-Line 'winget не найден.' 'Yellow' }
    }
    else {
        # 0x8A15002B: обновление не требуется, 0x8A150061: программа уже установлена.
        $okCodes = @(0, -1978335189, -1978335135)
        $i = 0
        foreach ($line in $apps) {
            $i++
            $parts = @($line -split '\s+')
            Write-Line ("[{0}/{1}] {2}" -f $i, $apps.Count, $parts[0])
            $arguments = @('install', '--id', $parts[0], '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + @($parts | Select-Object -Skip 1)
            & $winget @arguments
            if ($okCodes -contains $LASTEXITCODE) { $installed += $parts[0] }
            else { Write-Line "Не удалось установить $($parts[0]) (код $LASTEXITCODE)" 'Yellow'; $failed += $parts[0] }
        }
        Set-Content -LiteralPath $appsDone -Value (Get-Date)
    }
}

if (-not (Test-Path -LiteralPath $scriptsDone)) {
    $scripts = @(Get-ChildItem -LiteralPath $userDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($scripts.Count -gt 0) {
        Write-Host ''
        Write-Host "==> Ваши скрипты ($($scripts.Count))" -ForegroundColor Cyan
        Push-Location $userDir
        foreach ($script in $scripts) {
            Write-Line $script.Name
            try { & $script.FullName }
            catch { Write-Line "Ошибка в $($script.Name): $($_.Exception.Message)" 'Yellow'; $failed += $script.Name }
        }
        Pop-Location
    }
    Set-Content -LiteralPath $scriptsDone -Value (Get-Date)
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($deferred -and $attempt -lt $maxAttempts) {
    if (-not $task) {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Force | Out-Null
    }
    Write-Line 'Программы будут установлены при следующем входе в Windows.' 'Yellow'
}
elseif ($task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if ($deferred -and $attempt -ge $maxAttempts) { Write-Line "Программы так и не установлены за $maxAttempts попыток. Поставьте их вручную." 'Yellow' }

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
