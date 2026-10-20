#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Удаление программ из поля Uninstall профиля (Private\Uninstall.ps1): запуск скриптов из
# ThirdParty на этой Windows и их раскладка в образ для первого входа.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    # Проверки сверяют русский текст.
    Set-LunqLanguage -Language ru
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Remove-LunqPrograms' {
    It 'запускает скрипт из ThirdParty в отдельном PowerShell без меню, удалённое запоминает для отката' {
        InModuleScope LunqDebloater {
            Mock Write-Info { }
            Mock Write-Warning { }
            Mock Invoke-Native { 0 }
            $restore = New-LunqRestoreData -LunqProfile ([pscustomobject]@{ Categories = @([pscustomobject]@{ Id = 'edge'; Name = 'Microsoft Edge'; Enabled = $true; Uninstall = @('MicrosoftEdge') }) }) -Source Online
            $r = Remove-LunqPrograms -Config ([pscustomobject]@{ Uninstall = @('MicrosoftEdge') }) -Restore $restore
            @($r.Done) | Should -Be @('Microsoft Edge')
            $r.Summary | Should -Be 'удалено 1, ошибок 0'
            Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter {
                $FilePath -like '*powershell.exe' -and $Arguments[3] -eq '-File' -and $Arguments[4] -like '*ThirdParty*EdgeRemover*RemoveEdge.ps1' -and
                (($Arguments | Select-Object -Skip 5) -join ' ') -eq '-UninstallEdge -NonInteractive'
            }
            Test-Path -LiteralPath (Join-Path (Get-LunqThirdPartyRoot) 'EdgeRemover\RemoveEdge.ps1') | Should -BeTrue
            @($restore.Categories | ForEach-Object { $_.Id }) | Should -Be @('edge')
            @($restore.Categories[0].Uninstall | ForEach-Object { $_.Name }) | Should -Be @('MicrosoftEdge')
        }
    }

    It 'скрипт удаления завершился с ошибкой: это в итоге, а в данные для отката не попадает' {
        InModuleScope LunqDebloater {
            Mock Write-Info { }
            Mock Write-Warning { }
            Mock Invoke-Native { 1 }
            $restore = New-LunqRestoreData -LunqProfile ([pscustomobject]@{ Categories = @() }) -Source Online
            $r = Remove-LunqPrograms -Config ([pscustomobject]@{ Uninstall = @('MicrosoftEdge') }) -Restore $restore
            @($r.Failed) | Should -Be @('Microsoft Edge')
            $r.Summary | Should -Be 'удалено 0, ошибок 1'
            $restore.Categories.Count | Should -Be 0
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*Microsoft Edge*код 1*' }
        }
    }
}

Describe 'Copy-LunqUninstallers' {
    It 'кладёт скрипт вместе с его папкой и Uninstall.json: что запустить и с какими параметрами' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $target = Join-Path $Root 'Uninstall'
            Copy-LunqUninstallers -Destination $target -Names @('MicrosoftEdge')
            Test-Path -LiteralPath (Join-Path $target 'EdgeRemover\RemoveEdge.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $target 'EdgeRemover\LICENSE') | Should -BeTrue
            $json = Get-Content -LiteralPath (Join-Path $target 'Uninstall.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            @($json.Programs).Count | Should -Be 1
            $json.Programs[0].Name | Should -Be 'MicrosoftEdge'
            $json.Programs[0].Title | Should -Be 'Microsoft Edge'
            $json.Programs[0].Script | Should -Be 'EdgeRemover\RemoveEdge.ps1'
            @($json.Programs[0].Arguments) | Should -Be @('-UninstallEdge', '-NonInteractive')
        }
    }

    It 'у EdgeRemover есть параметры, с которыми его запускают удаление и откат' {
        # Обновлённый EdgeRemover без этих параметров открыл бы меню и ждал клавишу.
        $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'ThirdParty\EdgeRemover\RemoveEdge.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { '-' + $_.Name.VariablePath.UserPath })
        $used = & (Get-Module LunqDebloater) { @($script:LunqUninstallers['MicrosoftEdge'].Remove) + @($script:LunqUninstallers['MicrosoftEdge'].Restore) | Select-Object -Unique }
        foreach ($argument in $used) { $names | Should -Contain $argument }
    }
}

Describe 'ThirdParty\EdgeRemover' {
    It 'RemoveEdge.ps1 совпадает с версией из SOURCE.txt: тот же файл автора, только с BOM и CRLF' {
        $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'ThirdParty\EdgeRemover'
        $source = Get-Content -LiteralPath (Join-Path $dir 'SOURCE.txt') -Encoding UTF8
        $field = { param($pattern) (@($source | Where-Object { $_ -match $pattern }) | Select-Object -First 1) -replace '^.*:\s*', '' }
        $version = (& $field '^Версия:').Trim()
        $upstreamHash = (& $field '^SHA256 исходного файла').Trim()
        $version | Should -Match '^\d+\.\d+\.\d+$'
        $script = Join-Path $dir 'RemoveEdge.ps1'
        # Версия в самом скрипте та же, что записана в SOURCE.txt.
        Select-String -LiteralPath $script -Pattern ("^\`$version = '" + [regex]::Escape($version) + "'") -Quiet | Should -BeTrue
        # Сумма считается без BOM и с LF, как у файла в репозитории автора: так она не зависит от
        # того, как git выписал окончания строк.
        $bytes = [IO.File]::ReadAllBytes($script)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $bytes = $bytes[3..($bytes.Length - 1)] }
        $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes).Replace("`r`n", "`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = -join ($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
        $hash | Should -Be $upstreamHash
    }
}
