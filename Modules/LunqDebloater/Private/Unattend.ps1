function Get-LunqHostRegion {
    # Формат, раскладки и часовой пояс компьютера, на котором собирается образ: их получит и новая Windows.
    # Если что-то узнать не удалось, остаётся значение по умолчанию.
    $region = [pscustomobject]@{ Locale = 'en-US'; SystemLocale = 'en-US'; InputLocale = '0409:00000409'; Keyboards = @('en-US'); TimeZone = 'UTC' }
    try { $culture = (Get-Culture).Name; if ($culture) { $region.Locale = $culture; $region.SystemLocale = $culture } } catch { }
    # Язык программ, не поддерживающих Юникод (кодовая страница), задаётся отдельно от формата чисел
    # и дат: у пользователя с форматом en-US и русской кодовой страницей старые программы иначе
    # показали бы кракозябры.
    try { $system = (Get-WinSystemLocale -ErrorAction Stop).Name; if ($system) { $region.SystemLocale = $system } } catch { }
    try {
        $languages = @(Get-WinUserLanguageList -ErrorAction Stop)
        $tips = @($languages | ForEach-Object { @($_.InputMethodTips) } | Where-Object { $_ } | Select-Object -Unique)
        if ($tips.Count -gt 0) {
            $region.InputLocale = $tips -join ';'
            $region.Keyboards = @($languages | ForEach-Object { $_.LanguageTag })
        }
    }
    catch { }
    try { $zone = (Get-TimeZone).Id; if ($zone) { $region.TimeZone = $zone } } catch { }
    return $region
}

function Get-LunqImageLanguage {
    # Язык образа по умолчанию, например ru-RU, из Get-WindowsImage. $null, если его нет.
    param([Parameter(Mandatory)]$Image)
    if (-not $Image.PSObject.Properties['Languages'] -or @($Image.Languages).Count -eq 0) { return $null }
    $index = 0
    if ($Image.PSObject.Properties['DefaultLanguageIndex'] -and $Image.DefaultLanguageIndex -lt @($Image.Languages).Count) { $index = $Image.DefaultLanguageIndex }
    # Только сам код языка: при выводе к нему дописывается «(Default)».
    if ([string]@($Image.Languages)[$index] -match '^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*') { return $Matches[0] }
    return $null
}

# Имена, которые Windows уже занимает сама.
$script:ReservedAccountNames = 'Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount', 'defaultuser0', 'Администратор', 'Гость'

function Test-LunqAccountName {
    # Что не так с именем локальной учётной записи, или $null. Правила Windows: до 20 символов,
    # без "/\[]:;|=,+*?<>@, не из одних точек и пробелов. Апостроф и % тоже запрещены: имя
    # подставляется в команду PowerShell в файле ответов, а Setup раскрывает в ней переменные.
    param([AllowEmptyString()][string]$Name)
    if (-not $Name -or -not $Name.Trim()) { return Get-LunqText 'Unattend.NameEmpty' }
    if ($Name.Length -gt 20) { return Get-LunqText 'Unattend.NameTooLong' $Name }
    if ($Name -match '["/\\\[\]:;|=,+*?<>@''%]' -or $Name -match '[\x00-\x1F]') { return Get-LunqText 'Unattend.NameBadChars' $Name }
    if ($Name -match '^[.\s]+$' -or $Name -ne $Name.Trim() -or $Name.EndsWith('.')) { return Get-LunqText 'Unattend.NameBadForm' $Name }
    if ($script:ReservedAccountNames -contains $Name) { return Get-LunqText 'Unattend.NameReserved' $Name }
    return $null
}

function Read-LunqAccountName {
    # Имя учётной записи в пошаговом режиме. Enter берёт имя пользователя этого компьютера, «-»
    # оставляет имя и пароль установке Windows, как без -LocalAccountName.
    param([string]$Default)
    if (-not $Default -or (Test-LunqAccountName -Name $Default)) { $Default = 'User' }
    while ($true) {
        $answer = ([string](Read-Host ('    ' + (Get-LunqText 'Unattend.AskName' $Default)))).Trim()
        if (-not $answer) { return $Default }
        if ($answer -eq '-') { return '' }
        $problem = Test-LunqAccountName -Name $answer
        if (-not $problem) { return $answer }
        Write-Warning $problem
    }
}

function Get-LunqUnattendAccount {
    # Имя учётной записи, которую создаёт файл ответов, или пустая строка: тогда имя спросит OOBE.
    # Свойства AccountName может не быть: файлы ответов до 1.13.0 его не знали.
    param([Parameter(Mandatory)]$Unattend)
    if (-not $Unattend.LocalAccount -or -not $Unattend.PSObject.Properties['AccountName']) { return '' }
    return [string]$Unattend.AccountName
}

