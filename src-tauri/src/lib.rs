use std::sync::Mutex;
use tauri::{Emitter, Manager, RunEvent, State};

#[cfg(target_os = "macos")]
use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};

#[derive(Default)]
struct PendingFile(Mutex<Option<String>>);

#[tauri::command]
fn consume_pending_file(state: State<'_, PendingFile>) -> Option<String> {
    state.0.lock().ok().and_then(|mut g| g.take())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Capture launch arg before Tauri eats argv.
    let launch_path: Option<String> = std::env::args()
        .skip(1)
        .find(|arg| !arg.starts_with('-') && std::path::Path::new(arg).exists());

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(PendingFile(Mutex::new(launch_path)))
        .invoke_handler(tauri::generate_handler![consume_pending_file])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window missing");

            #[cfg(target_os = "macos")]
            {
                let _ = apply_vibrancy(
                    &window,
                    NSVisualEffectMaterial::HudWindow,
                    Some(NSVisualEffectState::Active),
                    Some(12.0),
                );
            }

            #[cfg(not(target_os = "macos"))]
            {
                let _ = window;
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if let RunEvent::Opened { urls } = event {
            for url in urls {
                let path = if url.scheme() == "file" {
                    url.to_file_path().ok().map(|p| p.to_string_lossy().to_string())
                } else {
                    Some(url.to_string())
                };
                if let Some(p) = path {
                    let _ = app_handle.emit("file-open", p);
                }
            }
        }
    });
}
