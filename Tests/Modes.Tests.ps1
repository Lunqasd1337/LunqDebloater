#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Режимы LunqDebloater.ps1, вынесенные в Private\Modes.ps1: список категорий, рецепт, расписание.

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'Mocks\Dism\Dism.psm1') -Force
    Import-Module (Join-Path $repo 'Modules\LunqDebloater\LunqDebloater.psd1') -Force
    Set-LunqLanguage -Language ru
}

AfterAll {
    Remove-Module LunqDebloater, Dism -Force -ErrorAction SilentlyContinue
}

Describe 'Split-LunqIdList' {
    It 'делит строку из -File по запятым и убирает пробелы и пустые части' {
        InModuleScope LunqDebloater {
            $ids = Split-LunqIdList @('apps, telemetry', ',ai,')
            $ids | Should -Be @('apps', 'telemetry', 'ai')
        }
    }

    It 'для пустого списка возвращает пустой массив, а не $null' {
        InModuleScope LunqDebloater {
            $ids = Split-LunqIdList $null
            , $ids | Should -BeOfType [object[]]
            $ids.Count | Should -Be 0
        }
    }
}

Describe 'Resolve-LunqRecipeParameters' {
    BeforeEach {
        $script:RecipeValues = [ordered]@{ IsoPath = 'D:\win.iso'; Index = 6; Category = @('apps'); SkipAppx = $true }
    }

    It 'берёт из рецепта только то, что не задано в командной строке' {
        InModuleScope LunqDebloater -Parameters @{ RecipeValues = $script:RecipeValues } {
            Mock Get-LunqRecipeParameters { $RecipeValues }
            $r = Resolve-LunqRecipeParameters -Recipe ([pscustomobject]@{}) -BoundParameters @{ IsoPath = 'E:\new.iso' }
            @($r.Values.Keys) | Should -Be @('Index', 'Category', 'SkipAppx')
            $r.Values.Index | Should -Be 6
            $r.CategoryFromRecipe | Should -BeTrue
        }
    }

    It 'с -Edition не берёт индекс из рецепта, с -SkipCategory не берёт категории' {
        InModuleScope LunqDebloater -Parameters @{ RecipeValues = $script:RecipeValues } {
            Mock Get-LunqRecipeParameters { $RecipeValues }
            $r = Resolve-LunqRecipeParameters -Recipe ([pscustomobject]@{}) -BoundParameters @{ Edition = 'Pro'; SkipCategory = @('ai') }
            $r.Values.Contains('Index') | Should -BeFalse
            $r.Values.Contains('Category') | Should -BeFalse
            $r.CategoryFromRecipe | Should -BeFalse
            $r.Values.IsoPath | Should -Be 'D:\win.iso'
        }
    }

    It 'принимает $PSBoundParameters скрипта' {
        InModuleScope LunqDebloater -Parameters @{ RecipeValues = $script:RecipeValues } {
            Mock Get-LunqRecipeParameters { $RecipeValues }
            function Get-Bound { param([string]$IsoPath, [int]$Index) $PSBoundParameters }
            $r = Resolve-LunqRecipeParameters -Recipe ([pscustomobject]@{}) -BoundParameters (Get-Bound -Index 2)
            $r.Values.Contains('Index') | Should -BeFalse
            $r.Values.IsoPath | Should -Be 'D:\win.iso'
        }
    }
}

Describe 'Invoke-LunqScheduleMode' {
    It 'без рецепта не создаёт задание и объясняет почему' {
        InModuleScope LunqDebloater {
            Mock Register-LunqSchedule { }
            { Invoke-LunqScheduleMode -Schedule Monthly -SourceRoot 'C:\Lunq' -ConfigPath 'C:\Lunq\Config' } |
                Should -Throw (Get-LunqText 'Main.ScheduleNeedsRecipe')
            Should -Invoke Register-LunqSchedule -Times 0
        }
    }

    It 'Off удаляет задание, рецепт не читает' {
        InModuleScope LunqDebloater {
            Mock Unregister-LunqSchedule { }
            Mock Read-LunqRecipe { throw 'не должен читаться' }
            Invoke-LunqScheduleMode -Schedule Off -RecipePath 'C:\r.json' -SourceRoot 'C:\Lunq' -ConfigPath 'C:\Lunq\Config'
            Should -Invoke Unregister-LunqSchedule -Times 1 -Exactly -ParameterFilter { $RecipePath -eq 'C:\r.json' }
        }
    }

    It 'берёт папку настроек из рецепта, если она есть и не задана в командной строке' {
        InModuleScope LunqDebloater -Parameters @{ Dir = $TestDrive } {
            Mock Read-LunqRecipe { [pscustomobject]@{ ConfigPath = $Dir } }
            Mock Register-LunqSchedule { }
            Invoke-LunqScheduleMode -Schedule Monthly -RecipePath 'C:\r.json' -SourceRoot 'C:\Lunq' -ConfigPath 'C:\Lunq\Config'
            Should -Invoke Register-LunqSchedule -Times 1 -Exactly -ParameterFilter { $ConfigPath -eq $Dir }
            Invoke-LunqScheduleMode -Schedule Monthly -RecipePath 'C:\r.json' -SourceRoot 'C:\Lunq' -ConfigPath 'C:\Lunq\Config' -ConfigFromCommandLine
            Should -Invoke Register-LunqSchedule -Times 1 -Exactly -ParameterFilter { $ConfigPath -eq 'C:\Lunq\Config' }
        }
    }

    It 'папку настроек из рецепта, которой нет, не берёт' {
        InModuleScope LunqDebloater -Parameters @{ Dir = (Join-Path $TestDrive 'нет') } {
            Mock Read-LunqRecipe { [pscustomobject]@{ ConfigPath = $Dir } }
            Mock Register-LunqSchedule { }
            Invoke-LunqScheduleMode -Schedule Monthly -RecipePath 'C:\r.json' -SourceRoot 'C:\Lunq' -ConfigPath 'C:\Lunq\Config'
            Should -Invoke Register-LunqSchedule -Times 1 -Exactly -ParameterFilter { $ConfigPath -eq 'C:\Lunq\Config' }
        }
    }
}
