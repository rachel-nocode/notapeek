use std::sync::Mutex;
use tauri::{Emitter, Manager, RunEvent, State};

#[cfg(target_os = "macos")]
use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};

#[derive(Default)]
struct PendingFile(Mutex<Option<String>>);

impl PendingFile {
    fn set(&self, path: String) {
        if let Ok(mut pending) = self.0.lock() {
            *pending = Some(path);
        }
    }

    fn take(&self) -> Option<String> {
        self.0.lock().ok().and_then(|mut pending| pending.take())
    }
}

#[tauri::command]
fn consume_pending_file(state: State<'_, PendingFile>) -> Option<String> {
    state.take()
}

fn opened_url_path(url: &tauri::Url) -> Option<String> {
    if url.scheme() == "file" {
        url.to_file_path()
            .ok()
            .map(|path| path.to_string_lossy().to_string())
    } else {
        Some(url.to_string())
    }
}

#[cfg(target_os = "macos")]
fn activate_quicklook_extension_once() {
    std::thread::spawn(|| {
        let appex = std::env::current_exe()
            .ok()
            .and_then(|exe| {
                exe.parent()
                    .and_then(|macos| macos.parent())
                    .map(|contents| contents.join("PlugIns/QuickLookMD.appex"))
            })
            .filter(|path| path.exists());

        let Some(home) = std::env::var_os("HOME") else {
            return;
        };

        let marker = std::path::PathBuf::from(home)
            .join("Library/Application Support/dev.rachel.notapeek")
            .join(format!("quicklook-activated-{}", env!("CARGO_PKG_VERSION")));

        if marker.exists() {
            return;
        }

        if let Some(appex) = appex.as_ref() {
            let _ = std::process::Command::new("/usr/bin/pluginkit")
                .arg("-a")
                .arg(appex)
                .status();
        }
        let _ = std::process::Command::new("/usr/bin/pluginkit")
            .args(["-e", "use", "-i", "dev.rachel.notapeek.quicklook"])
            .status();
        let _ = std::process::Command::new("/usr/bin/qlmanage")
            .arg("-r")
            .status();
        let _ = std::process::Command::new("/usr/bin/qlmanage")
            .args(["-r", "cache"])
            .status();

        if let Some(parent) = marker.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(marker, b"");
    });
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
                activate_quicklook_extension_once();
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
                if let Some(path) = opened_url_path(&url) {
                    app_handle.state::<PendingFile>().set(path.clone());
                    let _ = app_handle.emit("file-open", path);
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_file_returns_and_clears_latest_path() {
        let pending = PendingFile::default();

        pending.set("/tmp/first.md".to_string());
        pending.set("/tmp/second.md".to_string());

        assert_eq!(pending.take(), Some("/tmp/second.md".to_string()));
        assert_eq!(pending.take(), None);
    }

    #[test]
    fn opened_file_url_converts_to_plain_path() {
        let url = tauri::Url::parse("file:///tmp/note.md").unwrap();

        assert_eq!(opened_url_path(&url), Some("/tmp/note.md".to_string()));
    }

    #[test]
    fn opened_non_file_url_is_preserved() {
        let url = tauri::Url::parse("notapeek://open/path").unwrap();

        assert_eq!(
            opened_url_path(&url),
            Some("notapeek://open/path".to_string())
        );
    }
}
