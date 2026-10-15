#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Проверки скрипта первого входа (Modules\FirstLogon\FirstLogon.ps1). Он запускается в отдельном
# процессе PowerShell с заглушками: winget, интернет, планировщик и часы не настоящие.

BeforeAll {
    $script:Source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\FirstLogon\FirstLogon.ps1'
    $script:OnWindows = $env:OS -eq 'Windows_NT'
    $script:PowerShell = (Get-Process -Id $PID).Path

    # Ненастоящий winget собирается один раз на все тесты: компилятор запускается секунды.
    # Лог вызовов и список неудачных Id он ищет на уровень выше своей папки bin, то есть в папке теста.
    $script:FakeWingetDir = Join-Path ([IO.Path]::GetTempPath()) ('LunqFakeWinget_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:FakeWingetDir -Force | Out-Null
    $script:FakeWinget = Join-Path $script:FakeWingetDir 'winget.exe'
    if ($script:OnWindows) {
        $code = @'
using System; using System.IO; using System.Linq;
public static class FakeWinget {
    public static int Main(string[] args) {
        string root = Path.GetDirectoryName(Path.GetDirectoryName(System.Reflection.Assembly.GetEntryAssembly().Location));
        string failing = Path.Combine(root, "failing.txt");
        // notready.txt: сколько ещё раз winget --version завершится с ошибкой (App Installer обновляется).
        if (args.Length > 0 && args[0] == "--version") {
            string notReady = Path.Combine(root, "notready.txt");
            if (File.Exists(notReady)) {
                int left = int.Parse(File.ReadAllText(notReady).Trim());
                if (left > 0) { File.WriteAllText(notReady, (left - 1).ToString()); return 1; }
            }
            Console.WriteLine("v1.0.0");
            return 0;
        }
        int i = Array.IndexOf(args, "--id"); string id = i >= 0 ? args[i + 1] : "";
        File.AppendAllText(Path.Combine(root, "winget.log"), id + Environment.NewLine);
        if (File.Exists(failing) && File.ReadAllLines(failing).Contains(id)) return 1;
        return 0;
    }
}
'@
        # Add-Type в PowerShell 7 не собирает exe, поэтому собирает компилятор из .NET Framework.
        $source = Join-Path $script:FakeWingetDir 'winget.cs'
        [IO.File]::WriteAllText($source, $code)
        $csc = @('Framework64', 'Framework') | ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        $compilerOutput = & $csc /nologo /target:exe /reference:System.Core.dll "/out:$script:FakeWinget" $source 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Не удалось собрать winget.exe: $compilerOutput" }
    }
    else {
        $sh = "#!/bin/sh`nroot=`"`$(dirname `"`$(dirname `"`$0`")`")`"`nif [ `"`$1`" = '--version' ]; then left=0; if [ -f `"`$root/notready.txt`" ]; then left=`$(cat `"`$root/notready.txt`"); fi; if [ `"`$left`" -gt 0 ]; then echo `$((left - 1)) > `"`$root/notready.txt`"; exit 1; fi; echo v1.0.0; exit 0; fi`nid=''`nwhile [ `$# -gt 0 ]; do if [ `"`$1`" = '--id' ]; then id=`"`$2`"; fi; shift; done`necho `"`$id`" >> `"`$root/winget.log`"`nif [ -f `"`$root/failing.txt`" ] && grep -qx `"`$id`" `"`$root/failing.txt`"; then exit 1; fi`nexit 0`n"
        [IO.File]::WriteAllText($script:FakeWinget, $sh)
        & chmod +x $script:FakeWinget
    }

    function New-FirstLogonTest {
        # Папка C:\Windows\Setup\Scripts\Lunq в миниатюре: скрипт, Language.txt, Apps.txt, свои скрипты, unattend.xml.
        param([string[]]$Apps = @(), [hashtable]$Scripts = @{}, [ValidateSet('ru', 'en')][string]$Language = 'ru')
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $lunq = Join-Path $root 'Lunq'
        $user = Join-Path $lunq 'User'
        New-Item -ItemType Directory -Path $user -Force | Out-Null
        $text = [IO.File]::ReadAllText($script:Source)
        # Проверка прав администратора заменяется на «да» везде, а не только вне Windows. В обычном
        # окне Windows скрипт иначе перезапустил бы себя через UAC, и копия без заглушек поставила бы
        # настоящие программы и зарегистрировала бы настоящее задание.
        $check = 'if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {'
        if (-not $text.Contains($check)) { throw 'FirstLogon.ps1: admin check not found, update the test' }
        $text = $text.Replace($check, 'if ($false) {')
        $text = $text.Replace('$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())', '')
        [IO.File]::WriteAllText((Join-Path $lunq 'FirstLogon.ps1'), $text, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $lunq 'Language.txt'), $Language, (New-Object Text.UTF8Encoding($false)))
        if ($Apps.Count -gt 0) { Set-Content -LiteralPath (Join-Path $user 'Apps.txt') -Value $Apps -Encoding UTF8 }
        foreach ($name in $Scripts.Keys) { [IO.File]::WriteAllText((Join-Path $user $name), $Scripts[$name], (New-Object Text.UTF8Encoding($true))) }
        Set-Content -LiteralPath (Join-Path $user 'secret.txt') -Value 'password'

        $windows = Join-Path $root 'Windows'
        New-Item -ItemType Directory -Path (Join-Path $windows 'System32\Sysprep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $windows 'System32\Sysprep\unattend.xml') -Value '<!-- Created by LunqDebloater: runs the first logon setup script. -->'

        # Ненастоящий winget: пишет вызов в лог и возвращает ошибку для Id из failing.txt.
        $bin = Join-Path $root 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $wingetLog = Join-Path $root 'winget.log'
        $failing = Join-Path $root 'failing.txt'
        Copy-Item -LiteralPath $script:FakeWinget -Destination (Join-Path $bin 'winget.exe')

        # Обёртка: заглушки и запуск скрипта. Часы идут вперёд на каждый Start-Sleep, так что
        # ожидание интернета «до 5 минут» проходит мгновенно.
        $wrapper = @'
param($Lunq, $Windows, $Bin, $State, [switch]$Offline, [switch]$NoTask, [switch]$AclFails, [switch]$NcsiBlocked)
$env:PATH = $Bin + [IO.Path]::PathSeparator + $env:PATH
$env:WINDIR = $Windows
$global:Now = [datetime]'2026-01-01'
$global:Offline = [bool]$Offline
$global:NoTask = [bool]$NoTask
$global:AclFails = [bool]$AclFails
$global:NcsiBlocked = [bool]$NcsiBlocked
$global:TaskFile = Join-Path $State 'task'
$env:USERDOMAIN = 'PC'
$env:USERNAME = 'user'
function global:Get-Date { $global:Now }
function global:Start-Sleep { param($Seconds = 0, $Milliseconds = 0) $global:Now = $global:Now.AddSeconds($Seconds).AddMilliseconds($Milliseconds) }
function global:Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing, $TimeoutSec, $Method)
    if ($global:Offline -or ($global:NcsiBlocked -and $Uri -like '*msftconnecttest*')) { throw 'нет сети' }
    [pscustomobject]@{ Content = 'Microsoft Connect Test' }
}
function global:Get-ScheduledTask { param($TaskName, $ErrorAction) if (Test-Path -LiteralPath $global:TaskFile) { 'task' } }
function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, [switch]$Force) if ($global:NoTask) { throw 'планировщик недоступен' }; Set-Content -LiteralPath $global:TaskFile -Value @("name: $TaskName", $Action, $Trigger, $Principal, $Settings) }
function global:Unregister-ScheduledTask { Remove-Item -LiteralPath $global:TaskFile -ErrorAction SilentlyContinue }
# Заглушки задания возвращают свои аргументы строкой: тест сверяет их в файле задания.
function global:New-ScheduledTaskAction { param($Execute, $Argument) "action: $Execute $Argument" }
function global:New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User) "trigger: atlogon=$AtLogOn user=$User" }
function global:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) "principal: user=$UserId logon=$LogonType level=$RunLevel" }
function global:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit) 'battery={0},{1} limit={2}' -f $AllowStartIfOnBatteries, $DontStopIfGoingOnBatteries, $ExecutionTimeLimit }
function global:Set-Acl { param($LiteralPath, $AclObject, $ErrorAction) if ($global:AclFails) { throw 'доступ запрещён' }; Microsoft.PowerShell.Security\Set-Acl -LiteralPath $LiteralPath -AclObject $AclObject -ErrorAction Stop }
function global:Start-Transcript { }
function global:Stop-Transcript { }
function global:Add-AppxPackage { }
& (Join-Path $Lunq 'FirstLogon.ps1')
'@
        Set-Content -LiteralPath (Join-Path $root 'wrapper.ps1') -Value $wrapper -Encoding UTF8
        return [pscustomobject]@{ Root = $root; Lunq = $lunq; User = $user; Windows = $windows; Bin = $bin; WingetLog = $wingetLog; Failing = $failing; Task = (Join-Path $root 'task') }
    }

    function Invoke-FirstLogon {
        # Один вход в Windows: запуск скрипта в отдельном процессе. Возвращает вывод.
        param([Parameter(Mandatory)]$Test, [switch]$Offline, [switch]$NoTask, [switch]$AclFails, [switch]$NcsiBlocked)
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Test.Root 'wrapper.ps1'), '-Lunq', $Test.Lunq, '-Windows', $Test.Windows, '-Bin', $Test.Bin, '-State', $Test.Root)
        if ($Offline) { $arguments += '-Offline' }
        if ($NoTask) { $arguments += '-NoTask' }
        if ($AclFails) { $arguments += '-AclFails' }
        if ($NcsiBlocked) { $arguments += '-NcsiBlocked' }
        $output = & $script:PowerShell @arguments 2>&1 | Out-String
        return $output
    }

    function Get-Lines([string]$Path) { if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ }) } else { @() } }
}

