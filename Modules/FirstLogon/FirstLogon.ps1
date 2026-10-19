# LunqDebloater: первичная настройка после установки Windows.
# Запускается при первом входе (FirstLogonCommands из Windows\System32\Sysprep\unattend.xml).
# Ставит программы из Apps.txt через winget, удаляет программы из профиля (папка Uninstall)
# и выполняет скрипты *.ps1 из папки User.
# Пока не всё сделано, повторяет работу при следующих входах (до 5 попыток): если нет
# интернета или winget, если программа не поставилась или окно закрыли на середине.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$userDir = Join-Path $root 'User'
$appsFile = Join-Path $userDir 'Apps.txt'
$log = Join-Path $root 'FirstLogon.log'
$appsInstalledFile = Join-Path $root 'apps.installed'
$scriptsDoneFile = Join-Path $root 'scripts.done'
$uninstallDir = Join-Path $root 'Uninstall'
$uninstallDoneFile = Join-Path $root 'uninstall.done'
$attemptsFile = Join-Path $root 'attempts.txt'
$scriptsStartedFile = Join-Path $root 'scripts.started'
$uninstallStartedFile = Join-Path $root 'uninstall.started'
$taskName = 'LunqFirstLogon'
$maxAttempts = 5
# Скрипт, который столько раз начинался и не дошёл до конца (перезагрузил компьютер или завершил
# процесс), больше не запускается: иначе он повторялся бы при каждом входе.
$maxStarts = 2
# Столько секунд ждётся установка одной программы: зависший установщик не должен держать первый вход.
$appTimeoutSeconds = 1800

