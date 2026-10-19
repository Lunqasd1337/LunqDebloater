# LunqDebloater: удаление Microsoft Edge его собственным установщиком.
# Запускается из FirstLogon.ps1 при первом входе и из LunqDebloater.ps1 -Online, без модуля.
# Только установщик убирает Edge целиком: запись в «Программах», ClientState в EdgeUpdate и
# регистрацию приложения. Если просто стереть файлы (DISM /Remove-Edge), записи остаются, и
# Microsoft Store показывает Edge установленным. WebView2 не трогается: на нём работают виджеты,
# новый Outlook, Teams и многие программы.
# Вне ЕЭЗ установщик отказывается без AllowUninstall в EdgeUpdateDev: это значение пишет
# категория профиля edge. Возвращает объект: Status (Removed, NotInstalled, Failed) и ExitCode.
param(
    [string]$EdgeDir,
    [string]$UninstallKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
    [string[]]$Shortcuts,
    # Как запустить установщик: тесты подменяют его. Возвращает код выхода.
    [scriptblock]$Runner = { param($Path, $Arguments) (Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden).ExitCode }
)

# Значения по умолчанию здесь, а не в param(): вне Windows этих переменных окружения нет.
if (-not $EdgeDir) { $EdgeDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge' }
if ($null -eq $Shortcuts) {
    $Shortcuts = @(
        (Join-Path $env:PUBLIC 'Desktop\Microsoft Edge.lnk'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'),
        (Join-Path $env:USERPROFILE 'Desktop\Microsoft Edge.lnk'))
}

function Remove-EdgeLeftovers([string]$Key, [string[]]$Links) {
    # Запись в «Программах» без самого Edge и есть то, по чему Store считает его установленным.
    if (Test-Path -LiteralPath $Key) { Remove-Item -LiteralPath $Key -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($shortcut in $Links) {
        if ($shortcut -and (Test-Path -LiteralPath $shortcut)) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue }
    }
}

$application = Join-Path $EdgeDir 'Application'
$exe = Join-Path $application 'msedge.exe'
# Установщик лежит в папке версии: Application\<версия>\Installer\setup.exe. Берётся самый новый.
$setup = @(Get-ChildItem -LiteralPath $application -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+)+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'Installer\setup.exe') -PathType Leaf) } |
        Sort-Object { [version]$_.Name } -Descending | ForEach-Object { Join-Path $_.FullName 'Installer\setup.exe' })

if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -and $setup.Count -eq 0) {
    Remove-EdgeLeftovers $UninstallKey $Shortcuts
    return [pscustomobject]@{ Status = 'NotInstalled'; ExitCode = 0 }
}
if ($setup.Count -eq 0) { return [pscustomobject]@{ Status = 'Failed'; ExitCode = -1 } }

# Запущенный Edge держит свои файлы, и установщик оставил бы их на месте.
Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$code = [int](& $Runner $setup[0] @('--uninstall', '--system-level', '--force-uninstall'))

# Код выхода установщика Edge разный у разных версий, поэтому удаление проверяется по файлу.
if (Test-Path -LiteralPath $exe -PathType Leaf) { return [pscustomobject]@{ Status = 'Failed'; ExitCode = $code } }
Remove-EdgeLeftovers $UninstallKey $Shortcuts
return [pscustomobject]@{ Status = 'Removed'; ExitCode = $code }
