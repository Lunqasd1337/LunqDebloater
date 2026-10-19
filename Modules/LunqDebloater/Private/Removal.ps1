function Get-LunqImageTarget {
    # Параметры командлетов DISM: смонтированный образ (-Path) или эта Windows (-Online).
    param([string]$MountPath, [switch]$Online)
    if ($Online) { return @{ Online = $true } }
    return @{ Path = $MountPath }
}

function Get-LunqPackageFamilyName {
    # Имя семейства пакета из полного имени (Имя_Версия_Архитектура_Ресурс_Издатель): по нему
    # приложение находится в Microsoft Store, когда его нужно вернуть.
    param([Parameter(Mandatory)][string]$PackageName)
    $parts = $PackageName -split '_'
    if ($parts.Count -ge 5) { return '{0}_{1}' -f $parts[0], $parts[-1] }
    return $PackageName
}

function Get-LunqInstalledAppx {
    # Приложения, уже установленные у пользователей этой Windows. Обёртка, чтобы тесты могли её подменить.
    return @(Get-AppxPackage -AllUsers)
}

function Remove-LunqInstalledAppx {
    param([Parameter(Mandatory)]$Package)
    Remove-AppxPackage -Package $Package.PackageFullName -AllUsers -ErrorAction Stop
}

function Remove-LunqAppx {
    # В образе удаляются подготовленные пакеты (provisioned): у новых пользователей их не будет.
    # На этой Windows (-Online) ещё и уже установленные у всех пользователей.
    # -Restore: куда записать, что удалено, чтобы потом это можно было вернуть.
    param(
        [string]$MountPath,
        [switch]$Online,
        [Parameter(Mandatory)]$Config,
        $Restore
    )

    $result = New-LunqResult (Get-LunqText 'Removal.AppxTitle') Appx
    $patterns = Get-ConfigList $Config 'Appx', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info (Get-LunqText 'Removal.AppxEmpty'); return $result }

    $target = Get-LunqImageTarget -MountPath $MountPath -Online:$Online
    $packages = @(Get-AppxProvisionedPackage @target)
    $installed = @()
    if ($Online) { $installed = @(Get-LunqInstalledAppx) }
    $names = @(@($packages | ForEach-Object { $_.DisplayName }) + @($installed | ForEach-Object { $_.Name }) | Select-Object -Unique)
    $result.Total = $names.Count
    foreach ($name in $names) {
        if (-not (Test-NamePattern -Name $name -Patterns $patterns)) { continue }
        Write-Info (Get-LunqText 'Removal.Removing' $name)
        $family = $null
        try {
            foreach ($pkg in @($packages | Where-Object { $_.DisplayName -eq $name })) {
                $family = Get-LunqPackageFamilyName -PackageName $pkg.PackageName
                Remove-AppxProvisionedPackage @target -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            }
            foreach ($app in @($installed | Where-Object { $_.Name -eq $name })) {
                $family = $app.PackageFamilyName
                Remove-LunqInstalledAppx -Package $app
            }
            $result.Done.Add($name)
            if ($Restore) { Add-LunqRestoreItem -Restore $Restore -Kind Appx -Name $name -Extra @{ PackageFamilyName = $family } }
        }
        catch {
            Write-Warning (Get-LunqText 'Removal.RemoveFailed' $name $_.Exception.Message)
            $result.Failed.Add($name)
        }
    }
    Add-NotMatched $result $patterns $names
    $summaryKey = if ($Online) { 'Removal.AppxSummaryOnline' } else { 'Removal.AppxSummary' }
    Write-Info (Get-LunqText $summaryKey $result.Done.Count $names.Count)
    return $result
}