# Тексты на двух языках: скрипт работает в образе без модуля LunqDebloater и его таблиц строк.
# Язык записан при сборке в Language.txt рядом со скриптом; без него берётся язык системы.
$texts = @{
    ru = @{
        NoAdmin         = 'Первичная настройка пропущена: нужны права администратора.'
        WindowTitle     = 'LunqDebloater: первичная настройка'
        Header          = 'LunqDebloater: первичная настройка Windows'
        DoNotClose      = 'Не закрывайте это окно, оно закроется само.'
        TaskFailed      = 'Не удалось создать задание для повторной попытки: {0}'
        ProtectFailed   = 'Не удалось закрыть {0} от других пользователей: {1}'
        AppsHeader      = '==> Установка программ ({0})'
        WaitInternet    = 'Жду подключения к интернету (до 5 минут)...'
        WaitWinget      = 'Жду, пока Windows зарегистрирует winget (до 10 минут)...'
        NoInternet      = 'Нет подключения к интернету.'
        NoWinget        = 'winget не найден.'
        AppFailed       = 'Не удалось установить {0} (код {1})'
        ScriptsHeader   = '==> Ваши скрипты ({0})'
        ScriptExitCode  = '{0} завершился с кодом {1}'
        ScriptError     = 'Ошибка в {0}: {1}'
        ScriptsLater    = 'Ваши скрипты ({0}) выполнятся после установки программ, при следующем входе.'
        Interrupted     = '{0} уже {1} раза начинался и не дошёл до конца (например, перезагрузил компьютер), пропускаю.'
        AttemptsOver    = 'Первичная настройка не закончилась за {0} попыток и больше не повторяется. Что не получилось, видно в логе прошлых попыток.'
        UninstallHeader = '==> Удаление программ ({0})'
        UninstallFailed = 'Не удалось удалить {0} (код {1})'
        UninstallError  = 'Ошибка при удалении {0}: {1}'
        UninstallLater  = 'Удаление программ ({0}) выполнится после установки программ, при следующем входе.'
        AppsNextLogon   = 'Неустановленные программы будут поставлены при следующем входе в Windows.'
        AppsGaveUp      = 'Не все программы установлены за {0} попыток. Поставьте их вручную, список в {1}'
        AppsNoRetry     = 'Не все программы установлены, а повторить попытку при следующем входе нельзя. Поставьте их вручную, список в {0}'
        Done            = '==> Готово'
        Installed       = 'Установлено программ: {0}'
        Failed          = 'С ошибками: {0}'
        LogPath         = 'Подробности в логе: {0}'
        Closing         = '    Окно закроется через 60 секунд или по нажатию любой клавиши.'
        WifiHeader      = '==> Сети Wi-Fi ({0})'
        WifiFailed      = 'Не удалось добавить сеть {0} (код {1})'
        WifiAdded       = 'Добавлено сетей: {0}'
        WifiLater       = 'Сети, которые не добавились, будут добавлены при следующем входе.'
        AppTimeout      = 'Установка {0} не закончилась за {1} минут и прервана'
        PasswordHeader  = '==> Пароль для {0}'
        PasswordHint    = 'Учётная запись создана без пароля. Пока пароль не задан, войти может любой, кто сидит за компьютером.'
        PasswordPrompt  = 'Новый пароль (Enter: оставить без пароля)'
        PasswordRepeat  = 'Ещё раз'
        PasswordSet     = 'Пароль задан.'
        PasswordSkipped = 'Пароль не задан. Его можно задать в «Параметры → Учётные записи → Варианты входа».'
        PasswordDiffer  = 'Пароли не совпали.'
        PasswordFailed  = 'Не удалось задать пароль: {0}'
    }
    en = @{
        NoAdmin         = 'Initial setup skipped: administrator rights are required.'
        WindowTitle     = 'LunqDebloater: initial setup'
        Header          = 'LunqDebloater: initial Windows setup'
        DoNotClose      = 'Do not close this window, it will close by itself.'
        TaskFailed      = 'Could not create the task for another attempt: {0}'
        ProtectFailed   = 'Could not hide {0} from other users: {1}'
        AppsHeader      = '==> Installing apps ({0})'
        WaitInternet    = 'Waiting for an internet connection (up to 5 minutes)...'
        WaitWinget      = 'Waiting for Windows to register winget (up to 10 minutes)...'
        NoInternet      = 'No internet connection.'
        NoWinget        = 'winget was not found.'
        AppFailed       = 'Could not install {0} (code {1})'
        ScriptsHeader   = '==> Your scripts ({0})'
        ScriptExitCode  = '{0} exited with code {1}'
        ScriptError     = 'Error in {0}: {1}'
        ScriptsLater    = 'Your scripts ({0}) will run after the apps are installed, at the next sign-in.'
        Interrupted     = '{0} was started {1} times and never finished (for example, it restarted the computer), skipping.'
        AttemptsOver    = 'Initial setup did not finish in {0} attempts and will not run again. The log of the previous attempts shows what failed.'
        UninstallHeader = '==> Uninstalling programs ({0})'
        UninstallFailed = 'Could not uninstall {0} (code {1})'
        UninstallError  = 'Error while uninstalling {0}: {1}'
        UninstallLater  = 'Uninstalling programs ({0}) will run after the apps are installed, at the next sign-in.'
        AppsNextLogon   = 'Apps that were not installed will be installed at the next sign-in to Windows.'
        AppsGaveUp      = 'Not all apps were installed after {0} attempts. Install them manually, the list is in {1}'
        AppsNoRetry     = 'Not all apps were installed, and they cannot be retried at the next sign-in. Install them manually, the list is in {0}'
        Done            = '==> Done'
        Installed       = 'Apps installed: {0}'
        Failed          = 'With errors: {0}'
        LogPath         = 'Details are in the log: {0}'
        Closing         = '    This window will close in 60 seconds or when you press any key.'
        WifiHeader      = '==> Wi-Fi networks ({0})'
        WifiFailed      = 'Could not add the network {0} (code {1})'
        WifiAdded       = 'Networks added: {0}'
        WifiLater       = 'Networks that were not added will be added at the next sign-in.'
        AppTimeout      = 'Installing {0} did not finish in {1} minutes and was stopped'
        PasswordHeader  = '==> Password for {0}'
        PasswordHint    = 'The account was created without a password. Until a password is set, anyone at the computer can sign in.'
        PasswordPrompt  = 'New password (Enter: leave without a password)'
        PasswordRepeat  = 'Once more'
        PasswordSet     = 'The password is set.'
        PasswordSkipped = 'No password set. You can set one in Settings > Accounts > Sign-in options.'
        PasswordDiffer  = 'The passwords do not match.'
        PasswordFailed  = 'Could not set the password: {0}'
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
    # Работа идёт дальше, но в логе видно, что пароли и ключи рядом со скриптами остались доступны.
    catch { Write-Host ('    ' + (Get-Text 'ProtectFailed' $Path $_.Exception.Message)) -ForegroundColor Yellow }
}

Start-Transcript -Path $log -Append | Out-Null
Protect-Path $log
Protect-Path $userDir

function Write-Line([string]$Text, [string]$Color = 'Gray') { Write-Host "    $Text" -ForegroundColor $Color }

function Test-Internet {
    try { if ((Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5).Content -eq 'Microsoft Connect Test') { return $true } }
    catch { }   # не ответил: проверяется второй адрес
    # msftconnecttest.com бывает закрыт фильтром (Pi-hole, корпоративная сеть), и тогда каждый вход
    # ждал бы 5 минут. Второй адрес это сервер, откуда winget и так берёт каталог программ.
    # Ответ с кодом ошибки HTTP тоже значит, что сеть есть.
    try { $null = Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -Method Head -UseBasicParsing -TimeoutSec 5; return $true }
    catch { return [bool]$_.Exception.Response }
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

function Test-Winget([string]$Path) {
    # В первые минуты после установки Магазин часто обновляет App Installer: winget.exe уже есть,
    # но не запускается, и все программы этой попытки не поставились бы.
    try { & $Path --version *> $null; return $LASTEXITCODE -eq 0 }
    catch { return $false }
}

function Find-Winget {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-Winget $command.Source)) { return $command.Source }
    # Сразу после установки App Installer может быть ещё не зарегистрирован для пользователя.
    # Если регистрация не удалась, winget просто ищется ещё раз в Wait-For.
    if (-not $command) { try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop } catch { } }
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-Winget $command.Source)) { return $command.Source }
    return $null
}

