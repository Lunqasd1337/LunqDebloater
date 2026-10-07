# LunqDebloater

PowerShell-скрипт для преднастройки ISO-образа Windows 11 перед установкой. Работает офлайн, через DISM, над `install.wim`:

- удаляет предустановленные Appx-приложения;
- удаляет компоненты Windows (Capabilities и Optional Features);
- вносит изменения в реестр образа (кусты `SOFTWARE`, `SYSTEM` и профиль `Default`, от которого создаются все новые пользователи).

На выходе получается загрузочный ISO (BIOS + UEFI) с одной выбранной редакцией.

## Требования

- Windows 10/11, PowerShell 5.1 или 7, запуск от имени администратора.
- [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install), компонент **Deployment Tools** (нужен только `oscdimg.exe`).
- Около 15 ГБ свободного места на NTFS-диске для рабочей папки (по умолчанию `C:\LunqWork`).

## Запуск

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Get-ChildItem -Recurse | Unblock-File   # если архив скачан из интернета

.\LunqDebloater.ps1 -IsoPath D:\Win11_26H2.iso -Edition "Windows 11 Pro"
```

Если не указать `-Edition` или `-Index`, скрипт покажет список редакций и спросит номер. Итоговый ISO по умолчанию появится рядом с исходным (`Win11_26H2_Lunq.iso`), лог будет рядом с ним (`*.iso.log`).

| Параметр | Назначение |
|---|---|
| `-OutputIso` | Путь к итоговому ISO |
| `-ProfilePath` | Свой JSON-профиль вместо `Profiles\default.json` |
| `-Index` / `-Edition` | Редакция по номеру или имени |
| `-WorkDir` | Рабочая папка |
| `-OscdimgPath` | Путь к `oscdimg.exe`, если ADK стоит не в стандартной папке |
| `-SkipAppx`, `-SkipComponents`, `-SkipRegistry` | Пропустить шаг |
| `-CleanupComponents` | Очистить хранилище компонентов (`/ResetBase`): образ меньше, но обновления из него нельзя удалить |
| `-KeepWorkDir` | Не удалять рабочую папку после сборки |
| `-Force` | Перезаписать существующий итоговый ISO |

## Как устроен процесс

1. ISO монтируется, его содержимое копируется в рабочую папку.
2. Выбранная редакция экспортируется в отдельный `install.wim` (ESD при этом конвертируется в WIM).
3. `install.wim` монтируется, к нему применяется профиль: Appx, компоненты, реестр.
4. Образ сохраняется и пересжимается, `oscdimg` собирает загрузочный ISO.

При ошибке образ отключается без сохранения, а кусты реестра выгружаются.

## Профиль

Всё, что удаляется и меняется, описано в `Profiles\default.json`. Скопируйте его и правьте под себя.

```jsonc
{
  "Appx":         { "Remove":  ["Microsoft.BingNews", "Microsoft.Xbox*"] },  // DisplayName, можно с *
  "Capabilities": { "Remove":  ["Browser.InternetExplorer*"] },               // Get-WindowsCapability
  "Features":     { "Disable": ["Recall"], "RemovePayload": false },          // Get-WindowsOptionalFeature
  "Packages":     { "Remove":  [] },                                          // CBS-пакеты, осторожно
  "Registry": [
    { "Hive": "SOFTWARE",    "Path": "Policies\\Microsoft\\Windows\\DataCollection", "Name": "AllowTelemetry", "Type": "REG_DWORD", "Value": 0 },
    { "Hive": "DefaultUser", "Path": "Software\\Microsoft\\Windows\\CurrentVersion\\Run", "Name": "OneDriveSetup", "Action": "DeleteValue" },
    { "Hive": "SOFTWARE",    "Path": "Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\OutlookUpdate", "Action": "DeleteKey" }
  ]
}
```

- `Hive`: `SOFTWARE` (HKLM\SOFTWARE), `SYSTEM` (HKLM\SYSTEM, используйте `ControlSet001` вместо `CurrentControlSet`) или `DefaultUser` (HKCU для всех новых пользователей).
- `Action`: `Set` (по умолчанию), `DeleteValue` или `DeleteKey`.
- `Type`: `REG_DWORD`, `REG_QWORD`, `REG_SZ`, `REG_EXPAND_SZ`, `REG_MULTI_SZ` (массив строк), `REG_BINARY` (hex-строка).
- `Description` необязателен и нужен для будущего GUI.

Узнать точные имена в своём образе можно так (после `Mount-WindowsImage`):

```powershell
Get-AppxProvisionedPackage -Path C:\LunqWork\mount | Select DisplayName
Get-WindowsCapability     -Path C:\LunqWork\mount | Where State -eq Installed | Select Name
Get-WindowsOptionalFeature -Path C:\LunqWork\mount | Where State -eq Enabled | Select FeatureName
```

Профиль по умолчанию не трогает Microsoft Store, App Installer (winget), Терминал, Фотографии, Калькулятор, Блокнот, Paint и Безопасность Windows. Список `Packages` пуст намеренно: удаление CBS-пакетов может сломать установку обновлений.
