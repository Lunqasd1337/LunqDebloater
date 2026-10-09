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

# Тексты на двух языках: скрипт работает в образе без модуля LunqDebloater и его таблиц строк.
# Язык записан при сборке в Language.txt рядом со скриптом; без него берётся язык системы.
$texts = @{
    ru = @{
        NoAdmin        = 'Первичная настройка пропущена: нужны права администратора.'
        WindowTitle    = 'LunqDebloater: первичная настройка'
        Header         = 'LunqDebloater: первичная настройка Windows'
        DoNotClose     = 'Не закрывайте это окно, оно закроется само.'
        TaskFailed     = 'Не удалось создать задание для повторной попытки: {0}'
        AppsHeader     = '==> Установка программ ({0})'
        WaitInternet   = 'Жду подключения к интернету (до 5 минут)...'
        WaitWinget     = 'Жду, пока Windows зарегистрирует winget (до 10 минут)...'
        NoInternet     = 'Нет подключения к интернету.'
        NoWinget       = 'winget не найден.'
        AppFailed      = 'Не удалось установить {0} (код {1})'
        ScriptsHeader  = '==> Ваши скрипты ({0})'
        ScriptExitCode = '{0} завершился с кодом {1}'
        ScriptError    = 'Ошибка в {0}: {1}'
        ScriptsLater   = 'Ваши скрипты ({0}) выполнятся после установки программ, при следующем входе.'
        AppsNextLogon  = 'Неустановленные программы будут поставлены при следующем входе в Windows.'
        AppsGaveUp     = 'Не все программы установлены за {0} попыток. Поставьте их вручную, список в {1}'
        Done           = '==> Готово'
        Installed      = 'Установлено программ: {0}'
        Failed         = 'С ошибками: {0}'
        LogPath        = 'Подробности в логе: {0}'
        Closing        = '    Окно закроется через 60 секунд или по нажатию любой клавиши.'
    }
    en = @{
        NoAdmin        = 'Initial setup skipped: administrator rights are required.'
        WindowTitle    = 'LunqDebloater: initial setup'
        Header         = 'LunqDebloater: initial Windows setup'
        DoNotClose     = 'Do not close this window, it will close by itself.'
        TaskFailed     = 'Could not create the task for another attempt: {0}'
        AppsHeader     = '==> Installing apps ({0})'
        WaitInternet   = 'Waiting for an internet connection (up to 5 minutes)...'
        WaitWinget     = 'Waiting for Windows to register winget (up to 10 minutes)...'
        NoInternet     = 'No internet connection.'
        NoWinget       = 'winget was not found.'
        AppFailed      = 'Could not install {0} (code {1})'
        ScriptsHeader  = '==> Your scripts ({0})'
        ScriptExitCode = '{0} exited with code {1}'
        ScriptError    = 'Error in {0}: {1}'
        ScriptsLater   = 'Your scripts ({0}) will run after the apps are installed, at the next sign-in.'
        AppsNextLogon  = 'Apps that were not installed will be installed at the next sign-in to Windows.'
        AppsGaveUp     = 'Not all apps were installed after {0} attempts. Install them manually, the list is in {1}'
        Done           = '==> Done'
        Installed      = 'Apps installed: {0}'
        Failed         = 'With errors: {0}'
        LogPath        = 'Details are in the log: {0}'
        Closing        = '    This window will close in 60 seconds or when you press any key.'
    }
}
$language = ''
$languageFile = Join-Path $root 'Language.txt'
try { if (Test-Path -LiteralPath $languageFile) { $language = ([string](Get-Content -LiteralPath $languageFile -TotalCount 1)).Trim() } } catch { }   # файл не прочитать: язык системы
if (-not $texts.ContainsKey($language)) {
    $language = 'en'
    try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'ru') { $language = 'ru' } } catch { }   # язык системы не узнать: английский
}

# Текст по ключу; аргументы подставляются через -f.
function Get-Text([string]$Key) { return ($texts[$language][$Key] -f $args) }

# winget и установщики программ требуют прав администратора.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") }
    catch { Write-Host (Get-Text 'NoAdmin') -ForegroundColor Yellow; Start-Sleep -Seconds 10 }
    return
}

$Host.UI.RawUI.WindowTitle = Get-Text 'WindowTitle'

