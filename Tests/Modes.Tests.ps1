#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Режимы LunqDebloater.ps1, вынесенные в Private\Modes.ps1: список категорий и рецепт.

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

    It 'с -OutputIso или -OutputName в командной строке имя и путь ISO из рецепта не берутся' {
        InModuleScope LunqDebloater {
            Mock Get-LunqRecipeParameters { [ordered]@{ IsoPath = 'D:\win.iso'; OutputName = 'Win11_Lunq' } }
            $r = Resolve-LunqRecipeParameters -Recipe ([pscustomobject]@{}) -BoundParameters @{ OutputIso = 'E:\out.iso' }
            $r.Values.Contains('OutputName') | Should -BeFalse
            Mock Get-LunqRecipeParameters { [ordered]@{ IsoPath = 'D:\win.iso'; OutputIso = 'D:\old.iso' } }
            $r = Resolve-LunqRecipeParameters -Recipe ([pscustomobject]@{}) -BoundParameters @{ OutputName = 'Office' }
            $r.Values.Contains('OutputIso') | Should -BeFalse
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
