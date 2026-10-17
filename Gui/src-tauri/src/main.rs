// Окно LunqDebloater: тонкая оболочка над LunqDebloater.ps1. Сборку делает сам скрипт,
// окно только собирает параметры, запускает его с -EventsPath и показывает события.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::Serialize;
use serde_json::{json, Value};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{ChildStderr, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

// Консоль скрипта не показываем: всё, что он сообщает, приходит событиями.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Default)]
struct Run {
    running: Arc<AtomicBool>,
    // Пользователь подтвердил, что закрывает окно во время сборки.
    close_anyway: AtomicBool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppInfo {
    root: String,
    config_dir: String,
    version: String,
    profile: Value,
    work_dir: String,
}

#[derive(Serialize)]
struct Inputs {
    updates: u32,
    drivers: u32,
    apps: u32,
    scripts: u32,
}

fn find_root() -> Result<PathBuf, String> {
    // Exe лежит рядом со скриптом, а при разработке в Gui\src-tauri\target\...: ищем вверх по папкам.
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    exe.ancestors()
        .skip(1)
        .find(|dir| dir.join("LunqDebloater.ps1").is_file())
        .map(Path::to_path_buf)
        .ok_or_else(|| "NO_SCRIPT".to_string())
}

fn module_version(root: &Path) -> String {
    let manifest = root.join("Modules").join("LunqDebloater").join("LunqDebloater.psd1");
    let text = fs::read_to_string(manifest).unwrap_or_default();
    text.lines()
        .find(|line| line.trim_start().starts_with("ModuleVersion"))
        .and_then(|line| line.split('\'').nth(1))
        .unwrap_or_default()
        .to_string()
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    // Файлы проекта сохранены с BOM, а serde_json его не пропускает.
    serde_json::from_str(text.trim_start_matches('\u{feff}')).map_err(|e| format!("{}: {}", path.display(), e))
}

fn has_extension(path: &Path, extensions: &[&str]) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| extensions.iter().any(|x| e.eq_ignore_ascii_case(x)))
        .unwrap_or(false)
}

fn count_files(dir: &Path, extensions: &[&str], deep: bool) -> u32 {
    let Ok(entries) = fs::read_dir(dir) else { return 0 };
    let mut count = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if deep {
                count += count_files(&path, extensions, true);
            }
        } else if has_extension(&path, extensions) {
            count += 1;
        }
    }
    count
}

fn powershell() -> PathBuf {
    // Скрипт работает только в Windows PowerShell 5.1, а не в pwsh, который может стоять первым в PATH.
    let windows = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    windows.join("System32").join("WindowsPowerShell").join("v1.0").join("powershell.exe")
}

fn events_file(kind: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    std::env::temp_dir().join(format!("LunqDebloater_{}_{}_{}.jsonl", kind, std::process::id(), stamp))
}

