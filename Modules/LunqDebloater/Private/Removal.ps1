function Remove-LunqAppx {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Приложения Appx' Appx
    $patterns = Get-ConfigList $Config 'Appx', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info 'Список Appx в профиле пуст.'; return $result }

    $packages = @(Get-AppxProvisionedPackage -Path $MountPath)
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.DisplayName -Patterns $patterns) {
            Write-Info "Удаляю $($pkg.DisplayName)"
            try {
                Remove-AppxProvisionedPackage -Path $MountPath -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                $result.Done.Add($pkg.DisplayName)
            }
            catch {
                Write-Warning "Не удалось удалить $($pkg.DisplayName): $($_.Exception.Message)"
                $result.Failed.Add($pkg.DisplayName)
            }
        }
    }
    Add-NotMatched $result $patterns @($packages | ForEach-Object { $_.DisplayName })
    Write-Info "Удалено Appx-пакетов: $($result.Done.Count) из $($packages.Count) в образе."
    return $result
}

function Remove-LunqCapabilities {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Компоненты (Capabilities)' Capabilities
    $patterns = Get-ConfigList $Config 'Capabilities', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info 'Список Capabilities в профиле пуст.'; return $result }

    $installed = @(Get-WindowsCapability -Path $MountPath | Where-Object State -eq 'Installed')
    foreach ($cap in $installed) {
        if (Test-NamePattern -Name $cap.Name -Patterns $patterns) {
            Write-Info "Удаляю компонент $($cap.Name)"
            try {
                Remove-WindowsCapability -Path $MountPath -Name $cap.Name -ErrorAction Stop | Out-Null
                $result.Done.Add($cap.Name)
            }
            catch {
                Write-Warning "Не удалось удалить $($cap.Name): $($_.Exception.Message)"
                $result.Failed.Add($cap.Name)
            }
        }
    }
    Add-NotMatched $result $patterns @($installed | ForEach-Object { $_.Name })
    return $result
}

function Disable-LunqFeatures {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Функции Windows (Optional Features)' Features
    $patterns = Get-ConfigList $Config 'Features', 'Disable'
    if ($patterns.Count -eq 0) { Write-Info 'Список Features в профиле пуст.'; return $result }

    $removePayload = [bool](Get-ConfigValue $Config 'Features', 'RemovePayload')

    $enabled = @(Get-WindowsOptionalFeature -Path $MountPath | Where-Object State -eq 'Enabled')
    foreach ($feature in $enabled) {
        if (Test-NamePattern -Name $feature.FeatureName -Patterns $patterns) {
            Write-Info "Отключаю компонент $($feature.FeatureName)"
            try {
                $params = @{ Path = $MountPath; FeatureName = $feature.FeatureName; NoRestart = $true; ErrorAction = 'Stop' }
                if ($removePayload) { $params.Remove = $true }
                Disable-WindowsOptionalFeature @params | Out-Null
                $result.Done.Add($feature.FeatureName)
            }
            catch {
                Write-Warning "Не удалось отключить $($feature.FeatureName): $($_.Exception.Message)"
                $result.Failed.Add($feature.FeatureName)
            }
        }
    }
    Add-NotMatched $result $patterns @($enabled | ForEach-Object { $_.FeatureName })
    return $result
}

function Remove-LunqPackages {
    # Удаление CBS-пакетов. Может сломать обслуживание образа, поэтому в профиле по умолчанию пусто.
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)]$Config
    )

    $result = New-LunqResult 'Системные пакеты' Packages
    $patterns = Get-ConfigList $Config 'Packages', 'Remove'
    if ($patterns.Count -eq 0) { return $null }

    Write-Warning 'Удаление системных пакетов может помешать установке обновлений.'
    $packages = @(Get-WindowsPackage -Path $MountPath | Where-Object PackageState -eq 'Installed')
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.PackageName -Patterns $patterns) {
            Write-Info "Удаляю пакет $($pkg.PackageName)"
            try {
                Remove-WindowsPackage -Path $MountPath -PackageName $pkg.PackageName -NoRestart -ErrorAction Stop | Out-Null
                $result.Done.Add($pkg.PackageName)
            }
            catch {
                Write-Warning "Не удалось удалить $($pkg.PackageName): $($_.Exception.Message)"
                $result.Failed.Add($pkg.PackageName)
            }
        }
    }
    Add-NotMatched $result $patterns @($packages | ForEach-Object { $_.PackageName })
    return $result
}