Write-Host ''
Write-Host (Get-Text 'Header') -ForegroundColor Cyan
Write-Line (Get-Text 'DoNotClose')

# Сети Wi-Fi с компьютера, на котором собран образ: профили netsh с паролями открытым текстом.
# Они добавляются первыми, чтобы для программ сразу был интернет. Добавленная сеть тут же удаляется
# с диска. Не добавленная (например, драйвер Wi-Fi ещё не установлен) ждёт следующего входа в закрытой
# папке, а когда задание больше не нужно, удаляется вместе с остальным.
$wifiDir = Join-Path $root 'Wifi'
if (Test-Path -LiteralPath $wifiDir) {
    Protect-Path $wifiDir
    $wifiFiles = @(Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.xml' })
    if ($wifiFiles.Count -gt 0) {
        Write-Host ''
        Write-Host (Get-Text 'WifiHeader' $wifiFiles.Count) -ForegroundColor Cyan
        $wifiAdded = 0
        foreach ($wifiFile in $wifiFiles) {
            $global:LASTEXITCODE = 0
            & netsh wlan add profile "filename=$($wifiFile.FullName)" user=all *> $null
            if ($LASTEXITCODE -eq 0) {
                $wifiAdded++
                Remove-Item -LiteralPath $wifiFile.FullName -Force -ErrorAction SilentlyContinue
            }
            else { Write-Line (Get-Text 'WifiFailed' $wifiFile.BaseName $LASTEXITCODE) 'Yellow' }
        }
        Write-Line (Get-Text 'WifiAdded' $wifiAdded)
        if ($wifiAdded -lt $wifiFiles.Count) { Write-Line (Get-Text 'WifiLater') 'Yellow' }
    }
    if (@(Get-ChildItem -LiteralPath $wifiDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $wifiDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$attempt = 1
if (Test-Path -LiteralPath $attemptsFile) { $attempt = [int](Get-Content -LiteralPath $attemptsFile -Raw) + 1 }
Set-Content -LiteralPath $attemptsFile -Value $attempt
$lastAttempt = $attempt -ge $maxAttempts

function Invoke-Winget([string]$Winget, [string[]]$Arguments) {
    # Запускает winget и возвращает код выхода или $null, если установка не закончилась за отведённое
    # время. Вывод идёт через файл: в Windows PowerShell 5.1 транскрипт не пишет вывод внешних
    # программ, а так он попадает и в окно, и в лог.
    $out = Join-Path $root ('winget-' + [guid]::NewGuid().ToString('N') + '.txt')
    # Start-Process в 5.1 не берёт аргументы в кавычки сам.
    $line = @($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $process = Start-Process -FilePath $Winget -ArgumentList $line -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Без обращения к Handle Windows PowerShell 5.1 не отдаёт ExitCode после выхода.
    $null = $process.Handle
    $code = $null
    if ($process.WaitForExit($appTimeoutSeconds * 1000)) { $code = $process.ExitCode }
    else {
        # Вместе с установщиком, который запустил winget. taskkill есть только в Windows.
        try { & taskkill.exe /PID $process.Id /T /F *> $null } catch { $process.Kill() }
        if (-not $process.HasExited) { try { $process.Kill() } catch { } }   # уже завершился сам
    }
    foreach ($file in $out, "$out.err") {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        # Строки хода установки winget перезаписывает через возврат каретки: остаётся последняя.
        Get-Content -LiteralPath $file -Encoding UTF8 | ForEach-Object { @($_ -split "`r")[-1] } | Where-Object { $_.Trim() } | Out-Host
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    return $code
}

function Read-Lines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Отметка «начат» ставится до запуска, «выполнен» после: по ним видно, что запуск не дошёл до конца.
function Test-Interrupted([string]$StartedFile, [string]$Name) {
    return @(Read-Lines $StartedFile | Where-Object { $_ -eq $Name }).Count -ge $maxStarts
}

function Remove-Leftovers {
    # Всё сделано или попытки кончились: задание больше не нужно.
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    # В скриптах и файлах рядом с ними могут быть пароли и ключи, поэтому их копии удаляются.
    # Apps.txt и лог остаются. unattend.xml тоже удаляется, чтобы его не подхватил Sysprep.
    Get-ChildItem -LiteralPath $userDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Apps.txt' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $uninstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wifiDir -Recurse -Force -ErrorAction SilentlyContinue
    # Остался только Apps.txt, секретов в нём нет: права снова наследуются от Windows, и список
    # можно открыть без прав администратора.
    try {
        $acl = Get-Acl -LiteralPath $userDir -ErrorAction Stop
        $acl.SetAccessRuleProtection($false, $false)
        Set-Acl -LiteralPath $userDir -AclObject $acl -ErrorAction Stop
    }
    catch { }   # права не вернуть: список доступен администраторам
    $unattend = Join-Path $env:WINDIR 'System32\Sysprep\unattend.xml'
    if ((Test-Path -LiteralPath $unattend) -and (Select-String -LiteralPath $unattend -SimpleMatch 'Created by LunqDebloater' -Quiet)) {
        Remove-Item -LiteralPath $unattend -Force -ErrorAction SilentlyContinue
    }
}

# Попытки кончились, а задание осталось: последняя попытка не дошла до конца (например, её прервала
# перезагрузка). Работа больше не повторяется, остаётся только убрать за собой.
if ($attempt -gt $maxAttempts) {
    Write-Line (Get-Text 'AttemptsOver' $maxAttempts) 'Yellow'
    Remove-Leftovers
    Write-Line (Get-Text 'LogPath' $log)
    Stop-Transcript | Out-Null
    return
}

# Задание на следующий вход ставится сразу, до работы: если окно закроют или компьютер
# выключится на середине, недоделанное продолжится при следующем входе.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$retryScheduled = [bool]$task
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
        $retryScheduled = $true
    }
    catch { Write-Line (Get-Text 'TaskFailed' $_.Exception.Message) 'Yellow' }
}

# Учётная запись из файла ответов создана без пароля: в ISO пароль не хранится. Задать его
# предлагается один раз. Отметка удаляется после ответа, поэтому, если окно закрыли, вопрос
# повторится при следующем входе: задание для него уже создано выше.
$accountFile = Join-Path $root 'LocalAccount.txt'
if (Test-Path -LiteralPath $accountFile) {
    $account = ([string](Get-Content -LiteralPath $accountFile -TotalCount 1 -Encoding UTF8)).Trim()
    Write-Host ''
    Write-Host (Get-Text 'PasswordHeader' $account) -ForegroundColor Cyan
    Write-Line (Get-Text 'PasswordHint') 'Yellow'
    $passwordSet = $false
    for ($try = 1; $try -le 3 -and -not $passwordSet; $try++) {
        $first = Read-Host -AsSecureString ('    ' + (Get-Text 'PasswordPrompt'))
        if (-not $first -or $first.Length -eq 0) { break }
        $second = Read-Host -AsSecureString ('    ' + (Get-Text 'PasswordRepeat'))
        # Сравнение без вывода пароля: NetworkCredential раскрывает SecureString только в памяти.
        if ((New-Object Net.NetworkCredential('', $first)).Password -cne (New-Object Net.NetworkCredential('', $second)).Password) {
            Write-Line (Get-Text 'PasswordDiffer') 'Yellow'
            continue
        }
        # Set-LocalUser, а не net user: пароль не попадает в командную строку процесса.
        try {
            Set-LocalUser -Name $account -Password $first -ErrorAction Stop
            $passwordSet = $true
        }
        catch { Write-Line (Get-Text 'PasswordFailed' $_.Exception.Message) 'Yellow' }
    }
    if ($passwordSet) { Write-Line (Get-Text 'PasswordSet') } else { Write-Line (Get-Text 'PasswordSkipped') 'Yellow' }
    Remove-Item -LiteralPath $accountFile -Force -ErrorAction SilentlyContinue
}

# Без задания следующего входа не будет: эта попытка последняя, и откладывать ничего нельзя.
$finalRun = $lastAttempt -or -not $retryScheduled

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
        # 0x8A15002B: обновление не требуется, 0x8A150061: программа уже установлена,
        # 0x8A150109: установлена, закончится после перезагрузки.
        $okCodes = @(0, -1978335189, -1978335135, -1978334967)
        $i = 0
        foreach ($line in $todo) {
            $i++
            $parts = @($line -split '\s+')
            Write-Line ("[{0}/{1}] {2}" -f $i, $todo.Count, $parts[0])
            $arguments = @('install', '--id', $parts[0], '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') + @($parts | Select-Object -Skip 1)
            $code = Invoke-Winget $winget $arguments
            if ($null -eq $code) {
                Write-Line (Get-Text 'AppTimeout' $parts[0] ([int]($appTimeoutSeconds / 60))) 'Yellow'
                $failed += $parts[0]
                $appsPending = $true
            }
            elseif ($okCodes -contains $code) {
                $installed += $parts[0]
                Add-Content -LiteralPath $appsInstalledFile -Value $parts[0] -Encoding UTF8
            }
            else {
                Write-Line (Get-Text 'AppFailed' $parts[0] $code) 'Yellow'
                $failed += $parts[0]
                $appsPending = $true
            }
        }
    }
}

# Программы из профиля, которые DISM не удалил из образа (Uninstall.json кладёт сборка). Как и
# скрипты, они ждут программ из Apps.txt: среди них может быть браузер на замену Edge. Каждый
# скрипт удаления идёт в отдельном PowerShell, чтобы его exit и переменные не задели этот скрипт,
# и отмечается сделанным сразу: с ошибкой повторно не запускается.
$uninstallTodo = @()
$uninstallFile = Join-Path $uninstallDir 'Uninstall.json'
if (Test-Path -LiteralPath $uninstallFile) {
    $doneUninstall = @(Read-Lines $uninstallDoneFile)
    try { $uninstallTodo = @((Get-Content -LiteralPath $uninstallFile -Raw -Encoding UTF8 | ConvertFrom-Json).Programs | Where-Object { $_ -and $doneUninstall -notcontains $_.Name }) }
    catch { Write-Line (Get-Text 'UninstallError' $uninstallFile $_.Exception.Message) 'Yellow' }
}
if ($uninstallTodo.Count -gt 0 -and $appsPending -and -not $finalRun) {
    Write-Host ''
    Write-Line (Get-Text 'UninstallLater' $uninstallTodo.Count) 'Yellow'
}
elseif ($uninstallTodo.Count -gt 0) {
    Write-Host ''
    Write-Host (Get-Text 'UninstallHeader' $uninstallTodo.Count) -ForegroundColor Cyan
    $powershell = (Get-Process -Id $PID).Path
    foreach ($program in $uninstallTodo) {
        Write-Line $program.Title
        if (Test-Interrupted $uninstallStartedFile $program.Name) {
            Write-Line (Get-Text 'Interrupted' $program.Title $maxStarts) 'Yellow'
            $failed += $program.Title
            Add-Content -LiteralPath $uninstallDoneFile -Value $program.Name -Encoding UTF8
            continue
        }
        Add-Content -LiteralPath $uninstallStartedFile -Value $program.Name -Encoding UTF8
        $global:LASTEXITCODE = 0
        try {
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $uninstallDir $program.Script)) + @($program.Arguments)
            # Out-Host: вывод скрипта попадает и в окно, и в лог.
            & $powershell @arguments | Out-Host
            if ($global:LASTEXITCODE -ne 0) {
                Write-Line (Get-Text 'UninstallFailed' $program.Title $global:LASTEXITCODE) 'Yellow'
                $failed += $program.Title
            }
        }
        catch { Write-Line (Get-Text 'UninstallError' $program.Title $_.Exception.Message) 'Yellow'; $failed += $program.Title }
        Add-Content -LiteralPath $uninstallDoneFile -Value $program.Name -Encoding UTF8
    }
}

