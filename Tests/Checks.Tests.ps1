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

            # Папка по умолчанию без метки: остаток старой версии годится, чужие файлы нет.
            $old = Join-Path $Root 'LunqWork'
            New-Item -ItemType Directory -Path (Join-Path $old 'iso'), (Join-Path $old 'mount') -Force | Out-Null
            Test-LunqWorkDir -WorkDir $old -IsDefault | Should -BeNullOrEmpty
            Set-Content -LiteralPath (Join-Path $old 'photo.jpg') -Value 'x'
            Test-LunqWorkDir -WorkDir $old -IsDefault | Should -Be 'папка не пустая и создана не этим скриптом'
        }
    }

    It 'ISO без загрузчика BIOS (ARM64) собирается только для UEFI' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $isoRoot = Join-Path $Root 'arm64'
            $efi = Join-Path $isoRoot 'efi\microsoft\boot\efisys.bin'
            New-Item -ItemType Directory -Path (Split-Path $efi) -Force | Out-Null
            Set-Content -LiteralPath $efi -Value 'x'
            Mock Invoke-Native { Set-Content -LiteralPath $Arguments[-1] -Value 'iso'; 0 }
            New-BootableIso -IsoRoot $isoRoot -OutputPath (Join-Path $Root 'arm64.iso') -Oscdimg 'oscdimg.exe'
            Should -Invoke Invoke-Native -Times 1 -Exactly -ParameterFilter { $Arguments -contains "-bootdata:1#pEF,e,b$efi" }
            Test-Path -LiteralPath (Join-Path $Root 'arm64.iso') | Should -BeTrue
        }
    }

    It 'занятый прошлый ISO обнаруживается до сборки' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $out = Join-Path $Root 'locked_Lunq.iso'
            Set-Content -LiteralPath $out -Value 'old'
            Test-LunqOutputPath -OutputIso $out -IsoPath (Join-Path $Root 'Win11.iso') | Should -BeNullOrEmpty
            # Так держит файл подключённый в Проводнике ISO.
            $lock = [IO.File]::Open($out, 'Open', 'Read', 'None')
            try { Test-LunqOutputPath -OutputIso $out -IsoPath (Join-Path $Root 'Win11.iso') | Should -BeLike '*занят другой программой*' }
            finally { $lock.Dispose() }
        }
    }

    It 'oscdimg с ошибкой не портит прошлый ISO и не оставляет недописанный файл' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            $isoRoot = Join-Path $Root 'failiso'
            $efi = Join-Path $isoRoot 'efi\microsoft\boot\efisys.bin'
            New-Item -ItemType Directory -Path (Split-Path $efi) -Force | Out-Null
            Set-Content -LiteralPath $efi -Value 'x'
            $out = Join-Path $Root 'fail_Lunq.iso'
            Set-Content -LiteralPath $out -Value 'old'
            Mock Invoke-Native { Set-Content -LiteralPath $Arguments[-1] -Value 'half'; 5 }
            { New-BootableIso -IsoRoot $isoRoot -OutputPath $out -Oscdimg 'oscdimg.exe' } | Should -Throw '*кодом 5*'
            Get-Content -LiteralPath $out | Should -Be 'old'
            Test-Path -LiteralPath (Join-Path $Root 'fail_Lunq.partial.iso') | Should -BeFalse
            Mock Invoke-Native { Set-Content -LiteralPath $Arguments[-1] -Value 'new'; 0 }
            New-BootableIso -IsoRoot $isoRoot -OutputPath $out -Oscdimg 'oscdimg.exe'
            Get-Content -LiteralPath $out | Should -Be 'new'
            Test-Path -LiteralPath (Join-Path $Root 'fail_Lunq.partial.iso') | Should -BeFalse
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

