#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Копия этого компьютера (Private\Host.ps1): программы из winget export и сети Wi-Fi из netsh.

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

Describe 'Программы этого компьютера' {
    It 'из winget export берутся Id, у Microsoft Store с --source msstore, без частей Windows и повторов' {
        InModuleScope LunqDebloater {
            $json = @{
                Sources = @(
                    @{ SourceDetails = @{ Name = 'winget' }; Packages = @(@{ PackageIdentifier = 'Git.Git' }, @{ PackageIdentifier = 'Microsoft.VCLibs.Desktop.14' }, @{ PackageIdentifier = 'Microsoft.WindowsTerminal' }, @{ PackageIdentifier = '7zip.7zip' }, @{ PackageIdentifier = 'Git.Git' }) },
                    @{ SourceDetails = @{ Name = 'msstore' }; Packages = @(@{ PackageIdentifier = '9NKSQGP7F2NH' }) })
            } | ConvertTo-Json -Depth 5
            $lines = ConvertFrom-LunqWingetExport -Json $json
            $lines | Should -Be @('Git.Git', '7zip.7zip', '9NKSQGP7F2NH --source msstore')
        }
    }

    It 'одна программа даёт список из одной строки' {
        InModuleScope LunqDebloater {
            $json = '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Git.Git"}]}]}'
            $lines = ConvertFrom-LunqWingetExport -Json $json
            , $lines | Should -BeOfType [array]
            $lines.Count | Should -Be 1
        }
    }

    It 'winget export с кодом «не все программы найдены» всё равно даёт список' {
        $temp = Join-Path $TestDrive 'apps'
        InModuleScope LunqDebloater -Parameters @{ Temp = $temp } {
            param($Temp)
            Mock Invoke-Native {
                $out = $Arguments[[array]::IndexOf([string[]]$Arguments, '--output') + 1]
                Set-Content -LiteralPath $out -Value '{"Sources":[{"SourceDetails":{"Name":"winget"},"Packages":[{"PackageIdentifier":"Git.Git"},{"PackageIdentifier":"7zip.7zip"}]}]}'
                return -1978335212
            } -ParameterFilter { $FilePath -eq 'winget.exe' }
            $apps = Export-LunqHostApps -TempDir $Temp
            $apps | Should -Be @('Git.Git', '7zip.7zip')
            Should -Invoke Invoke-Native -ParameterFilter { $SuccessCodes -contains -1978335212 }
        }
        @(Get-ChildItem -LiteralPath $temp -File).Count | Should -Be 0
    }

    It 'winget не запустился или не создал файл: понятная ошибка' {
        InModuleScope LunqDebloater -Parameters @{ Temp = (Join-Path $TestDrive 'apps2') } {
            param($Temp)
            Mock Invoke-Native { throw 'The term winget.exe is not recognized' } -ParameterFilter { $FilePath -eq 'winget.exe' }
            { Export-LunqHostApps -TempDir $Temp } | Should -Throw 'winget не запустился: *'
            Mock Invoke-Native { 0 } -ParameterFilter { $FilePath -eq 'winget.exe' }
            { Export-LunqHostApps -TempDir $Temp } | Should -Throw 'winget export не создал список программ.'
        }
    }

    It 'к Apps.txt добавляются только новые программы, сам Apps.txt не меняется' {
        $apps = Join-Path $TestDrive 'Apps.txt'
        Set-Content -LiteralPath $apps -Value @('# Мои программы', '7zip.7zip', 'Mozilla.Firefox --scope machine') -Encoding UTF8
        $before = Get-Content -LiteralPath $apps -Raw
        $dest = Join-Path $TestDrive 'out\Apps.txt'
        InModuleScope LunqDebloater -Parameters @{ Apps = $apps; Dest = $dest } {
            param($Apps, $Dest)
            $r = Merge-LunqAppsList -AppsPath $Apps -Extra @('Git.Git', '7zip.7zip', 'Mozilla.Firefox') -Destination $Dest
            $r.Added | Should -Be 1
            Get-Content -LiteralPath $Dest -Encoding UTF8 | Should -Be @('# Мои программы', '7zip.7zip', 'Mozilla.Firefox --scope machine', '', '# Программы с компьютера, где собирался образ (winget export)', 'Git.Git')
        }
        Get-Content -LiteralPath $apps -Raw | Should -Be $before
    }

    It 'без Apps.txt список состоит из программ этого компьютера' {
        $dest = Join-Path $TestDrive 'out2\Apps.txt'
        InModuleScope LunqDebloater -Parameters @{ Dest = $dest } {
            param($Dest)
            (Merge-LunqAppsList -AppsPath '' -Extra @('Git.Git') -Destination $Dest).Added | Should -Be 1
            @(Get-Content -LiteralPath $Dest | Where-Object { $_ -and -not $_.StartsWith('#') }) | Should -Be @('Git.Git')
        }
    }
}

Describe 'Сети Wi-Fi этого компьютера' {
    It 'возвращаются имена сетей из профилей, пароли выгружаются открытым текстом' {
        $dest = Join-Path $TestDrive 'wifi'
        InModuleScope LunqDebloater -Parameters @{ Dest = $dest } {
            param($Dest)
            Mock Invoke-Native {
                $folder = ($Arguments | Where-Object { $_ -like 'folder=*' }) -replace '^folder=', ''
                # netsh пишет профиль в UTF-8 без BOM.
                [IO.File]::WriteAllText((Join-Path $folder 'Wi-Fi-Home.xml'), '<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1"><name>Дом 5G</name></WLANProfile>', (New-Object Text.UTF8Encoding($false)))
                Set-Content -LiteralPath (Join-Path $folder 'Wi-Fi-Bad.xml') -Value 'not xml'
                return 0
            } -ParameterFilter { $FilePath -eq 'netsh.exe' }
            $names = Export-LunqHostWifi -Destination $Dest
            $names | Should -Be @('Wi-Fi-Bad', 'Дом 5G')
            Should -Invoke Invoke-Native -ParameterFilter { $Arguments -contains 'key=clear' }
        }
    }

    It 'нет Wi-Fi или служба WLAN выключена: пустой список, а не ошибка' {
        InModuleScope LunqDebloater -Parameters @{ Dest = (Join-Path $TestDrive 'wifi2') } {
            param($Dest)
            Mock Invoke-Native { 1 } -ParameterFilter { $FilePath -eq 'netsh.exe' }
            $names = Export-LunqHostWifi -Destination $Dest
            $names.Count | Should -Be 0
        }
    }
}
