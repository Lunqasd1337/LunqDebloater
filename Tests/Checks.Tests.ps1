#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Проверки перед сборкой (Private\Checks.ps1, Private\Iso.ps1): рабочая папка, итоговый ISO,
# версия образа и системы, остатки прошлого запуска.

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

Describe 'Рабочая папка и итоговый ISO' {
    It 'корень диска не годится' {
        InModuleScope LunqDebloater { Test-LunqWorkDir -WorkDir ([IO.Path]::GetPathRoot($TestDrive)) | Should -Be 'это корень диска' }
    }

    It 'папка, внутри которой лежит ISO, не годится' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Test-LunqWorkDir -WorkDir $Root -ProtectedPaths (Join-Path $Root 'Win11.iso') | Should -BeLike 'внутри неё лежит*'
        }
    }

    It 'чужая непустая папка не годится, своя с меткой годится' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $foreign = Join-Path $Root 'foreign'
            New-Item -ItemType Directory -Path $foreign -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $foreign 'file.txt') -Value 'x'
            Test-LunqWorkDir -WorkDir $foreign | Should -Be 'папка не пустая и создана не этим скриптом'

            $own = Join-Path $Root 'own'
            Initialize-LunqWorkDir -WorkDir $own
            Set-Content -LiteralPath (Join-Path $own 'leftover.txt') -Value 'x'
            Test-LunqWorkDir -WorkDir $own | Should -BeNullOrEmpty
        }
    }

    It 'ISO без загрузчика BIOS (ARM64) собирается только для UEFI' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $isoRoot = Join-Path $Root 'arm64'
            $efi = Join-Path $isoRoot 'efi\microsoft\boot\efisys.bin'
            New-Item -ItemType Directory -Path (Split-Path $efi) -Force | Out-Null
            Set-Content -LiteralPath $efi -Value 'x'
            Mock Invoke-Native { 0 }
            New-BootableIso -IsoRoot $isoRoot -OutputPath (Join-Path $Root 'arm64.iso') -Oscdimg 'oscdimg.exe'
            Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $Arguments -contains "-bootdata:1#pEF,e,b$efi" }
        }
    }

    It 'итоговый ISO не может совпадать с исходным' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $iso = Join-Path $Root 'Win11.iso'
            Test-LunqOutputPath -OutputIso $iso -IsoPath $iso | Should -BeLike 'это исходный ISO*'
        }
    }

    It 'папки для итогового ISO нет' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Test-LunqOutputPath -OutputIso (Join-Path $Root 'missing\out.iso') -IsoPath (Join-Path $Root 'in.iso') | Should -BeLike 'папки*нет*'
        }
    }

    It 'папка есть и доступна для записи' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Test-LunqOutputPath -OutputIso (Join-Path $Root 'out.iso') -IsoPath (Join-Path $Root 'in.iso') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-LunqImageRequirements' {
    BeforeAll {
        $requirements = [pscustomobject]@{ Build = 26300; MinRevision = 9457; Architecture = 'amd64' }
    }

    It 'подходящая сборка' {
        $info = [pscustomobject]@{ Build = 26300; Revision = 9500; Architecture = 'amd64' }
        $r = Test-LunqImageRequirements -Info $info -Requirements $requirements
        $r.Errors.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 0
    }

    It 'другая сборка и архитектура' {
        $info = [pscustomobject]@{ Build = 26200; Revision = 9500; Architecture = 'arm64' }
        $r = Test-LunqImageRequirements -Info $info -Requirements $requirements
        $r.Errors.Count | Should -Be 2
    }

    It 'старая ревизия: ошибка без накопительного обновления и предупреждение с ним' {
        $info = [pscustomobject]@{ Build = 26300; Revision = 100; Architecture = 'amd64' }
        (Test-LunqImageRequirements -Info $info -Requirements $requirements).Errors.Count | Should -Be 1
        $r = Test-LunqImageRequirements -Info $info -Requirements $requirements -HasCumulativeUpdate
        $r.Errors.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 1
    }
}

Describe 'Get-LunqHostWarning' {
    It 'предупреждает, если система старше образа' {
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 19045 | Should -BeLike '*19045 (Windows 10)*старше образа*'
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 22631 | Should -BeLike '*Windows 11 23H2*'
    }

    It 'молчит, если система той же версии или новее, или версия неизвестна' {
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 26300 | Should -BeNullOrEmpty
        Get-LunqHostWarning -ImageBuild 26300 -HostBuild 0 | Should -BeNullOrEmpty
    }
}

Describe 'Test-LunqPrerequisites: остатки прошлого запуска' {
    BeforeAll {
        $work = Join-Path $TestDrive 'w'
        $iso = Join-Path $TestDrive 'in.iso'
        Set-Content -LiteralPath $iso -Value 'iso'
        Mock -ModuleName LunqDebloater Get-LunqDriveInfo { [pscustomobject]@{ Name = 'T:\'; DriveFormat = 'NTFS'; AvailableFreeSpace = [long]500GB } }
        Mock -ModuleName LunqDebloater Find-Oscdimg { 'oscdimg.exe' }
        Mock -ModuleName LunqDebloater Write-Host { }
    }

    It 'свой смонтированный образ не считается предупреждением' {
        $own = Join-Path $work 'mount'
        Mock -ModuleName LunqDebloater Get-WindowsImage { [pscustomobject]@{ Path = $own } } -ParameterFilter { $Mounted }
        $r = Test-LunqPrerequisites -IsoPath $iso -WorkDir $work -OutputIso (Join-Path $TestDrive 'out.iso') -OwnMountPaths $own
        $r.Warnings | Should -Be 0
        $r.Errors | Should -Be 0
    }

    It 'чужой смонтированный образ даёт предупреждение' {
        Mock -ModuleName LunqDebloater Get-WindowsImage { [pscustomobject]@{ Path = 'C:\Other\mount' } } -ParameterFilter { $Mounted }
        $r = Test-LunqPrerequisites -IsoPath $iso -WorkDir $work -OutputIso (Join-Path $TestDrive 'out.iso') -OwnMountPaths (Join-Path $work 'mount')
        $r.Warnings | Should -Be 1
    }
}