AfterAll {
    Remove-Item -LiteralPath $script:FakeWingetDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Скрипт первого входа' {
    It 'всё получилось: программы стоят, скрипт выполнен, за собой убрано' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip', 'Mozilla.Firefox --scope machine') -Scripts @{ '10-hello.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'hello.txt') -Value 'Готово'" }
        $out = Invoke-FirstLogon -Test $t
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip', 'Mozilla.Firefox')
        Get-Lines (Join-Path $t.Lunq 'apps.installed') | Should -Be @('7zip.7zip', 'Mozilla.Firefox')
        Get-Lines (Join-Path $t.Lunq 'scripts.done') | Should -Be @('10-hello.ps1')
        # Копии скриптов и файлов рядом с ними удалены, Apps.txt остался.
        @(Get-ChildItem -LiteralPath $t.User | ForEach-Object { $_.Name }) | Should -Be @('Apps.txt')
        Test-Path -LiteralPath (Join-Path $t.Windows 'System32\Sysprep\unattend.xml') | Should -BeFalse
        Test-Path -LiteralPath $t.Task | Should -BeFalse
        $out | Should -Match 'Установлено программ: 2'
    }

    It 'права на скрипты не поставились: об этом написано, а работа идёт дальше' {
        # В Linux Get-Acl нет вовсе, в Windows отказывает заглушка Set-Acl: итог один.
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        $out = Invoke-FirstLogon -Test $t -AclFails
        $out | Should -Match ('Не удалось закрыть .*' + [regex]::Escape((Split-Path $t.User -Leaf)) + ' от других пользователей')
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip')
        $out | Should -Match 'Установлено программ: 1'
    }

    It 'winget ещё не запускается: скрипт ждёт, а не теряет попытку' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        Set-Content -LiteralPath (Join-Path $t.Root 'notready.txt') -Value '2'
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Жду, пока Windows зарегистрирует winget'
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip')
        $out | Should -Match 'Установлено программ: 1'
    }

    It 'msftconnecttest.com закрыт фильтром: интернет находится по второму адресу без ожидания' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        $out = Invoke-FirstLogon -Test $t -NcsiBlocked
        $out | Should -Not -Match 'Жду подключения к интернету'
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip')
    }

    It 'по-английски, если в Language.txt записано en' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip', 'Mozilla.Firefox --scope machine') -Language en
        $out = Invoke-FirstLogon -Test $t
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip', 'Mozilla.Firefox')
        Test-Path -LiteralPath $t.Task | Should -BeFalse
        $out | Should -Match 'Apps installed: 2'
        $out | Should -Not -Match 'Установлено программ'
    }

    It 'неудавшаяся программа ставится при следующем входе, остальные повторно не ставятся' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip', 'Broken.App')
        Set-Content -LiteralPath $t.Failing -Value 'Broken.App'
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Не удалось установить Broken.App'
        Test-Path -LiteralPath $t.Task | Should -BeTrue
        # Задание запускает этот же скрипт при входе этого пользователя с повышенными правами,
        # и от батареи, без ограничения по времени.
        $script = Join-Path $t.Lunq 'FirstLogon.ps1'
        Get-Content -LiteralPath $t.Task | Should -Be @(
            'name: LunqFirstLogon',
            "action: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`"",
            'trigger: atlogon=True user=PC\user',
            'principal: user=PC\user logon=Interactive level=Highest',
            'battery=True,True limit=00:00:00')
        Test-Path -LiteralPath (Join-Path $t.User 'secret.txt') | Should -BeTrue
        if ($script:OnWindows) {
            # Скрипты и файлы рядом с ними (там могут быть пароли) доступны только администраторам и SYSTEM.
            $acl = Get-Acl -LiteralPath $t.User
            $acl.AreAccessRulesProtected | Should -BeTrue
            @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) |
                Should -Be @('S-1-5-18', 'S-1-5-32-544')
        }

        Remove-Item -LiteralPath $t.Failing
        Invoke-FirstLogon -Test $t | Out-Null
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip', 'Broken.App', 'Broken.App')
        Test-Path -LiteralPath $t.Task | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.User 'secret.txt') | Should -BeFalse
    }

    It 'пока программы не поставились, скрипты ждут; на последней попытке выполняются' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip') -Scripts @{ '10-hello.ps1' = "Write-Host 'привет'" }
        for ($i = 1; $i -le 4; $i++) {
            $out = Invoke-FirstLogon -Test $t -Offline
            $out | Should -Match 'Ваши скрипты \(1\) выполнятся после установки программ'
            Test-Path -LiteralPath (Join-Path $t.Lunq 'scripts.done') | Should -BeFalse
        }
        $out = Invoke-FirstLogon -Test $t -Offline
        $out | Should -Match 'привет'
        Get-Lines (Join-Path $t.Lunq 'scripts.done') | Should -Be @('10-hello.ps1')
    }

    It 'задание не создалось: скрипты выполняются сразу и за собой убрано' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip') -Scripts @{ '10-hello.ps1' = "Write-Host 'привет'" }
        $out = Invoke-FirstLogon -Test $t -Offline -NoTask
        $out | Should -Match 'Не удалось создать задание'
        $out | Should -Match 'привет'
        $out | Should -Match 'повторить попытку при следующем входе нельзя'
        Test-Path -LiteralPath (Join-Path $t.User 'secret.txt') | Should -BeFalse
    }

    It 'скрипт с exit 1 считается неудачным, но повторно не запускается' {
        $t = New-FirstLogonTest -Scripts @{ '10-fail.ps1' = 'exit 1'; '20-ok.ps1' = "Write-Host 'ok'" }
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match '10-fail.ps1 завершился с кодом 1'
        $out | Should -Match 'С ошибками: 10-fail.ps1'
        $out | Should -Not -Match '20-ok.ps1 завершился'
        Get-Lines (Join-Path $t.Lunq 'scripts.done') | Should -Be @('10-fail.ps1', '20-ok.ps1')
    }

    It 'скрипт с исключением считается неудачным' {
        $t = New-FirstLogonTest -Scripts @{ '10-throw.ps1' = "throw 'сломалось'" }
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Ошибка в 10-throw.ps1: сломалось'
    }

    It 'без интернета пробует 5 раз, потом сдаётся и убирает за собой' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        for ($i = 1; $i -le 4; $i++) {
            $out = Invoke-FirstLogon -Test $t -Offline
            $out | Should -Match 'Нет подключения к интернету'
            Test-Path -LiteralPath $t.Task | Should -BeTrue
        }
        $out = Invoke-FirstLogon -Test $t -Offline
        $out | Should -Match 'Не все программы установлены за 5 попыток'
        Test-Path -LiteralPath $t.Task | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.User 'secret.txt') | Should -BeFalse
        Get-Lines $t.WingetLog | Should -BeNullOrEmpty
    }
}
