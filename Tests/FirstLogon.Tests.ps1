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
        // scope.log: Id и --scope каждого вызова; useronly.txt: установщик только для текущего
        // пользователя, на --scope machine winget отвечает 0x8A150010.
        int s = Array.IndexOf(args, "--scope"); string scope = s >= 0 ? args[s + 1] : "";
        File.AppendAllText(Path.Combine(root, "scope.log"), id + " " + scope + Environment.NewLine);
        string userOnly = Path.Combine(root, "useronly.txt");
        if (scope == "machine" && File.Exists(userOnly) && File.ReadAllLines(userOnly).Contains(id)) return unchecked((int)0x8A150010);
        // hang.txt: установщик завис; reboot.txt: установлено, нужна перезагрузка (0x8A150109).
        string hang = Path.Combine(root, "hang.txt");
        if (File.Exists(hang) && File.ReadAllLines(hang).Contains(id)) System.Threading.Thread.Sleep(30000);
        string reboot = Path.Combine(root, "reboot.txt");
        if (File.Exists(reboot) && File.ReadAllLines(reboot).Contains(id)) return unchecked((int)0x8A150109);
        if (File.Exists(failing) && File.ReadAllLines(failing).Contains(id)) return 1;
        Console.WriteLine("Successfully installed " + id);
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
        $sh = "#!/bin/sh`nroot=`"`$(dirname `"`$(dirname `"`$0`")`")`"`nif [ `"`$1`" = '--version' ]; then left=0; if [ -f `"`$root/notready.txt`" ]; then left=`$(cat `"`$root/notready.txt`"); fi; if [ `"`$left`" -gt 0 ]; then echo `$((left - 1)) > `"`$root/notready.txt`"; exit 1; fi; echo v1.0.0; exit 0; fi`nid=''`nscope=''`nwhile [ `$# -gt 0 ]; do if [ `"`$1`" = '--id' ]; then id=`"`$2`"; fi; if [ `"`$1`" = '--scope' ]; then scope=`"`$2`"; fi; shift; done`necho `"`$id`" >> `"`$root/winget.log`"`necho `"`$id `$scope`" >> `"`$root/scope.log`"`nif [ -f `"`$root/hang.txt`" ] && grep -qx `"`$id`" `"`$root/hang.txt`"; then sleep 30; fi`nif [ -f `"`$root/failing.txt`" ] && grep -qx `"`$id`" `"`$root/failing.txt`"; then exit 1; fi`necho `"Successfully installed `$id`"`nexit 0`n"
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
        # Зависшая установка прерывается через 3 секунды, а не через полчаса.
        if (-not $text.Contains('$appTimeoutSeconds = 1800')) { throw 'FirstLogon.ps1: app timeout not found, update the test' }
        $text = $text.Replace('$appTimeoutSeconds = 1800', '$appTimeoutSeconds = 3')
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
param($Lunq, $Windows, $Bin, $State, [switch]$Offline, [switch]$NoTask, [switch]$AclFails, [switch]$NcsiBlocked, [switch]$WifiFails)
$env:PATH = $Bin + [IO.Path]::PathSeparator + $env:PATH
# Номер процесса скрипта первого входа: тест сверяет, что ваши скрипты идут в другом.
Set-Content -LiteralPath (Join-Path $State 'pid.txt') -Value $PID
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
# netsh: вызов пишется в лог, а с -WifiFails сеть не добавляется.
$global:NetshLog = Join-Path $State 'netsh.log'
$global:WifiFails = [bool]$WifiFails
function global:netsh { Add-Content -LiteralPath $global:NetshLog -Value ($args -join ' '); if ($global:WifiFails) { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 } }
# Ответы на вопрос о пароле по строке из answers.txt, дальше пустой ответ (Enter). Set-LocalUser
# пишет, кому и какой пароль задан бы был.
$global:Answers = New-Object System.Collections.Generic.Queue[string]
$answersFile = Join-Path $State 'answers.txt'
if (Test-Path -LiteralPath $answersFile) { foreach ($a in @(Get-Content -LiteralPath $answersFile -Encoding UTF8)) { $global:Answers.Enqueue($a) } }
$global:SetUserLog = Join-Path $State 'setuser.log'
function global:Read-Host {
    param($Prompt, [switch]$AsSecureString)
    $answer = if ($global:Answers.Count -gt 0) { $global:Answers.Dequeue() } else { '' }
    Write-Host "$Prompt> [$($answer -replace '.', '*')]"
    if (-not $answer) { return (New-Object Security.SecureString) }
    return (ConvertTo-SecureString -String $answer -AsPlainText -Force)
}
function global:Set-LocalUser {
    param($Name, $Password, $ErrorAction)
    if ($Name -eq 'Сломан') { throw 'учётная запись не найдена' }
    Add-Content -LiteralPath $global:SetUserLog -Value ('{0}|{1}' -f $Name, (New-Object Net.NetworkCredential('', $Password)).Password) -Encoding UTF8
}
& (Join-Path $Lunq 'FirstLogon.ps1')
'@
        Set-Content -LiteralPath (Join-Path $root 'wrapper.ps1') -Value $wrapper -Encoding UTF8
        return [pscustomobject]@{ Root = $root; Lunq = $lunq; User = $user; Windows = $windows; Bin = $bin; WingetLog = $wingetLog; Failing = $failing; Task = (Join-Path $root 'task') }
    }

    function Invoke-FirstLogon {
        # Один вход в Windows: запуск скрипта в отдельном процессе. Возвращает вывод.
        param([Parameter(Mandatory)]$Test, [switch]$Offline, [switch]$NoTask, [switch]$AclFails, [switch]$NcsiBlocked, [switch]$WifiFails)
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Test.Root 'wrapper.ps1'), '-Lunq', $Test.Lunq, '-Windows', $Test.Windows, '-Bin', $Test.Bin, '-State', $Test.Root)
        if ($Offline) { $arguments += '-Offline' }
        if ($NoTask) { $arguments += '-NoTask' }
        if ($AclFails) { $arguments += '-AclFails' }
        if ($NcsiBlocked) { $arguments += '-NcsiBlocked' }
        if ($WifiFails) { $arguments += '-WifiFails' }
        $output = & $script:PowerShell @arguments 2>&1 | Out-String
        return $output
    }

    function Add-FakeUninstall {
        # Папка Uninstall, как её кладёт сборка, но с ненастоящим скриптом: он пишет в лог, с какими
        # параметрами его запустили, и завершается с заданным кодом.
        param([Parameter(Mandatory)]$Test, [int]$ExitCode = 0)
        $dir = Join-Path $Test.Lunq 'Uninstall\Fake'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $log = Join-Path $Test.Root 'uninstall.log'
        Set-Content -LiteralPath (Join-Path $dir 'Remove.ps1') -Encoding UTF8 -Value @"
param([switch]`$UninstallEdge, [switch]`$NonInteractive)
Add-Content -LiteralPath '$log' -Value (@(`$PSBoundParameters.Keys | Sort-Object) -join ',')
exit $ExitCode
"@
        $json = '{"Programs":[{"Name":"MicrosoftEdge","Title":"Microsoft Edge","Script":"Fake\\Remove.ps1","Arguments":["-UninstallEdge","-NonInteractive"]}]}'
        Set-Content -LiteralPath (Join-Path $Test.Lunq 'Uninstall\Uninstall.json') -Value $json -Encoding UTF8
        return $log
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
        # Программы ставятся для всех пользователей, а своё --scope из Apps.txt не дублируется.
        Get-Lines (Join-Path $t.Root 'scope.log') | Should -Be @('7zip.7zip machine', 'Mozilla.Firefox machine')
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

    It 'сети Wi-Fi добавляются до программ, а их файлы с паролями сразу удаляются' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        $wifi = Join-Path $t.Lunq 'Wifi'
        New-Item -ItemType Directory -Path $wifi -Force | Out-Null
        foreach ($name in 'Wi-Fi-Home', 'Wi-Fi-Office') { Set-Content -LiteralPath (Join-Path $wifi "$name.xml") -Value '<WLANProfile />' }
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Сети Wi-Fi \(2\)'
        $out | Should -Match 'Добавлено сетей: 2'
        $calls = Get-Lines (Join-Path $t.Root 'netsh.log')
        $calls.Count | Should -Be 2
        $calls[0] | Should -Match '^wlan add profile filename=.*Wi-Fi-Home\.xml user=all$'
        Test-Path -LiteralPath $wifi | Should -BeFalse
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip')
    }

    It 'сеть не добавилась: об этом написано, файлы всё равно удалены' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        $wifi = Join-Path $t.Lunq 'Wifi'
        New-Item -ItemType Directory -Path $wifi -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $wifi 'Wi-Fi-Home.xml') -Value '<WLANProfile />'
        $out = Invoke-FirstLogon -Test $t -WifiFails
        $out | Should -Match 'Не удалось добавить сеть Wi-Fi-Home \(код 1\)'
        $out | Should -Match 'Добавлено сетей: 0'
        Test-Path -LiteralPath $wifi | Should -BeFalse
        $out | Should -Match 'Установлено программ: 1'
    }

    It 'сеть не добавилась, а программы ещё ждут: файл сети остаётся закрытым до следующего входа' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        $wifi = Join-Path $t.Lunq 'Wifi'
        New-Item -ItemType Directory -Path $wifi -Force | Out-Null
        foreach ($name in 'Wi-Fi-Home', 'Wi-Fi-Office') { Set-Content -LiteralPath (Join-Path $wifi "$name.xml") -Value '<WLANProfile />' }
        $out = Invoke-FirstLogon -Test $t -WifiFails -Offline
        $out | Should -Match 'будут добавлены при следующем входе'
        @(Get-ChildItem -LiteralPath $wifi -Filter '*.xml').Count | Should -Be 2
        Test-Path -LiteralPath $t.Task | Should -BeTrue
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Добавлено сетей: 2'
        Test-Path -LiteralPath $wifi | Should -BeFalse
        Get-Lines $t.WingetLog | Should -Be @('7zip.7zip')
    }

    It 'зависшая установка прерывается, остальные программы ставятся, вывод winget виден' {
        $t = New-FirstLogonTest -Apps @('Slow.App', '7zip.7zip')
        Set-Content -LiteralPath (Join-Path $t.Root 'hang.txt') -Value 'Slow.App'
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Установка Slow\.App не закончилась за \d+ минут и прервана'
        $out | Should -Match 'Successfully installed 7zip\.7zip'
        $out | Should -Match 'Установлено программ: 1'
        Get-Lines (Join-Path $t.Lunq 'apps.installed') | Should -Be @('7zip.7zip')
        # Программа осталась неустановленной: следующий вход попробует снова.
        Test-Path -LiteralPath $t.Task | Should -BeTrue
    }

    It 'код «установлено, нужна перезагрузка» считается успехом' -Skip:(-not $script:OnWindows) {
        # Код 0x8A150109 отрицательный, такой код выхода есть только у программ Windows.
        $t = New-FirstLogonTest -Apps @('Reboot.App')
        Set-Content -LiteralPath (Join-Path $t.Root 'reboot.txt') -Value 'Reboot.App'
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Установлено программ: 1'
        Test-Path -LiteralPath $t.Task | Should -BeFalse
    }

    It 'нет установщика для всех пользователей: программа ставится для текущего' -Skip:(-not $script:OnWindows) {
        # Код 0x8A150010 отрицательный, такой код выхода есть только у программ Windows.
        $t = New-FirstLogonTest -Apps @('User.App', 'Mozilla.Firefox --scope user')
        Set-Content -LiteralPath (Join-Path $t.Root 'useronly.txt') -Value 'User.App'
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'User.App: установщика для всех пользователей нет'
        Get-Lines (Join-Path $t.Root 'scope.log') | Should -Be @('User.App machine', 'User.App ', 'Mozilla.Firefox user')
        Get-Lines (Join-Path $t.Lunq 'apps.installed') | Should -Be @('User.App', 'Mozilla.Firefox')
    }

    It 'учётная запись без пароля: пароль спрашивается дважды и задаётся, вопрос больше не повторяется' {
        $t = New-FirstLogonTest
        [IO.File]::WriteAllText((Join-Path $t.Lunq 'LocalAccount.txt'), 'Иван', (New-Object Text.UTF8Encoding($false)))
        Set-Content -LiteralPath (Join-Path $t.Root 'answers.txt') -Value @('секрет1', 'другой', 'секрет2', 'секрет2') -Encoding UTF8
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Пароль для Иван'
        $out | Should -Match 'Пароли не совпали'
        $out | Should -Match 'Пароль задан'
        $out | Should -Not -Match 'секрет'
        Get-Lines (Join-Path $t.Root 'setuser.log') | Should -Be @('Иван|секрет2')
        Test-Path -LiteralPath (Join-Path $t.Lunq 'LocalAccount.txt') | Should -BeFalse
    }

    It 'Enter вместо пароля оставляет учётную запись без пароля' {
        $t = New-FirstLogonTest
        [IO.File]::WriteAllText((Join-Path $t.Lunq 'LocalAccount.txt'), 'Иван', (New-Object Text.UTF8Encoding($false)))
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Пароль не задан'
        Test-Path -LiteralPath (Join-Path $t.Root 'setuser.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.Lunq 'LocalAccount.txt') | Should -BeFalse
    }

    It 'без отметки пароль не спрашивается' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        Set-Content -LiteralPath (Join-Path $t.Root 'answers.txt') -Value 'секрет' -Encoding UTF8
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Not -Match 'Пароль для'
        Test-Path -LiteralPath (Join-Path $t.Root 'setuser.log') | Should -BeFalse
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
        $powershell = Join-Path $t.Windows 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Get-Content -LiteralPath $t.Task | Should -Be @(
            'name: LunqFirstLogon',
            "action: $powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`"",
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
        $out | Should -Match '10-throw.ps1 завершился с кодом 1'
        $out | Should -Match 'сломалось'
        $out | Should -Match 'С ошибками: 10-throw.ps1'
    }

    It 'скрипт идёт в отдельном процессе в папке User' {
        # Скрипт пишет номер своего процесса и текущую папку в папку теста.
        $t = New-FirstLogonTest -Scripts @{
            '10-own.ps1' = "Set-Content -LiteralPath (Join-Path (Split-Path (Split-Path `$PSScriptRoot)) 'script.txt') -Value @(`$PID, (Get-Location).Path)"
            '20-fail.ps1' = 'exit 1'
        }
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'С ошибками: 20-fail.ps1'
        $lines = Get-Lines (Join-Path $t.Root 'script.txt')
        $lines[0] | Should -Not -Be (Get-Lines (Join-Path $t.Root 'pid.txt'))[0]
        $lines[1] | Should -Be $t.User
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

    It 'скрипт, который перезагружает компьютер, запускается не больше двух раз' {
        # Скрипт завершает процесс скрипта первого входа, как перезагрузка: отметка «выполнен»
        # не ставится. В Windows PowerShell 5.1 у Get-Process нет Parent, там родитель берётся из CIM.
        $reboot = 'if ($PSVersionTable.PSVersion.Major -ge 6) { $parent = (Get-Process -Id $PID).Parent.Id } ' +
            'else { $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId }; Stop-Process -Id $parent -Force'
        $t = New-FirstLogonTest -Scripts @{ '10-reboot.ps1' = $reboot }
        for ($i = 1; $i -le 2; $i++) {
            $out = Invoke-FirstLogon -Test $t
            $out | Should -Not -Match '==> Готово'
            Test-Path -LiteralPath $t.Task | Should -BeTrue
        }
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match '10-reboot.ps1 уже 2 раза начинался и не дошёл до конца'
        $out | Should -Match 'С ошибками: 10-reboot.ps1'
        Get-Lines (Join-Path $t.Lunq 'scripts.started') | Should -Be @('10-reboot.ps1', '10-reboot.ps1')
        Test-Path -LiteralPath $t.Task | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.User 'secret.txt') | Should -BeFalse
    }

    It 'попытки кончились, а задание осталось: работа не повторяется, за собой убрано' {
        # Пятая попытка не дошла до конца (например, её прервала перезагрузка), задание осталось.
        $t = New-FirstLogonTest -Apps @('7zip.7zip') -Scripts @{ '10-ok.ps1' = "Write-Host 'ok'" }
        Set-Content -LiteralPath (Join-Path $t.Lunq 'attempts.txt') -Value 5
        Set-Content -LiteralPath $t.Task -Value 'task'
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'не закончилась за 5 попыток и больше не повторяется'
        Get-Lines $t.WingetLog | Should -BeNullOrEmpty
        $out | Should -Not -Match '10-ok.ps1'
        Test-Path -LiteralPath $t.Task | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.User 'secret.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.User 'Apps.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $t.Windows 'System32\Sysprep\unattend.xml') | Should -BeFalse
    }

    It 'программы из профиля удаляются после программ в отдельном PowerShell, без меню, один раз' {
        $t = New-FirstLogonTest -Apps @('7zip.7zip')
        $log = Add-FakeUninstall -Test $t -ExitCode 0
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match '==> Удаление программ \(1\)'
        Get-Lines $log | Should -Be @('NonInteractive,UninstallEdge')
        Get-Lines (Join-Path $t.Lunq 'uninstall.done') | Should -Be @('MicrosoftEdge')
        # Всё сделано: скрипты удаления с диска убраны, как и копии своих скриптов.
        Test-Path -LiteralPath (Join-Path $t.Lunq 'Uninstall') | Should -BeFalse
        $out | Should -Not -Match 'С ошибками'
    }

    It 'пока программы не поставились, удаление ждёт: на замену Edge может ставиться браузер' {
        $t = New-FirstLogonTest -Apps @('Mozilla.Firefox')
        $log = Add-FakeUninstall -Test $t -ExitCode 0
        $out = Invoke-FirstLogon -Test $t -Offline
        $out | Should -Match 'Удаление программ \(1\) выполнится после установки программ'
        Test-Path -LiteralPath $log | Should -BeFalse
        $out = Invoke-FirstLogon -Test $t
        Get-Lines $log | Should -Be @('NonInteractive,UninstallEdge')
    }

    It 'скрипт удаления, дважды не дошедший до конца, больше не запускается' {
        $t = New-FirstLogonTest
        $log = Add-FakeUninstall -Test $t -ExitCode 0
        Set-Content -LiteralPath (Join-Path $t.Lunq 'uninstall.started') -Value @('MicrosoftEdge', 'MicrosoftEdge') -Encoding UTF8
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Microsoft Edge уже 2 раза начинался и не дошёл до конца'
        Get-Lines $log | Should -BeNullOrEmpty
        Get-Lines (Join-Path $t.Lunq 'uninstall.done') | Should -Be @('MicrosoftEdge')
    }

    It 'скрипт удаления с ошибкой попадает в итог и повторно не запускается' {
        $t = New-FirstLogonTest
        $log = Add-FakeUninstall -Test $t -ExitCode 3
        $out = Invoke-FirstLogon -Test $t
        $out | Should -Match 'Не удалось удалить Microsoft Edge \(код 3\)'
        $out | Should -Match 'С ошибками: Microsoft Edge'
        Get-Lines (Join-Path $t.Lunq 'uninstall.done') | Should -Be @('MicrosoftEdge')
    }
}