function Remove-LunqCapabilities {
    param(
        [string]$MountPath,
        [switch]$Online,
        [Parameter(Mandatory)]$Config,
        $Restore
    )

    $result = New-LunqResult (Get-LunqText 'Removal.CapabilitiesTitle') Capabilities
    $patterns = Get-ConfigList $Config 'Capabilities', 'Remove'
    if ($patterns.Count -eq 0) { Write-Info (Get-LunqText 'Removal.CapabilitiesEmpty'); return $result }

    $target = Get-LunqImageTarget -MountPath $MountPath -Online:$Online
    $installed = @(Get-WindowsCapability @target | Where-Object State -eq 'Installed')
    $result.Total = $installed.Count
    foreach ($cap in $installed) {
        if (Test-NamePattern -Name $cap.Name -Patterns $patterns) {
            Write-Info (Get-LunqText 'Removal.RemovingCapability' $cap.Name)
            try {
                Remove-WindowsCapability @target -Name $cap.Name -ErrorAction Stop | Out-Null
                $result.Done.Add($cap.Name)
                if ($Restore) { Add-LunqRestoreItem -Restore $Restore -Kind Capabilities -Name $cap.Name }
            }
            catch {
                Write-Warning (Get-LunqText 'Removal.RemoveFailed' $cap.Name $_.Exception.Message)
                $result.Failed.Add($cap.Name)
            }
        }
    }
    Add-NotMatched $result $patterns @($installed | ForEach-Object { $_.Name })
    return $result
}

function Disable-LunqFeatures {
    param(
        [string]$MountPath,
        [switch]$Online,
        [Parameter(Mandatory)]$Config,
        $Restore
    )

    $result = New-LunqResult (Get-LunqText 'Removal.FeaturesTitle') Features
    $patterns = Get-ConfigList $Config 'Features', 'Disable'
    if ($patterns.Count -eq 0) { Write-Info (Get-LunqText 'Removal.FeaturesEmpty'); return $result }

    $removePayload = [bool](Get-ConfigValue $Config 'Features', 'RemovePayload')

    $target = Get-LunqImageTarget -MountPath $MountPath -Online:$Online
    $enabled = @(Get-WindowsOptionalFeature @target | Where-Object State -eq 'Enabled')
    $result.Total = $enabled.Count
    foreach ($feature in $enabled) {
        if (Test-NamePattern -Name $feature.FeatureName -Patterns $patterns) {
            Write-Info (Get-LunqText 'Removal.DisablingFeature' $feature.FeatureName)
            try {
                $params = @{ FeatureName = $feature.FeatureName; NoRestart = $true; ErrorAction = 'Stop' }
                if ($removePayload) { $params.Remove = $true }
                Disable-WindowsOptionalFeature @target @params | Out-Null
                $result.Done.Add($feature.FeatureName)
                if ($Restore) { Add-LunqRestoreItem -Restore $Restore -Kind Features -Name $feature.FeatureName }
            }
            catch {
                Write-Warning (Get-LunqText 'Removal.DisableFailed' $feature.FeatureName $_.Exception.Message)
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
        [string]$MountPath,
        [switch]$Online,
        [Parameter(Mandatory)]$Config,
        $Restore
    )

    $result = New-LunqResult (Get-LunqText 'Removal.PackagesTitle') Packages
    $patterns = Get-ConfigList $Config 'Packages', 'Remove'
    if ($patterns.Count -eq 0) { return $null }

    Write-Warning (Get-LunqText 'Removal.PackagesWarning')
    $target = Get-LunqImageTarget -MountPath $MountPath -Online:$Online
    $packages = @(Get-WindowsPackage @target | Where-Object PackageState -eq 'Installed')
    $result.Total = $packages.Count
    foreach ($pkg in $packages) {
        if (Test-NamePattern -Name $pkg.PackageName -Patterns $patterns) {
            Write-Info (Get-LunqText 'Removal.RemovingPackage' $pkg.PackageName)
            try {
                Remove-WindowsPackage @target -PackageName $pkg.PackageName -NoRestart -ErrorAction Stop | Out-Null
                $result.Done.Add($pkg.PackageName)
                if ($Restore) { Add-LunqRestoreItem -Restore $Restore -Kind Packages -Name $pkg.PackageName }
            }
            catch {
                Write-Warning (Get-LunqText 'Removal.RemoveFailed' $pkg.PackageName $_.Exception.Message)
                $result.Failed.Add($pkg.PackageName)
            }
        }
    }
    Add-NotMatched $result $patterns @($packages | ForEach-Object { $_.PackageName })
    return $result
}
