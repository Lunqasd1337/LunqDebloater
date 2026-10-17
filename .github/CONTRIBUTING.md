# Как помочь проекту

English: [see below](#contributing-in-english)

Как устроен код и в каком порядке идёт сборка, описано в [ARCHITECTURE.md](../ARCHITECTURE.md). Участвуя в проекте, вы соглашаетесь с [правилами общения](CODE_OF_CONDUCT.md).

## Проверка перед PR

Тесты не трогают систему: вместо DISM, reg.exe, oscdimg и winget работают заглушки. Запустите их и анализатор из корня репозитория (подробнее в разделе «Разработка» в [README.md](../README.md)):

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -MinimumVersion 1.23.0 -Scope CurrentUser -Force
Invoke-Pester -Path .\Tests
Invoke-ScriptAnalyzer -Path .\LunqDebloater.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\Install.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\Modules -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Если менялось окно (папка `Gui`), проверьте и его. Нужны [Rust](https://rustup.rs) и Visual Studio Build Tools с компонентом «Разработка классических приложений на C++»:

```powershell
cd Gui\src-tauri
cargo clippy --locked -- -D warnings
cargo build --release --locked
```

GitHub Actions выполняет то же для каждого PR: тесты в Windows PowerShell 5.1 и в PowerShell 7, анализатор в Windows PowerShell 5.1, сборку окна с `cargo clippy`. Собранный `LunqDebloater.exe` лежит в артефакте `LunqDebloater-window` запуска. Скрипт по-настоящему работает в 5.1, поэтому проверяйте и в нём.

## Правила

- **Тексты интерфейса.** Всё, что видит пользователь (вывод в консоль, вопросы, ошибки, строки лога, итог), не пишется в коде, а берётся через `Get-LunqText 'Область.Имя'` из таблиц `Modules\LunqDebloater\Strings\<язык>\*.psd1`. Новую строку добавляйте сразу в обе таблицы, `ru` и `en`, с одинаковыми ключами и одинаковыми `{0}`, `{1}`. Фигурные скобки в самом тексте пишутся удвоенными: `{{` и `}}`.
- **Тексты профиля.** `Name` и `Description` в `Config\Profile.json` пишутся с переводами: `{ "ru": "...", "en": "..." }`. Профиль проверяется схемой `Schemas\Profile.schema.json` (VS Code подхватывает её сам).
- **Кодировка.** Файлы `.ps1`, `.psm1`, `.psd1` и `Config\README*.txt` сохраняются в UTF-8 с BOM: без BOM Windows PowerShell 5.1 читает их как ANSI, и русский текст ломает скрипт. Исключение: `Install.ps1` хранится только в ASCII и без BOM, потому что его выполняют через `irm | iex`. Окончания строк выставляет `.gitattributes`.
- **Параметры.** Новый параметр `LunqDebloater.ps1` описывается в таблицах `README.md` и `README.en.md`: тест проверяет, что ни один не забыт.
- **Окно.** Своей логики сборки у окна нет: каждая его настройка превращается в параметр скрипта в `scriptArgs()` (`Gui\ui\app.js`). Тексты окна лежат в `Gui\ui\strings.js`, новый ключ добавляется сразу в `ru` и `en` с одинаковыми `{0}`, `{1}`. Как добавить настройку, описано в [ARCHITECTURE.md](../ARCHITECTURE.md#окно).
- **CHANGELOG и версия.** Заметное для пользователя изменение записывается в [CHANGELOG.md](../CHANGELOG.md), а версия поднимается в `ModuleVersion` манифеста `Modules\LunqDebloater\LunqDebloater.psd1` и вместе с ней в `Gui\src-tauri\Cargo.toml` и `Gui\src-tauri\tauri.conf.json` (тест следит, чтобы они совпадали). Если текущая версия уже выпущена, заводится новая.
- Комментарии в коде пишутся по-русски, как в остальном проекте.

## Сообщить об ошибке

Откройте issue по шаблону «Ошибка / Bug report» и приложите лог. Каждый запуск пишет его в папку `Logs` рядом со скриптом, в том числе запуск из окна: там его открывает кнопка «Открыть лог», а после ошибки кнопка «Отчёт об ошибке» показывает архив для issue. Если сборка прервалась ошибкой, там же лежит архив `LunqDebloater_<дата>_report.zip`: приложите его, в нём уже есть оба лога и профиль. Иначе пришлите оба файла последнего запуска, `LunqDebloater_<дата>.log` и `LunqDebloater_<дата>_dism.zip` (подробнее в разделе «Логи и версия» в [README.md](../README.md)). В начале лога есть версия LunqDebloater, Windows и параметры запуска. В архиве путь к папке пользователя, имя пользователя и имя компьютера уже заменены. Отдельные логи перед отправкой посмотрите сами: нет ли в них того, что вы не хотите показывать (например, имени пользователя в путях).

---

## Contributing in English

The code layout and the order of the build are described in [ARCHITECTURE.en.md](../ARCHITECTURE.en.md). By taking part in the project you agree to the [code of conduct](CODE_OF_CONDUCT.md#code-of-conduct).

### Checks before a PR

The tests do not touch the system: stubs replace DISM, reg.exe, oscdimg and winget. Run them and the analyzer from the repository root (see the "Development" section in [README.en.md](../README.en.md)):

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -MinimumVersion 1.23.0 -Scope CurrentUser -Force
Invoke-Pester -Path .\Tests
Invoke-ScriptAnalyzer -Path .\LunqDebloater.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\Install.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\Modules -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

If you changed the window (the `Gui` folder), check it too. You need [Rust](https://rustup.rs) and Visual Studio Build Tools with the "Desktop development with C++" workload:

```powershell
cd Gui\src-tauri
cargo clippy --locked -- -D warnings
cargo build --release --locked
```

GitHub Actions runs the same for every PR: the tests in Windows PowerShell 5.1 and in PowerShell 7, the analyzer in Windows PowerShell 5.1, and the window build with `cargo clippy`. The built `LunqDebloater.exe` is in the run's `LunqDebloater-window` artifact. The script really runs in 5.1, so test in it too.

### Rules

- **Interface texts.** Nothing the user sees (console output, prompts, errors, log lines, the result) is written in the code. It comes from `Get-LunqText 'Area.Name'` and the tables `Modules\LunqDebloater\Strings\<language>\*.psd1`. Add every new string to both tables, `ru` and `en`, with the same keys and the same `{0}`, `{1}` placeholders. Literal braces in the text are doubled: `{{` and `}}`.
- **Profile texts.** `Name` and `Description` in `Config\Profile.json` are written with translations: `{ "ru": "...", "en": "..." }`. The profile is checked by the schema `Schemas\Profile.schema.json` (VS Code picks it up by itself).
- **Encoding.** `.ps1`, `.psm1`, `.psd1` files and `Config\README*.txt` are saved as UTF-8 with BOM: without a BOM Windows PowerShell 5.1 reads them as ANSI, and Russian text breaks the script. The exception is `Install.ps1`: it is ASCII only and has no BOM, because it is run through `irm | iex`. Line endings are set by `.gitattributes`.
- **Parameters.** A new `LunqDebloater.ps1` parameter is documented in the tables of `README.md` and `README.en.md`: a test makes sure none is forgotten.
- **The window.** The window has no build logic of its own: each of its settings becomes a script parameter in `scriptArgs()` (`Gui\ui\app.js`). The window texts are in `Gui\ui\strings.js`; add every new key to both `ru` and `en` with the same `{0}`, `{1}`. How to add a setting is described in [ARCHITECTURE.en.md](../ARCHITECTURE.en.md#the-window).
- **CHANGELOG and version.** A change that users notice goes into [CHANGELOG.md](../CHANGELOG.md), and the version is raised in `ModuleVersion` of the manifest `Modules\LunqDebloater\LunqDebloater.psd1` and with it in `Gui\src-tauri\Cargo.toml` and `Gui\src-tauri\tauri.conf.json` (a test makes sure they match). If the current version is already released, a new one is started.
- Code comments are written in Russian, like in the rest of the project.

### Reporting a bug

Open an issue with the "Ошибка / Bug report" form and attach the log. Every run writes it to the `Logs` folder next to the script, including a run from the window: there the "Open log" button opens it, and after an error the "Bug report" button shows the archive for the issue. When a build stops with an error, the same folder has an archive `LunqDebloater_<date>_report.zip`: attach it, it already holds both logs and the profile. Otherwise send both files of the last run, `LunqDebloater_<date>.log` and `LunqDebloater_<date>_dism.zip` (see the "Logs and version" section in [README.en.md](../README.en.md)). The start of the log shows the LunqDebloater version, Windows version and the parameters of the run. In the archive the user folder path, the user name and the computer name are already replaced. Check separate logs yourself before sending: make sure they have nothing you do not want to share (for example, your user name in paths).