Describe 'Смонтированные образы' {
    It 'DISM не ответил: считается, что образ смонтирован, и рабочая папка не удаляется' {
        InModuleScope LunqDebloater -Parameters @{ Root = "$TestDrive" } {
            param($Root)
            Mock Get-WindowsImage { throw 'DISM is busy' } -ParameterFilter { $Mounted }
            Mock Dismount-OfflineHives { }
            $work = Join-Path $Root 'busywork'
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            Get-LunqMountedPaths -Paths @(Join-Path $work 'mount') | Should -BeNullOrEmpty
            Test-LunqAnyMounted -Paths @(Join-Path $work 'mount') | Should -BeTrue
            { Reset-LunqWorkDir -WorkDir $work -MountPaths @(Join-Path $work 'mount') } | Should -Throw '*DISM не ответил*'
            Test-Path -LiteralPath $work | Should -BeTrue
        }
    }

    It 'DISM ответил: занятые папки из списка и пустой список, если ничего не смонтировано' {
        InModuleScope LunqDebloater {
            Mock Get-WindowsImage { @([pscustomobject]@{ Path = 'C:\W\mount' }, [pscustomobject]@{ Path = 'C:\Other' }) } -ParameterFilter { $Mounted }
            @(Get-LunqMountedPaths -Paths 'C:\W\mount', 'C:\W\remount') | Should -Be @('C:\W\mount')
            Test-LunqAnyMounted -Paths 'C:\W\remount' | Should -BeFalse
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
        Mock -ModuleName LunqDebloater Get-LunqDriveInfo { [pscustomobject]@{ Name = 'T:\'; DriveType = 'Fixed'; DriveFormat = 'NTFS'; AvailableFreeSpace = [long]500GB } }
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

Describe 'Get-LunqContentsDir' {
    It 'опись сохраняется рядом с ISO, если туда можно писать' {
        $iso = Join-Path $TestDrive 'win.iso'
        Get-LunqContentsDir -IsoPath $iso -FallbackDir (Join-Path $TestDrive 'Logs') | Should -Be "$TestDrive"
    }

    It 'папка ISO только для чтения: опись уходит в запасную папку, и об этом сказано' {
        Mock -ModuleName LunqDebloater Test-LunqWritableFolder { $false }
        Mock -ModuleName LunqDebloater Write-Info { }
        $fallback = Join-Path $TestDrive 'Logs'
        Get-LunqContentsDir -IsoPath 'D:\win.iso' -FallbackDir $fallback | Should -Be $fallback
        Should -Invoke -ModuleName LunqDebloater Write-Info -Times 1 -Exactly -ParameterFilter { $Message -like '*не записать*' }
    }
}

Describe 'Редакции в ISO' {
    It 'Get-WindowsReleaseName: известная сборка даёт выпуск, неизвестная пустую строку' {
        InModuleScope LunqDebloater {
            Get-WindowsReleaseName -Build 26100 | Should -Be 'Windows 11 24H2'
            Get-WindowsReleaseName -Build 12345 | Should -Be ''
        }
    }

    It 'Get-EditionHint: <Name>' -TestCases @(
        @{ Name = 'Windows 11 Pro'; Hint = 'BitLocker*' },
        @{ Name = 'Windows 11 Pro for Workstations'; Hint = 'Pro для мощных*' },
        @{ Name = 'Windows 11 Pro Education'; Hint = 'Pro для учебных*' },
        @{ Name = 'Windows 11 Education'; Hint = 'для учебных заведений, по*' },
        @{ Name = 'Windows 11 Корпоративная'; Hint = 'корпоративная*' },
        @{ Name = 'Windows 11 Домашняя для одного языка'; Hint = 'Домашняя с одним*' },
        @{ Name = 'Windows 11 Домашняя'; Hint = 'для домашнего*' },
        @{ Name = 'Windows 11 Pro N'; Hint = 'BitLocker*Версия N*' },
        @{ Name = 'Windows 11 IoT'; Hint = '' }
    ) {
        param($Name, $Hint)
        InModuleScope LunqDebloater -Parameters @{ Name = $Name; Hint = $Hint } {
            param($Name, $Hint)
            Get-EditionHint -Name $Name | Should -BeLike $Hint
        }
    }

    Context 'Select-LunqEdition' {
        BeforeAll {
            $script:images = @(
                [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' },
                [pscustomobject]@{ ImageIndex = 5; ImageName = 'Windows 11 Pro' })
        }

        BeforeEach {
            Mock -ModuleName LunqDebloater Write-Host { }
            Mock -ModuleName LunqDebloater Write-Info { }
        }

        It 'номер и имя из параметров' {
            InModuleScope LunqDebloater -Parameters @{ Images = $images } {
                param($Images)
                Select-LunqEdition -Images $Images -Index 5 | Should -Be 5
                Select-LunqEdition -Images $Images -Edition 'Windows 11 Home' | Should -Be 1
                { Select-LunqEdition -Images $Images -Index 3 } | Should -Throw '*номером 3*'
                { Select-LunqEdition -Images $Images -Edition 'Windows 11 Ultimate' } | Should -Throw "*'Windows 11 Ultimate' не найдена*"
            }
        }

        It 'одна редакция выбирается без вопроса' {
            InModuleScope LunqDebloater -Parameters @{ Images = $images } {
                param($Images)
                Mock Read-Host { throw 'вопроса быть не должно' }
                Select-LunqEdition -Images @($Images[1]) | Should -Be 5
            }
        }

        It 'неверный ответ переспрашивается' {
            InModuleScope LunqDebloater -Parameters @{ Images = $images } {
                param($Images)
                $global:LunqEditionAnswers = New-Object System.Collections.Generic.Queue[object]
                foreach ($answer in 'abc', '3', $null, '5') { $global:LunqEditionAnswers.Enqueue($answer) }
                Mock Read-Host { $global:LunqEditionAnswers.Dequeue() }
                Mock Write-Warning { }
                Select-LunqEdition -Images $Images | Should -Be 5
                Should -Invoke Write-Warning -Times 3 -Exactly
                Remove-Variable -Name LunqEditionAnswers -Scope Global
            }
        }
    }
}
