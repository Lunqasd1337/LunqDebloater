# Общие функции тестов: копия скрипта с заглушками и запуск сборки.

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:OnWindows = $env:OS -eq 'Windows_NT'

function New-LunqTestApp {
    # Копирует скрипт в папку теста и добавляет заглушки. Возвращает пути, с которыми работает тест.
    param([Parameter(Mandatory)][string]$Root)

    $app = Join-Path $Root 'app'
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    foreach ($item in 'LunqDebloater.ps1', 'Modules', 'Config') {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $item) -Destination $app -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Mocks\TestMocks.ps1') -Destination (Join-Path $app 'Modules\LunqDebloater\Private\ZZ.TestMocks.ps1')

    # Вне Windows PowerShell 5.1 (например, PowerShell 7 на Linux) скрипт перезапустил бы себя
    # в powershell.exe или отказался бы работать, поэтому в копии эти проверки выключаются.
    if ($PSVersionTable.PSEdition -eq 'Core' -or -not $script:OnWindows) {
        $main = Join-Path $app 'LunqDebloater.ps1'
        $text = [IO.File]::ReadAllText($main)
        $text = $text.Replace("if (`$env:OS -ne 'Windows_NT') {", 'if ($false) {').Replace("if (`$PSVersionTable.PSEdition -eq 'Core') {", 'if ($false) {')
        [IO.File]::WriteAllText($main, $text, (New-Object Text.UTF8Encoding($true)))
    }

    $iso = Join-Path $Root 'Win11.iso'
    Set-Content -LiteralPath $iso -Value 'iso'

    $updates = Join-Path $Root 'updates'
    New-Item -ItemType Directory -Path $updates -Force | Out-Null
    foreach ($name in 'windows11.0-kb5080000-x64.msu', 'windows11.0-kb5079999-x64.msu', 'windows11.0-kb5080001-x64-ndp481.msu') {
        Set-Content -LiteralPath (Join-Path $updates $name) -Value 'msu'
    }

    $drivers = Join-Path $Root 'drivers'
    foreach ($driver in @(@('net', 'Net'), @('rst', 'SCSIAdapter'), @('bad', 'Display'))) {
        $folder = Join-Path $drivers $driver[0]
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder "$($driver[0]).inf") -Value "[Version]`r`nClass=$($driver[1])"
    }

    return [pscustomobject]@{
        Root      = $Root
        App       = $app
        Script    = Join-Path $app 'LunqDebloater.ps1'
        Iso       = $iso
        OutputIso = Join-Path $Root 'Win11_Lunq.iso'
        WorkDir   = Join-Path $Root 'work'
        Updates   = $updates
        Drivers   = $drivers
        NativeLog = Join-Path $Root 'native.log'
        RegLog    = Join-Path $Root 'reg.log'
    }
}

function Enter-LunqTestEnvironment {
    # Переменные окружения для заглушек. Exit-LunqTestEnvironment возвращает всё как было.
    param([Parameter(Mandatory)]$Test)
    $script:SavedEnvironment = @{}
    foreach ($name in 'PSModulePath', 'SystemDrive', 'OS', 'LUNQ_TEST_ROOT', 'LUNQ_TEST_ISO', 'LUNQ_TEST_NATIVE_LOG', 'LUNQ_TEST_REG_LOG') {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:PSModulePath = (Join-Path $PSScriptRoot 'Mocks') + [IO.Path]::PathSeparator + $env:PSModulePath
    if (-not $env:SystemDrive) { $env:SystemDrive = $Test.Root }
    if (-not $script:OnWindows) { $env:OS = 'Windows_NT' }
    $env:LUNQ_TEST_ROOT = $Test.Root
    $env:LUNQ_TEST_ISO = $Test.Iso
    $env:LUNQ_TEST_NATIVE_LOG = $Test.NativeLog
    $env:LUNQ_TEST_REG_LOG = $Test.RegLog
    Remove-Module Dism, LunqDebloater -Force -ErrorAction SilentlyContinue
}

function Exit-LunqTestEnvironment {
    foreach ($name in $script:SavedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name])
    }
    foreach ($name in 'LUNQ_TEST_MOUNTED', 'LUNQ_TEST_DISM_EXIT', 'LUNQ_TEST_HOST_BUILD', 'LUNQ_TEST_NOT_ADMIN', 'LUNQ_TEST_ISO_ATTACHED', 'LUNQ_TEST_IMAGE_VERSION', 'LUNQ_TEST_FAIL_APPX') {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    Remove-Module Dism, LunqDebloater -Force -ErrorAction SilentlyContinue
    Remove-Item function:global:Read-Host, function:global:Start-Process -ErrorAction SilentlyContinue
}

function Invoke-LunqTestRun {
    # Запускает копию скрипта в этом же процессе и возвращает весь вывод одной строкой.
    # Ошибка сборки (throw в скрипте) попадает в Error, вывод до неё сохраняется.
    param([Parameter(Mandatory)]$Test, [hashtable]$Parameters = @{}, [string[]]$Answers)

    if ($PSBoundParameters.ContainsKey('Answers')) {
        # Пошаговый режим: Read-Host отвечает по очереди из списка, дальше пустой строкой (Enter).
        $global:LunqTestAnswers = New-Object System.Collections.Generic.Queue[string]
        foreach ($a in $Answers) { $global:LunqTestAnswers.Enqueue($a) }
        function global:Read-Host {
            param($Prompt, [switch]$AsSecureString)
            $answer = if ($global:LunqTestAnswers.Count -gt 0) { $global:LunqTestAnswers.Dequeue() } else { '' }
            Write-Host "$Prompt> [$answer]"
            return $answer
        }
    }
    function global:Start-Process { Write-Host "    [mock] Start-Process $args" }
    # Проверки сверяют русский текст, если тест сам не выбрал язык.
    if (-not $Parameters.ContainsKey('Language')) { $Parameters = $Parameters.Clone(); $Parameters['Language'] = 'ru' }

    $errorRecord = $null
    $lines = New-Object System.Collections.Generic.List[string]
    try { & $Test.Script @Parameters *>&1 | ForEach-Object { $lines.Add(($_ | Out-String -Width 400).TrimEnd()) } }
    catch { $errorRecord = $_ }
    return [pscustomobject]@{ Output = ($lines -join "`n"); Error = $errorRecord }
}

function Get-LunqStepNumbers {
    # Все «Шаг N из M» из вывода: проверка, что шаги идут подряд и счётчик верный.
    param([Parameter(Mandatory)][string]$Output)
    return @([regex]::Matches($Output, 'Шаг (\d+) из (\d+)') | ForEach-Object { [pscustomobject]@{ N = [int]$_.Groups[1].Value; M = [int]$_.Groups[2].Value } })
}
