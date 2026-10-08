function Get-LunqHostRegion {
    # Формат, раскладки и часовой пояс компьютера, на котором собирается образ: их получит и новая Windows.
    # Если что-то узнать не удалось, остаётся значение по умолчанию.
    $region = [pscustomobject]@{ Locale = 'en-US'; InputLocale = '0409:00000409'; Keyboards = @('en-US'); TimeZone = 'UTC' }
    try { $culture = (Get-Culture).Name; if ($culture) { $region.Locale = $culture } } catch { }
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

function Format-LunqUnattendSummary {
    # Одна строка о файле ответов для плана, итога и отметки о сборке.
    param([Parameter(Mandatory)]$Unattend)
    $parts = @()
    if ($Unattend.Oobe) { $parts += Get-LunqText 'Unattend.Oobe' }
    if ($Unattend.Region) { $parts += Get-LunqText 'Unattend.Region' $Unattend.Region.Locale $Unattend.Region.TimeZone }
    if ($Unattend.Bypass) { $parts += Get-LunqText 'Unattend.Bypass' }
    if ($Unattend.LocalAccount) { $parts += Get-LunqText 'Unattend.LocalAccount' }
    return ($parts -join ', ')
}

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
        $lines.Add("      <SystemLocale>$(& $e $Unattend.Region.Locale)</SystemLocale>")
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

    if ($Unattend.Region) {
        $lines.Add('  <settings pass="specialize">')
        $lines.Add("    <component name=`"Microsoft-Windows-Shell-Setup`" $attrs>")
        $lines.Add("      <TimeZone>$(& $e $Unattend.Region.TimeZone)</TimeZone>")
        $lines.Add('    </component>')
        $lines.Add('  </settings>')
    }

    # oobeSystem: регион, вопросы при первом запуске и команда первого входа.
    $lines.Add('  <settings pass="oobeSystem">')
    if ($Unattend.Region) {
        $lines.Add("    <component name=`"Microsoft-Windows-International-Core`" $attrs>")
        $lines.Add("      <InputLocale>$(& $e $Unattend.Region.InputLocale)</InputLocale>")
        $lines.Add("      <SystemLocale>$(& $e $Unattend.Region.Locale)</SystemLocale>")
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
    $lines.Add('      </OOBE>')
    if ($FirstLogonCommand) {
        $lines.Add('      <FirstLogonCommands>')
        $lines.Add('        <SynchronousCommand wcm:action="add">')
        $lines.Add('          <Order>1</Order>')
        $lines.Add("          <CommandLine>$(& $e $FirstLogonCommand)</CommandLine>")
        $lines.Add('          <Description>LunqDebloater first logon</Description>')
        $lines.Add('        </SynchronousCommand>')
        $lines.Add('      </FirstLogonCommands>')
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