fn script_command(root: &Path, events: &Path, args: &[String]) -> Command {
    let mut command = Command::new(powershell());
    command
        .current_dir(root)
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(root.join("LunqDebloater.ps1"))
        .args(args)
        .arg("-EventsPath")
        .arg(events)
        // Вывод консоли не читаем, а непрочитанный канал остановил бы скрипт, когда заполнится.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

fn drain(stream: Option<ChildStderr>) -> Arc<Mutex<Vec<u8>>> {
    // Ошибки PowerShell до первого события (например, скрипт не прочитался) видны только здесь.
    // Читаем кусками в общий буфер, а не ждём конца потока: его может держать открытым
    // программа, которую скрипт запустил и которая пережила его.
    let collected = Arc::new(Mutex::new(Vec::new()));
    let target = collected.clone();
    thread::spawn(move || {
        let Some(mut stream) = stream else { return };
        let mut chunk = [0u8; 4096];
        while let Ok(read) = stream.read(&mut chunk) {
            if read == 0 {
                break;
            }
            if let Ok(mut buffer) = target.lock() {
                buffer.extend_from_slice(&chunk[..read]);
            }
        }
    });
    collected
}

fn collected_text(collected: &Arc<Mutex<Vec<u8>>>) -> String {
    // Короткая пауза после выхода скрипта: поток успевает дочитать последние строки.
    thread::sleep(Duration::from_millis(300));
    let buffer = collected.lock().map(|b| b.clone()).unwrap_or_default();
    tail(&String::from_utf8_lossy(&buffer))
}

fn tail(text: &str) -> String {
    let chars: Vec<char> = text.trim().chars().collect();
    let start = chars.len().saturating_sub(3000);
    chars[start..].iter().collect()
}

fn read_events(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

fn read_new_events(path: &Path, offset: &mut u64, pending: &mut Vec<u8>, mut emit: impl FnMut(Value)) {
    // Файл дописывается, пока идёт сборка: читаем только новое и отдаём целые строки.
    let Ok(mut file) = File::open(path) else { return };
    if file.seek(SeekFrom::Start(*offset)).is_err() {
        return;
    }
    let mut buffer = Vec::new();
    if file.read_to_end(&mut buffer).is_err() {
        return;
    }
    *offset += buffer.len() as u64;
    pending.extend_from_slice(&buffer);
    while let Some(end) = pending.iter().position(|b| *b == b'\n') {
        let line: Vec<u8> = pending.drain(..=end).collect();
        if let Ok(event) = serde_json::from_slice::<Value>(&line) {
            emit(event);
        }
    }
}

#[tauri::command]
fn app_info() -> Result<AppInfo, String> {
    let root = find_root()?;
    let config = root.join("Config");
    let profile = read_json(&config.join("Profile.json"))?;
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    Ok(AppInfo {
        root: root.display().to_string(),
        config_dir: config.display().to_string(),
        version: module_version(&root),
        profile,
        work_dir: format!(r"{}\LunqWork", drive),
    })
}

#[tauri::command]
async fn scan_inputs(updates: String, drivers: String, config_dir: String) -> Inputs {
    // Те же папки и расширения, что ищет скрипт: обновления в корне и в SafeOS и Setup, драйверы на любой глубине.
    let updates = PathBuf::from(updates);
    let config = PathBuf::from(config_dir);
    let kinds = ["msu", "cab"];
    let apps = fs::read_to_string(config.join("Apps.txt"))
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .count() as u32;
    Inputs {
        updates: count_files(&updates, &kinds, false)
            + count_files(&updates.join("SafeOS"), &kinds, false)
            + count_files(&updates.join("Setup"), &kinds, false),
        drivers: count_files(Path::new(&drivers), &["inf"], true),
        apps,
        scripts: count_files(&config.join("Scripts"), &["ps1"], false),
    }
}

#[tauri::command]
async fn list_editions(iso: String, language: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let root = find_root()?;
        let events = events_file("editions");
        let args = vec!["-IsoPath".to_string(), iso, "-ListEditions".to_string(), "-Language".to_string(), language];
        let mut child = script_command(&root, &events, &args).spawn().map_err(|e| e.to_string())?;
        let stderr = drain(child.stderr.take());
        let status = child.wait().map_err(|e| e.to_string())?;
        let errors = collected_text(&stderr);
        let list = read_events(&events);
        let _ = fs::remove_file(&events);
        if let Some(found) = list.iter().find(|e| e["type"] == "editions") {
            return Ok(found["items"].clone());
        }
        if let Some(text) = list.iter().find(|e| e["type"] == "error").and_then(|e| e["text"].as_str()) {
            return Err(text.to_string());
        }
        Err(format!("SCRIPT_FAILED {}\n{}", status.code().unwrap_or(-1), errors))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
fn start_build(app: AppHandle, run: State<'_, Run>, args: Vec<String>) -> Result<(), String> {
    if run.running.swap(true, Ordering::SeqCst) {
        return Err("ALREADY_RUNNING".to_string());
    }
    let started = find_root().and_then(|root| {
        let events = events_file("build");
        let child = script_command(&root, &events, &args).spawn().map_err(|e| e.to_string())?;
        Ok((child, events))
    });
    let (mut child, events) = match started {
        Ok(value) => value,
        Err(error) => {
            run.running.store(false, Ordering::SeqCst);
            return Err(error);
        }
    };
    let running = run.running.clone();
    let stderr = drain(child.stderr.take());
    thread::spawn(move || {
        let mut offset = 0;
        let mut pending = Vec::new();
        loop {
            // Сначала узнаём, жив ли скрипт, потом читаем: после выхода прочитаются и последние строки.
            let exited = !matches!(child.try_wait(), Ok(None));
            read_new_events(&events, &mut offset, &mut pending, |event| {
                let _ = app.emit("lunq-event", event);
            });
            if exited {
                break;
            }
            thread::sleep(Duration::from_millis(250));
        }
        let code = child.wait().ok().and_then(|status| status.code());
        let errors = collected_text(&stderr);
        let _ = fs::remove_file(&events);
        running.store(false, Ordering::SeqCst);
        let _ = app.emit("lunq-exit", json!({ "code": code, "stderr": errors }));
    });
    Ok(())
}

#[tauri::command]
fn path_exists(path: String) -> bool {
    Path::new(&path).exists()
}

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    // Проводник открывает папку и выделяет в ней файл.
    let mut command = Command::new("explorer.exe");
    #[cfg(windows)]
    command.raw_arg(format!("/select,\"{}\"", path));
    command.spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_path(path: String) -> Result<(), String> {
    // Папку открывает проводник, файл (например, лог) программа, связанная с ним.
    Command::new("explorer.exe").arg(path).spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[tauri::command]
fn close_anyway(window: tauri::Window, run: State<'_, Run>) {
    run.close_anyway.store(true, Ordering::SeqCst);
    let _ = window.close();
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(Run::default())
        .invoke_handler(tauri::generate_handler![
            app_info,
            scan_inputs,
            list_editions,
            start_build,
            path_exists,
            reveal,
            open_path,
            close_anyway
        ])
        .on_window_event(|window, event| {
            // Пока идёт сборка, окно сначала спрашивает: без него прогресс уже не увидеть.
            if let WindowEvent::CloseRequested { api, .. } = event {
                let run = window.state::<Run>();
                if run.running.load(Ordering::SeqCst) && !run.close_anyway.load(Ordering::SeqCst) {
                    api.prevent_close();
                    let _ = window.emit("lunq-close-requested", ());
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("LunqDebloater window failed to start");
}