function Format-LunqUnattendSummary {
    # Одна строка о файле ответов для плана, итога и отметки о сборке.
    param([Parameter(Mandatory)]$Unattend)
    $parts = @()
    if ($Unattend.Oobe) { $parts += Get-LunqText 'Unattend.Oobe' }
    if ($Unattend.Region) { $parts += Get-LunqText 'Unattend.Region' $Unattend.Region.Locale $Unattend.Region.TimeZone }
    if ($Unattend.Bypass) { $parts += Get-LunqText 'Unattend.Bypass' }
    $account = Get-LunqUnattendAccount -Unattend $Unattend
    if ($account) { $parts += Get-LunqText 'Unattend.LocalAccountNamed' $account }
    elseif ($Unattend.LocalAccount) { $parts += Get-LunqText 'Unattend.LocalAccount' }
    return ($parts -join ', ')
}

# Создание учётной записи в specialize. {0}: имя, уже проверенное Test-LunqAccountName. Пароль не
# истекает, как у учётной записи, созданной в OOBE: иначе через 42 дня Windows потребовала бы новый.
$script:CreateAccountCommand = 'powershell.exe -NoProfile -Command "New-LocalUser -Name ''{0}'' -NoPassword -AccountNeverExpires | Set-LocalUser -PasswordNeverExpires $true; Add-LocalGroupMember -SID S-1-5-32-544 -Member ''{0}''"'

