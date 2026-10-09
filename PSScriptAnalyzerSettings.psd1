@{
    # Настройки PSScriptAnalyzer для проверки в GitHub Actions и локально:
    #   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Скрипт консольный: цветной вывод через Write-Host нужен намеренно.
        'PSAvoidUsingWriteHost',
        # Имена вроде Add-LunqUpdates и Dismount-OfflineHives понятнее в единственном числе не станут.
        'PSUseSingularNouns',
        # -WhatIf внутренним функциям не нужен: подтверждение спрашивает сам скрипт перед сборкой.
        'PSUseShouldProcessForStateChangingFunctions',
        # Пустые catch оставлены там, где ошибка не важна (заголовок окна, запасные значения);
        # в каждом таком месте есть комментарий почему.
        'PSAvoidUsingEmptyCatchBlock'
    )
    Rules        = @{
        # Скрипт работает в Windows PowerShell 5.1: синтаксис новее него не годится.
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        # Синтаксис не всё: параметры вроде ConvertFrom-Json -AsHashtable в 5.1 тоже нет.
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
