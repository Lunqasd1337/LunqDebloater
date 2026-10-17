@{
    # Манифест модуля LunqDebloater. Версия отсюда видна в заголовке окна, в логе, в итоге
    # сборки и в реестре собранного образа (HKLM\SOFTWARE\LunqDebloater).
    RootModule        = 'LunqDebloater.psm1'
    ModuleVersion     = '1.9.2'
    GUID              = '2e51670f-e6c1-4bef-936f-7455bd5dff55'
    Author            = 'Lunqasd1337'
    Description       = 'Офлайн-преднастройка ISO-образа Windows 11 через DISM.'
    PowerShellVersion = '5.1'

    # Только функции, которые вызывает LunqDebloater.ps1: шаги сборки вызывает Build.ps1 внутри
    # модуля. Остальные внутренние, тесты берут их через & (Get-Module LunqDebloater) { ... }.
    FunctionsToExport = @(
        'Compress-LunqDismLog',
        'ConvertTo-LunqArgumentList',
        'Disable-LunqCategories',
        'Dismount-IsoImage',
        'Dismount-OfflineHives',
        'Enter-LunqRunLock',
        'Exit-LunqRunLock',
        'Find-LunqBuildInputs',
        'Format-FirstLogonSummary',
        'Format-LunqUnattendSummary',
        'Format-Size',
        'Get-FolderSize',
        'Get-IsoEditions',
        'Get-IsoImageInfo',
        'Get-LunqDefaultLanguage',
        'Get-LunqEffectiveConfig',
        'Get-LunqFilesSize',
        'Get-LunqFirstLogon',
        'Get-LunqHostRegion',
        'Get-LunqHostWarning',
        'Get-LunqText',
        'Get-LunqVersion',
        'Get-WindowsReleaseName',
        'Invoke-LunqBuild',
        'Invoke-LunqContentAction',
        'Mount-IsoImage',
        'New-LunqBugReport',
        'New-LunqContentOptions',
        'Read-LunqProfile',
        'Read-YesNo',
        'Select-IsoFile',
        'Select-LunqBuildOptions',
        'Select-LunqCategories',
        'Select-LunqEdition',
        'Select-LunqPEDrivers',
        'Select-LunqPEUpdates',
        'Select-LunqProfile',
        'Set-LunqLanguage',
        'Start-LunqLog',
        'Stop-LunqLog',
        'Test-Administrator',
        'Test-CumulativeUpdate',
        'Test-LunqAnyMounted',
        'Test-LunqImageRequirements',
        'Test-LunqOption',
        'Test-LunqPrerequisites',
        'Write-CategoryList',
        'Write-Check',
        'Write-Info',
        'Write-LunqReport',
        'Write-LunqRunInfo',
        'Write-Section',
        'Write-UpdateList'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
