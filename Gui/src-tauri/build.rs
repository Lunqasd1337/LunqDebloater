fn main() {
    // Свой манифест: окно сразу просит права администратора, потому что без них скрипт
    // не смонтирует ISO. Common Controls 6 нужны системным диалогам выбора файла,
    // Tauri добавляет их в свой манифест сам, а этот манифест его заменяет.
    let windows = tauri_build::WindowsAttributes::new().app_manifest(include_str!("app.manifest"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows))
        .expect("tauri-build failed");
}