# Каждый скрипт отмечается выполненным сразу после завершения: скрипт с ошибкой повторно
# не запускается, а не дошедшие до конца (окно закрыли) выполнятся при следующем входе, но
# не больше двух раз.
$doneScripts = @(Read-Lines $scriptsDoneFile)
$scripts = @(Get-ChildItem -LiteralPath $userDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.ps1' -and $doneScripts -notcontains $_.Name } | Sort-Object Name)
# Скрипты идут после программ: они могут настраивать то, что ещё не поставилось. На последней
# попытке они выполняются в любом случае.
if ($scripts.Count -gt 0 -and $appsPending -and -not $finalRun) {
    Write-Host ''
    Write-Line (Get-Text 'ScriptsLater' $scripts.Count) 'Yellow'
}
elseif ($scripts.Count -gt 0) {
    Write-Host ''
    Write-Host (Get-Text 'ScriptsHeader' $scripts.Count) -ForegroundColor Cyan
    Push-Location $userDir
    foreach ($userScript in $scripts) {
        Write-Line $userScript.Name
        if (Test-Interrupted $scriptsStartedFile $userScript.Name) {
            Write-Line (Get-Text 'Interrupted' $userScript.Name $maxStarts) 'Yellow'
            $failed += $userScript.Name
            Add-Content -LiteralPath $scriptsDoneFile -Value $userScript.Name -Encoding UTF8
            continue
        }
        Add-Content -LiteralPath $scriptsStartedFile -Value $userScript.Name -Encoding UTF8
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

if ($appsPending -and -not $finalRun) {
    Write-Line (Get-Text 'AppsNextLogon') 'Yellow'
}
else {
    if ($appsPending -and $lastAttempt) { Write-Line (Get-Text 'AppsGaveUp' $maxAttempts $appsFile) 'Yellow' }
    elseif ($appsPending) { Write-Line (Get-Text 'AppsNoRetry' $appsFile) 'Yellow' }
    Remove-Leftovers
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
