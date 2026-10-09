#Requires -Version 5.1
<#
    LunqDebloater: функции офлайн-преднастройки образа Windows 11.
    Все операции выполняются над смонтированным install.wim через модуль DISM
    и reg.exe, поэтому работают только на Windows и с правами администратора.

    Функции разложены по файлам в папке Private по темам: вывод в консоль, профиль, ISO,
    проверки, обслуживание образа, реестр, файл ответов, первый вход, итог.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot

# Версия LunqDebloater задаётся в манифесте. Она видна в заголовке окна, в логе, в итоге
# и в реестре собранного образа.
$script:LunqVersion = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'LunqDebloater.psd1')).ModuleVersion

foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $file.FullName
}

# Язык по умолчанию берётся из системы. Скрипт переключает его параметром -Language.
Set-LunqLanguage -Language (Get-LunqDefaultLanguage)