# Рядом со скриптами могут лежать пароли и ключи, а в лог попадает вывод скриптов. Они наследуют
# от Windows права на чтение для всех пользователей, поэтому доступ оставляется только администраторам
# и SYSTEM. Сам FirstLogon.ps1 остаётся доступным: иначе его не запустить без повышения прав.
function Protect-Path([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # ErrorActionPreference здесь Continue, поэтому ошибки командлетов явно превращаются в исключения.
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($rule) }
        $inheritance = 'None'
        if (Test-Path -LiteralPath $Path -PathType Container) { $inheritance = 'ContainerInherit, ObjectInherit' }
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
            $identity = New-Object Security.Principal.SecurityIdentifier $sid
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $identity, 'FullControl', $inheritance, 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
    catch { }   # права не поменять: работа идёт как раньше
}

Start-Transcript -Path $log -Append | Out-Null
Protect-Path $log
Protect-Path $userDir

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
Write-Host (Get-Text 'Header') -ForegroundColor Cyan
Write-Line (Get-Text 'DoNotClose')

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
        # По умолчанию задание не запускается от батареи и останавливается, когда зарядку отключают:
        # на ноутбуке программы так и не поставились бы. Ограничение в 3 дня тоже не нужно.
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
    }
    catch { Write-Line (Get-Text 'TaskFailed' $_.Exception.Message) 'Yellow' }
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
    Write-Host (Get-Text 'AppsHeader' $todo.Count) -ForegroundColor Cyan
    $online = Wait-For { Test-Internet } 300 (Get-Text 'WaitInternet')
    $winget = $null
    if ($online) { $winget = Wait-For { Find-Winget } 600 (Get-Text 'WaitWinget') }

    if (-not $winget) {
        $appsPending = $true
        if (-not $online) { Write-Line (Get-Text 'NoInternet') 'Yellow' } else { Write-Line (Get-Text 'NoWinget') 'Yellow' }
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
                Write-Line (Get-Text 'AppFailed' $parts[0] $LASTEXITCODE) 'Yellow'
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
# Скрипты идут после программ: они могут настраивать то, что ещё не поставилось. На последней
# попытке они выполняются в любом случае.
if ($scripts.Count -gt 0 -and $appsPending -and -not $lastAttempt) {
    Write-Host ''
    Write-Line (Get-Text 'ScriptsLater' $scripts.Count) 'Yellow'
}
elseif ($scripts.Count -gt 0) {
    Write-Host ''
    Write-Host (Get-Text 'ScriptsHeader' $scripts.Count) -ForegroundColor Cyan
    Push-Location $userDir
    foreach ($userScript in $scripts) {
        Write-Line $userScript.Name
        # Неудачей считается и исключение, и ненулевой код выхода (exit 1 в скрипте).
        $global:LASTEXITCODE = 0
        try {
            & $userScript.FullName
            if ($global:LASTEXITCODE -ne 0) {
                Write-Line (Get-Text 'ScriptExitCode' $userScript.Name $global:LASTEXITCODE) 'Yellow'
                $failed += $userScript.Name
            }
        }
        catch { Write-Line (Get-Text 'ScriptError' $userScript.Name $_.Exception.Message) 'Yellow'; $failed += $userScript.Name }
        Add-Content -LiteralPath $scriptsDoneFile -Value $userScript.Name -Encoding UTF8
    }
    Pop-Location
}

if ($appsPending -and -not $lastAttempt) {
    Write-Line (Get-Text 'AppsNextLogon') 'Yellow'
}
else {
    # Всё сделано или попытки кончились: задание больше не нужно.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($appsPending) { Write-Line (Get-Text 'AppsGaveUp' $maxAttempts $appsFile) 'Yellow' }
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
Write-Host (Get-Text 'Done') -ForegroundColor Cyan
if ($installed.Count -gt 0) { Write-Line (Get-Text 'Installed' $installed.Count) }
if ($failed.Count -gt 0) { Write-Line (Get-Text 'Failed' ($failed -join ', ')) 'Yellow' }
Write-Line (Get-Text 'LogPath' $log)
Stop-Transcript | Out-Null

Write-Host ''
Write-Host (Get-Text 'Closing') -ForegroundColor DarkGray
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    try { if ([Console]::KeyAvailable) { break } } catch { break }
    Start-Sleep -Milliseconds 200
}
