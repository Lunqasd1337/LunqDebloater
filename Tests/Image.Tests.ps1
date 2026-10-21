#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Образ и ISO на диске (Private\Image.ps1): экспорт и пересжатие install.wim.

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

Describe 'Export-SingleEdition' {
    It 'пересжатие на месте заменяет install.wim готовым файлом' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $wim = Join-Path $Root 'inplace.wim'
            Set-Content -LiteralPath $wim -Value 'old'
            Mock Export-WindowsImage { Set-Content -LiteralPath $DestinationImagePath -Value 'new' }
            Export-SingleEdition -SourceImage $wim -SourceIndex 1 -DestinationImage $wim
            Get-Content -LiteralPath $wim | Should -Be 'new'
            Test-Path -LiteralPath "$wim.tmp" | Should -BeFalse
            Should -Invoke Export-WindowsImage -Times 1 -Exactly -ParameterFilter { $CompressionType -eq 'Max' -and $CheckIntegrity }
        }
    }

    It 'если готовый файл не встал на место, прежний install.wim остаётся' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $wim = Join-Path $Root 'locked.wim'
            Set-Content -LiteralPath $wim -Value 'serviced'
            Mock Export-WindowsImage { Set-Content -LiteralPath $DestinationImagePath -Value 'new' }
            Mock Set-LunqFileFromTemp { throw 'file is locked' }
            { Export-SingleEdition -SourceImage $wim -SourceIndex 1 -DestinationImage $wim } | Should -Throw '*locked*'
            Get-Content -LiteralPath $wim | Should -Be 'serviced'
        }
    }

    It 'экспорт с ISO оставляет источник и создаёт новый файл' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $source = Join-Path $Root 'install.esd'
            $target = Join-Path $Root 'export\install.wim'
            Set-Content -LiteralPath $source -Value 'esd'
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Mock Export-WindowsImage { Set-Content -LiteralPath $DestinationImagePath -Value 'wim' }
            Export-SingleEdition -SourceImage $source -SourceIndex 5 -DestinationImage $target -CompressionType Fast -KeepSource
            Test-Path -LiteralPath $source | Should -BeTrue
            Get-Content -LiteralPath $target | Should -Be 'wim'
        }
    }
}

Describe 'Optimize-LunqWim' {
    It 'пересобирает все образы WIM и помечает загрузочный' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $wim = Join-Path $Root 'boot.wim'
            Set-Content -LiteralPath $wim -Value 'old'
            Mock Get-WindowsImage { @([pscustomobject]@{ ImageIndex = 2 }, [pscustomobject]@{ ImageIndex = 1 }) }
            Mock Export-WindowsImage { Add-Content -LiteralPath $DestinationImagePath -Value "image $SourceIndex" }
            Optimize-LunqWim -Path $wim -BootIndex 2
            @(Get-Content -LiteralPath $wim) | Should -Be @('image 1', 'image 2')
            Should -Invoke Export-WindowsImage -Times 1 -Exactly -ParameterFilter { $SourceIndex -eq 2 -and $SetBootable }
        }
    }
}

Describe 'install.wim и флешка FAT32' {
    It 'install.wim больше 4 ГБ: предупреждение и строка для итога, до 4 ГБ ничего' {
        InModuleScope LunqDebloater {
            Mock Write-Warning { }
            Mock Get-Item { [pscustomobject]@{ Length = [long]5GB } } -ParameterFilter { $LiteralPath -eq 'big.wim' }
            Mock Get-Item { [pscustomobject]@{ Length = [long]4GB - 1 } } -ParameterFilter { $LiteralPath -eq 'fits.wim' }
            Test-LunqWimSize -WimPath 'fits.wim' | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 0 -Exactly
            $result = Test-LunqWimSize -WimPath 'big.wim'
            $result.Kind | Should -Be 'WimSize'
            $result.Summary | Should -Match 'больше 4 ГБ.+Rufus'
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Rufus*' }
        }
    }
}
