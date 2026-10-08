# Язык интерфейса. Все тексты для консоли, лога и ошибок лежат в таблицах
# Strings\<язык>\*.psd1: ключ «Область.Имя» и строка для оператора -f.
$script:LunqLanguages = @('ru', 'en')
$script:LunqLanguage = 'ru'
$script:LunqStrings = @{}

function Get-LunqDefaultLanguage {
    # Русский на русской Windows, английский на любой другой.
    $name = ''
    try { $name = (Get-UICulture).TwoLetterISOLanguageName } catch { }   # язык системы не узнать: английский
    if ($name -eq 'ru') { return 'ru' }
    return 'en'
}

function Import-LunqStrings {
    # Собирает все таблицы строк одного языка в одну. Повтор ключа считается ошибкой.
    param([Parameter(Mandatory)][string]$Language)
    $folder = Join-Path $script:ModuleRoot "Strings\$Language"
    $strings = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.psd1' -File | Sort-Object Name)) {
        $table = Import-PowerShellDataFile -LiteralPath $file.FullName
        foreach ($key in $table.Keys) {
            if ($strings.ContainsKey($key)) { throw "String '$key' is defined twice ($Language, $($file.Name))." }
            $strings[$key] = $table[$key]
        }
    }
    return $strings
}

function Set-LunqLanguage {
    param([Parameter(Mandatory)][ValidateSet('ru', 'en')][string]$Language)
    $script:LunqStrings = Import-LunqStrings -Language $Language
    $script:LunqLanguage = $Language
}

function Get-LunqLanguage {
    return $script:LunqLanguage
}

function Get-LunqText {
    # Строка интерфейса по ключу. Строка всегда проходит через -f, поэтому фигурные скобки
    # в самом тексте пишутся удвоенными: {{ и }}.
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1, ValueFromRemainingArguments)][object[]]$Arguments
    )
    $text = $script:LunqStrings[$Key]
    if ($null -eq $text) { throw "String '$Key' is missing for language '$($script:LunqLanguage)'." }
    if ($null -eq $Arguments) { $Arguments = @() }
    return ($text -f $Arguments)
}

function Get-LunqLocalized {
    # Текст из профиля: либо строка, либо объект с переводами { "ru": "...", "en": "..." }.
    # Берётся текущий язык, затем английский, затем первый попавшийся.
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $properties = @($Value.PSObject.Properties)
    foreach ($name in @($script:LunqLanguage, 'en')) {
        $match = $properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($match) { return [string]$match.Value }
    }
    if ($properties.Count -gt 0) { return [string]$properties[0].Value }
    return [string]$Value
}
