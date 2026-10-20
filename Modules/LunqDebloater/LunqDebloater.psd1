@{
    # Манифест модуля LunqDebloater. Версия отсюда видна в заголовке окна, в логе, в итоге
    # сборки и в реестре собранного образа (HKLM\SOFTWARE\LunqDebloater).
    RootModule        = 'LunqDebloater.psm1'
    ModuleVersion     = '1.14.0'
    GUID              = '2e51670f-e6c1-4bef-936f-7455bd5dff55'
    Author            = 'Lunqasd1337'
    Description       = 'Офлайн-преднастройка ISO-образа Windows 11 через DISM.'
    PowerShellVersion = '5.1'

    # Только функции, которые вызывает LunqDebloater.ps1: шаги сборки вызывает Build.ps1 внутри
    # модуля. Остальные внутренние, тесты берут их через & (Get-Module LunqDebloater) { ... }.
    FunctionsToExport = @(
        'Add-LunqDefenderExclusion',
        'Compare-LunqRecipeFiles',
        'Compress-LunqDismLog',
        'ConvertTo-LunqArgumentList',
        'Disable-LunqCategories',
        'Dismount-IsoImage',
        'Dismount-LunqStateIso',
        'Dismount-OfflineHives',
        'Enter-LunqRunLock',
        'Exit-LunqRunLock',
        'Export-LunqHostApps',
        'Export-LunqHostWifi',
        'Format-Size',
        'Get-ConfigList',
        'Get-InstallImagePath',
        'Get-IsoEditions',
        'Get-IsoImageInfo',
        'Get-LunqBuildInputs',
        'Get-LunqCatalogRelease',
        'Get-LunqContentsDir',
        'Get-LunqDefaultLanguage',
        'Get-LunqDefaultOutputName',
        'Get-LunqEffectiveConfig',
        'Get-LunqFilesSize',
        'Get-LunqFirstLogon',
        'Get-LunqHostRegion',
        'Get-LunqHostWarning',
        'Get-LunqMountedPaths',
        'Get-LunqOutputIsoPath',
        'Get-LunqRecipeFiles',
        'Get-LunqRecipeProfile',
        'Get-LunqSortedUpdates',
        'Get-LunqText',
        'Get-LunqUpdateFiles',
        'Get-LunqVersion',
        'Get-WindowsReleaseName',
        'Invoke-LunqBuild',
        'Invoke-LunqInventoryMode',
        'Invoke-LunqOnlineMode',
        'Invoke-LunqRestoreMode',
        'Merge-LunqAppsList',
        'Mount-IsoImage',
        'New-LunqBugReport',
        'New-LunqRestoreData',
        'Read-LunqAccountName',
        'Read-LunqOutputName',
        'Read-LunqProfile',
        'Read-LunqRecipe',
        'Read-YesNo',
        'Remove-LunqDefenderExclusion',
        'Remove-LunqScheduleLeftovers',
        'Remove-LunqWorkDir',
        'Resolve-LunqRecipeParameters',
        'Save-LunqBuildOutputs',
        'Save-LunqCatalogUpdates',
        'Select-IsoFile',
        'Select-LunqBuildContents',
        'Select-LunqCategories',
        'Select-LunqEdition',
        'Select-LunqPEUpdates',
        'Select-LunqProfile',
        'Set-LunqLanguage',
        'Set-LunqOnlyCategories',
        'Split-LunqIdList',
        'Start-LunqLog',
        'Stop-LunqLog',
        'Test-Administrator',
        'Test-CumulativeUpdate',
        'Test-LunqAccountName',
        'Test-LunqAnyMounted',
        'Test-LunqImageRequirements',
        'Test-LunqOutputName',
        'Test-LunqPrerequisites',
        'Write-Check',
        'Write-Info',
        'Write-LunqBuildPlan',
        'Write-LunqReport',
        'Write-LunqRunInfo',
        'Write-Section'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
