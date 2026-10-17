## Что меняется / What changes

<!-- Что было раньше и что стало. Before and after. -->

## Проверка / Checks

- [ ] `Invoke-Pester -Path .\Tests` проходит / passes
- [ ] PSScriptAnalyzer без замечаний / no findings
- [ ] Если менялось окно: `cargo clippy -- -D warnings` в `Gui\src-tauri` без замечаний, тексты в `ru` и `en` в `strings.js` / if the window changed: no `cargo clippy` warnings, texts in both `ru` and `en` of `strings.js`
- [ ] Новые строки есть в `Strings\ru` и `Strings\en` / new strings are in both tables
- [ ] Новый параметр описан в `README.md` и `README.en.md` / new parameter is documented in both READMEs
- [ ] Изменение для пользователя записано в `CHANGELOG.md`, версия поднята в манифесте, `Cargo.toml` и `tauri.conf.json` / user-visible change is in `CHANGELOG.md`, version bumped in the manifest, `Cargo.toml` and `tauri.conf.json`
- [ ] Проверено на настоящем ISO (какой) / tested on a real ISO (which one):