function New-LunqUnattendXml {
    # autounattend.xml для корня ISO. Windows Setup находит его на флешке, применяет на всех этапах
    # установки и сохраняет в Windows\Panther. Диск для установки по-прежнему выбирает человек.
    param(
        [Parameter(Mandatory)]$Unattend,
        [Parameter(Mandatory)][string]$Architecture,
        [string]$ImageLanguage,
        [string]$FirstLogonCommand
    )
    $e = { param($text) [Security.SecurityElement]::Escape([string]$text) }
    $account = Get-LunqUnattendAccount -Unattend $Unattend
    $systemLocale = $null
    if ($Unattend.Region) {
        $systemLocale = $Unattend.Region.Locale
        if ($Unattend.Region.PSObject.Properties['SystemLocale'] -and $Unattend.Region.SystemLocale) { $systemLocale = $Unattend.Region.SystemLocale }
    }
    $attrs = 'processorArchitecture="{0}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"' -f $Architecture
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<!-- Created by LunqDebloater: setup answer file. -->')
    $lines.Add('<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">')

    # windowsPE: язык установщика, лицензия, обход проверки требований.
    $lines.Add('  <settings pass="windowsPE">')
    # Первую страницу установщика (язык, формат, раскладка) Setup пропускает, только если заданы все её поля.
    if ($Unattend.Region -and $ImageLanguage) {
        $lines.Add("    <component name=`"Microsoft-Windows-International-Core-WinPE`" $attrs>")
        $lines.Add('      <SetupUILanguage>')
        $lines.Add("        <UILanguage>$(& $e $ImageLanguage)</UILanguage>")
        $lines.Add('      </SetupUILanguage>')
        $lines.Add("      <InputLocale>$(& $e $Unattend.Region.InputLocale)</InputLocale>")
        $lines.Add("      <SystemLocale>$(& $e $systemLocale)</SystemLocale>")
        $lines.Add("      <UILanguage>$(& $e $ImageLanguage)</UILanguage>")
        $lines.Add("      <UserLocale>$(& $e $Unattend.Region.Locale)</UserLocale>")
        $lines.Add('    </component>')
    }
    $lines.Add("    <component name=`"Microsoft-Windows-Setup`" $attrs>")
    if ($Unattend.Bypass) {
        $lines.Add('      <RunSynchronous>')
        $order = 0
        foreach ($value in 'BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck') {
            $order++
            $lines.Add('        <RunSynchronousCommand wcm:action="add">')
            $lines.Add("          <Order>$order</Order>")
            $lines.Add("          <Path>reg.exe add &quot;HKLM\SYSTEM\Setup\LabConfig&quot; /v $value /t REG_DWORD /d 1 /f</Path>")
            $lines.Add('        </RunSynchronousCommand>')
        }
        $lines.Add('      </RunSynchronous>')
    }
    # Ключ продукта и выбор редакции остаются как без файла ответов.
    $lines.Add('      <UserData>')
    $lines.Add('        <ProductKey>')
    $lines.Add('          <Key>00000-00000-00000-00000-00000</Key>')
    $lines.Add('          <WillShowUI>Always</WillShowUI>')
    $lines.Add('        </ProductKey>')
    $lines.Add("        <AcceptEula>$(([string][bool]$Unattend.Oobe).ToLower())</AcceptEula>")
    $lines.Add('      </UserData>')
    $lines.Add('      <UseConfigurationSet>false</UseConfigurationSet>')
    $lines.Add('    </component>')
    $lines.Add('  </settings>')

    if ($Unattend.Region -or $Unattend.LocalAccount) {
        $lines.Add('  <settings pass="specialize">')
        if ($Unattend.Region) {
            $lines.Add("    <component name=`"Microsoft-Windows-Shell-Setup`" $attrs>")
            $lines.Add("      <TimeZone>$(& $e $Unattend.Region.TimeZone)</TimeZone>")
            $lines.Add('    </component>')
        }
        if ($Unattend.LocalAccount) {
            # Запасной путь к локальной учётной записи: если OOBE всё же покажет вход в учётную запись
            # Майкрософт, BypassNRO добавляет на этот экран вариант «У меня нет Интернета».
            $lines.Add("    <component name=`"Microsoft-Windows-Deployment`" $attrs>")
            $lines.Add('      <RunSynchronous>')
            $lines.Add('        <RunSynchronousCommand wcm:action="add">')
            $lines.Add('          <Order>1</Order>')
            $lines.Add('          <Path>reg.exe add &quot;HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE&quot; /v BypassNRO /t REG_DWORD /d 1 /f</Path>')
            $lines.Add('        </RunSynchronousCommand>')
            if ($account) {
                # Учётная запись создаётся здесь, от SYSTEM, а не через UserAccounts\LocalAccounts: там
                # группа задаётся именем, а на русской Windows она называется «Администраторы», и с
                # именем Administrators пользователь стал бы обычным. Здесь группа берётся по SID.
                # Пароля нет: в ISO его не хранить, задать его предложит первый вход.
                $lines.Add('        <RunSynchronousCommand wcm:action="add">')
                $lines.Add('          <Order>2</Order>')
                $lines.Add("          <Path>$(& $e ($script:CreateAccountCommand -f $account))</Path>")
                $lines.Add('        </RunSynchronousCommand>')
            }
            $lines.Add('      </RunSynchronous>')
            $lines.Add('    </component>')
        }
        $lines.Add('  </settings>')
    }

    # oobeSystem: регион, вопросы при первом запуске и команда первого входа.
    $lines.Add('  <settings pass="oobeSystem">')
    if ($Unattend.Region) {
        $lines.Add("    <component name=`"Microsoft-Windows-International-Core`" $attrs>")
        $lines.Add("      <InputLocale>$(& $e $Unattend.Region.InputLocale)</InputLocale>")
        $lines.Add("      <SystemLocale>$(& $e $systemLocale)</SystemLocale>")
        if ($ImageLanguage) { $lines.Add("      <UILanguage>$(& $e $ImageLanguage)</UILanguage>") }
        $lines.Add("      <UserLocale>$(& $e $Unattend.Region.Locale)</UserLocale>")
        $lines.Add('    </component>')
    }
    $lines.Add("    <component name=`"Microsoft-Windows-Shell-Setup`" $attrs>")
    $lines.Add('      <OOBE>')
    if ($Unattend.Oobe) {
        # 3: все параметры конфиденциальности выключены, страница с ними не показывается.
        $lines.Add('        <ProtectYourPC>3</ProtectYourPC>')
        $lines.Add('        <HideEULAPage>true</HideEULAPage>')
    }
    # Без учётной записи Майкрософт OOBE сразу предлагает создать локальную.
    $lines.Add("        <HideOnlineAccountScreens>$(([string][bool]$Unattend.LocalAccount).ToLower())</HideOnlineAccountScreens>")
    # Учётная запись уже есть: экран создания локальной учётной записи не нужен.
    if ($account) { $lines.Add('        <HideLocalAccountScreen>true</HideLocalAccountScreen>') }
    $lines.Add('      </OOBE>')
    if ($FirstLogonCommand) {
        foreach ($line in (Get-LunqFirstLogonCommandsXml -Command $FirstLogonCommand -Indent '      ')) { $lines.Add($line) }
    }
    $lines.Add('    </component>')
    $lines.Add('  </settings>')
    $lines.Add('</unattend>')
    return ($lines -join "`r`n")
}

function Install-LunqUnattend {
    # Кладёт autounattend.xml в корень будущего ISO.
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)]$Unattend,
        [Parameter(Mandatory)][string]$Architecture,
        [string]$ImageLanguage,
        [switch]$WithFirstLogon
    )
    $result = New-LunqResult (Get-LunqText 'Unattend.Title') 'Unattend'
    $path = Join-Path $IsoRoot 'autounattend.xml'
    if (Test-Path -LiteralPath $path) { throw (Get-LunqText 'Unattend.Exists') }
    $command = $null
    if ($WithFirstLogon) { $command = $script:FirstLogonCommand }
    $xml = New-LunqUnattendXml -Unattend $Unattend -Architecture $Architecture -ImageLanguage $ImageLanguage -FirstLogonCommand $command
    # Проверка, что получился корректный XML.
    [void][xml]$xml
    [IO.File]::WriteAllText($path, $xml, (New-Object Text.UTF8Encoding($false)))
    $summary = Format-LunqUnattendSummary -Unattend $Unattend
    if ($WithFirstLogon) { $summary = Get-LunqText 'Unattend.WithFirstLogon' $summary }
    $result.Summary = $summary
    Write-Info "autounattend.xml: $summary"
    if (-not $ImageLanguage -and $Unattend.Region) { Write-Warning (Get-LunqText 'Unattend.NoImageLanguage') }
    return $result
}
