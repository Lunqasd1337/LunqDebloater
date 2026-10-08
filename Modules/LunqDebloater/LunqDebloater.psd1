@{
    # Манифест модуля LunqDebloater. Версия отсюда видна в заголовке окна, в логе, в итоге
    # сборки и в реестре собранного образа (HKLM\SOFTWARE\LunqDebloater).
    RootModule        = 'LunqDebloater.psm1'
    ModuleVersion     = '1.3.0'
    GUID              = '2e51670f-e6c1-4bef-936f-7455bd5dff55'
    Author            = 'Lunqasd1337'
    Description       = 'Офлайн-преднастройка ISO-образа Windows 11 через DISM.'
    PowerShellVersion = '5.1'

    # Функции, которые вызывает LunqDebloater.ps1. Остальные внутренние и снаружи не видны.
    FunctionsToExport = @(
        'Add-LunqDrivers',
        'Add-LunqUpdates',
        'ConvertTo-LunqArgumentList',
        'Copy-IsoContent',
        'Disable-LunqCategories',
        'Disable-LunqFeatures',
        'Dismount-IsoImage',
        'Dismount-OfflineHives',
        'Export-SingleEdition',
        'Format-FirstLogonSummary',
        'Format-LunqUnattendSummary',
        'Format-Size',
        'Get-FolderSize',
        'Get-InstallImagePath',
        'Get-IsoEditions',
        'Get-IsoImageInfo',
        'Get-LunqDefaultLanguage',
        'Get-LunqDriverFiles',
        'Get-LunqEffectiveConfig',
        'Get-LunqFirstLogon',
        'Get-LunqHostRegion',
        'Get-LunqHostWarning',
        'Get-LunqImageLanguage',
        'Get-LunqLanguage',
        'Get-LunqLocalized',
        'Get-LunqMountedPaths',
        'Get-LunqText',
        'Get-LunqUpdateFiles',
        'Get-LunqVersion',
        'Get-WindowsReleaseName',
        'Initialize-LunqSteps',
        'Install-LunqFirstLogon',
        'Install-LunqUnattend',
        'Invoke-LunqComponentCleanup',
        'Mount-IsoImage',
        'New-BootableIso',
        'New-LunqOption',
        'New-LunqResult',
        'Read-LunqProfile',
        'Read-YesNo',
        'Remove-LunqAppx',
        'Remove-LunqCapabilities',
        'Remove-LunqPackages',
        'Reset-LunqWorkDir',
        'Select-IsoFile',
        'Select-LunqBuildOptions',
        'Select-LunqCategories',
        'Select-LunqEdition',
        'Select-LunqPEDrivers',
        'Select-LunqPEUpdates',
        'Select-LunqProfile',
        'Set-LunqBuildStamp',
        'Set-LunqLanguage',
        'Set-LunqRegistry',
        'Start-LunqLog',
        'Stop-LunqLog',
        'Test-Administrator',
        'Test-CumulativeUpdate',
        'Test-LunqImageRequirements',
        'Test-LunqOption',
        'Test-LunqPrerequisites',
        'Update-LunqRecovery',
        'Update-LunqSetup',
        'Write-CategoryList',
        'Write-Check',
        'Write-Info',
        'Write-LunqInventory',
        'Write-LunqReport',
        'Write-LunqRunInfo',
        'Write-Section',
        'Write-Step',
        'Write-UpdateList'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
