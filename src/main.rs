// Swap - System tray app to switch between Claude Code settings.json profiles.

use std::cell::RefCell;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;
use std::time::SystemTime;

use gtk::prelude::*;
use libappindicator::{AppIndicator, AppIndicatorStatus};
use serde_json::{Map, Value};

const POLL_INTERVAL: u32 = 3; // seconds

struct Config {
    target: String,
    profiles: Map<String, Value>,
}

struct App {
    indicator: AppIndicator,
    config: Option<Config>,
    config_mtime: Option<SystemTime>,
    config_file: PathBuf,
    icon_path: String,
}

// ── Path helpers ─────────────────────────────────────────────────────

fn home_dir() -> PathBuf {
    dirs::home_dir().expect("could not determine home directory")
}

fn config_file() -> PathBuf {
    home_dir().join(".claude").join("swap.json")
}

fn expand_tilde(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        home_dir().join(rest)
    } else if path == "~" {
        home_dir()
    } else {
        PathBuf::from(path)
    }
}

/// Resolve the icon: prefer the installed hicolor theme name, otherwise an
/// absolute path to the bundled SVG. Returns (indicator_icon, abs_path).
fn resolve_icon() -> (String, String) {
    let hicolor = home_dir().join(".local/share/icons/hicolor/scalable/apps/swap.svg");

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("assets/swap-icon.svg"));
        }
    }
    candidates.push(home_dir().join(".local/share/swap/assets/swap-icon.svg"));
    candidates.push(PathBuf::from(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/assets/swap-icon.svg"
    )));

    let icon_path = candidates
        .iter()
        .find(|p| p.exists())
        .cloned()
        .unwrap_or_else(|| candidates[0].clone())
        .to_string_lossy()
        .into_owned();

    let indicator_icon = if hicolor.exists() {
        "swap".to_string()
    } else {
        icon_path.clone()
    };

    (indicator_icon, icon_path)
}

// ── File helpers ─────────────────────────────────────────────────────

/// Write data to a file atomically using tmp + rename, then chmod 0600.
fn safe_write(path: &Path, data: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn load_config(config_file: &Path) -> Option<Config> {
    let text = fs::read_to_string(config_file).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let obj = value.as_object()?;
    let target = obj.get("target")?.as_str()?.to_string();
    let profiles = obj.get("profiles")?.as_object()?.clone();
    if profiles.is_empty() {
        return None;
    }
    Some(Config { target, profiles })
}

/// Compare the target file content against each profile to find the active one.
fn detect_active_profile(cfg: &Config) -> Option<String> {
    let target = expand_tilde(&cfg.target);
    let text = fs::read_to_string(&target).ok()?;
    let current: Value = serde_json::from_str(&text).ok()?;
    for (name, content) in &cfg.profiles {
        if &current == content {
            return Some(name.clone());
        }
    }
    None
}

/// Write the selected profile content to the target file and notify.
fn apply_profile(target: &Path, content: &Value, profile_name: &str, icon_path: &str) {
    if let Some(parent) = target.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let mut data = serde_json::to_string_pretty(content).unwrap_or_default();
    data.push('\n');
    if safe_write(target, &data).is_err() {
        return;
    }
    let _ = Command::new("notify-send")
        .args([
            "-i",
            icon_path,
            "Swap",
            &format!("Switched to: {profile_name}"),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

fn seed_config(config_file: &Path) {
    if config_file.exists() {
        return;
    }
    if let Some(parent) = config_file.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let example = r#"{
  "target": "~/.claude/settings.json",
  "profiles": {
    "Claude": {
      "model": "opus",
      "permissions": {
        "allow": [
          "Bash(*)",
          "Read(*)",
          "Write(*)",
          "Edit(*)",
          "Glob(*)",
          "Grep(*)",
          "WebFetch(*)",
          "WebSearch(*)"
        ],
        "deny": []
      }
    },
    "GLM": {
      "model": "opus",
      "permissions": {
        "allow": [
          "Bash(*)",
          "Read(*)",
          "Write(*)",
          "Edit(*)",
          "Glob(*)",
          "Grep(*)"
        ],
        "deny": [
          "WebFetch(*)",
          "WebSearch(*)"
        ]
      }
    },
    "Empresa": {
      "model": "sonnet",
      "permissions": {
        "allow": [
          "Read(*)",
          "Glob(*)",
          "Grep(*)"
        ],
        "deny": [
          "Bash(*)",
          "Write(*)",
          "Edit(*)",
          "WebFetch(*)",
          "WebSearch(*)"
        ]
      }
    }
  }
}
"#;
    let _ = safe_write(config_file, example);
}

// ── Menu / tray ──────────────────────────────────────────────────────

fn append_footer(menu: &gtk::Menu, app: &Rc<RefCell<App>>, config_file: &Path) {
    let edit_item = gtk::MenuItem::with_label("Edit Config...");
    let cf = config_file.to_path_buf();
    edit_item.connect_activate(move |_| {
        let _ = Command::new("xdg-open")
            .arg(&cf)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    });
    menu.append(&edit_item);

    let reload_item = gtk::MenuItem::with_label("Reload Config");
    let app_reload = app.clone();
    reload_item.connect_activate(move |_| build_menu(&app_reload));
    menu.append(&reload_item);

    menu.append(&gtk::SeparatorMenuItem::new());

    let quit_item = gtk::MenuItem::with_label("Quit");
    quit_item.connect_activate(|_| gtk::main_quit());
    menu.append(&quit_item);
}

fn build_menu(app: &Rc<RefCell<App>>) {
    let config_file = app.borrow().config_file.clone();
    let icon_path = app.borrow().icon_path.clone();

    let config = load_config(&config_file);
    let mut menu = gtk::Menu::new();

    match &config {
        None => {
            let item = gtk::MenuItem::with_label("Config error - check ~/.claude/swap.json");
            item.set_sensitive(false);
            menu.append(&item);
            menu.append(&gtk::SeparatorMenuItem::new());
            append_footer(&menu, app, &config_file);
        }
        Some(cfg) => {
            let target_name = expand_tilde(&cfg.target)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| cfg.target.clone());
            let header = gtk::MenuItem::with_label(&format!("Target: {target_name}"));
            header.set_sensitive(false);
            menu.append(&header);
            menu.append(&gtk::SeparatorMenuItem::new());

            let active = detect_active_profile(cfg);
            let target = expand_tilde(&cfg.target);

            let mut group: Option<gtk::RadioMenuItem> = None;
            for (name, content) in &cfg.profiles {
                let item = gtk::RadioMenuItem::with_label(name);
                if let Some(g) = &group {
                    item.join_group(Some(g));
                }
                item.set_active(active.as_deref() == Some(name.as_str()));

                let target = target.clone();
                let content = content.clone();
                let name_owned = name.clone();
                let icon_path = icon_path.clone();
                item.connect_toggled(move |w| {
                    if w.is_active() {
                        apply_profile(&target, &content, &name_owned, &icon_path);
                    }
                });

                menu.append(&item);
                group = Some(item);
            }

            menu.append(&gtk::SeparatorMenuItem::new());
            append_footer(&menu, app, &config_file);
        }
    }

    menu.show_all();
    let mut app_mut = app.borrow_mut();
    app_mut.indicator.set_menu(&mut menu);
    app_mut.config = config;
}

// ── Main ─────────────────────────────────────────────────────────────

fn main() {
    let config_file = config_file();
    if let Some(parent) = config_file.parent() {
        let _ = fs::create_dir_all(parent);
    }
    seed_config(&config_file);

    if std::env::args().any(|a| a == "--seed-only") {
        return;
    }

    // PR_SET_NAME so the process shows up as "swap".
    unsafe {
        libc::prctl(libc::PR_SET_NAME, b"swap\0".as_ptr() as libc::c_ulong, 0, 0, 0);
    }

    gtk::init().expect("failed to initialize GTK");

    let (indicator_icon, icon_path) = resolve_icon();
    let mut indicator = AppIndicator::new("swap", &indicator_icon);
    indicator.set_status(AppIndicatorStatus::Active);

    let app = Rc::new(RefCell::new(App {
        indicator,
        config: None,
        config_mtime: None,
        config_file: config_file.clone(),
        icon_path,
    }));

    build_menu(&app);

    // Poll the config file for changes and rebuild the menu on update.
    let app_poll = app.clone();
    glib::timeout_add_seconds_local(POLL_INTERVAL, move || {
        let cf = app_poll.borrow().config_file.clone();
        if let Ok(meta) = fs::metadata(&cf) {
            if let Ok(mtime) = meta.modified() {
                let changed = app_poll.borrow().config_mtime != Some(mtime);
                if changed {
                    app_poll.borrow_mut().config_mtime = Some(mtime);
                    build_menu(&app_poll);
                }
            }
        }
        glib::ControlFlow::Continue
    });

    glib::unix_signal_add_local(libc::SIGTERM, || {
        gtk::main_quit();
        glib::ControlFlow::Break
    });
    glib::unix_signal_add_local(libc::SIGINT, || {
        gtk::main_quit();
        glib::ControlFlow::Break
    });

    gtk::main();
}
