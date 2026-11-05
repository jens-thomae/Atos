//! D-006 Files prototype in Slint. Brief: docs/decisions/D-006-prototype-brief.md §3.

use slint::platform::WindowEvent;
use slint::{ComponentHandle, ModelRc, RenderingState, StandardListViewItem, VecModel};
use std::cell::RefCell;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant, SystemTime};

slint::include_modules!();

// ponytail: Slint's table reports pointer down/up but no double-click, and has no public
// double-click interval, so this uses GTK's default (400 ms).
const DOUBLE_CLICK: Duration = Duration::from_millis(400);

struct Entry {
    name: String,
    path: PathBuf,
    is_dir: bool,
    size: u64,
    modified: Option<SystemTime>,
}

struct Tab {
    dir: PathBuf,
    sel: i32,
}

struct State {
    tabs: Vec<Tab>,
    cur: usize,
    places: [PathBuf; 3],
    entries: Vec<Entry>,
    cwd: PathBuf,
    last_down: Option<(i32, Instant)>,
}

fn read(dir: &Path) -> std::io::Result<Vec<Entry>> {
    let mut entries = Vec::new();
    for dirent in std::fs::read_dir(dir)? {
        let path = dirent?.path();
        let name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let meta = std::fs::symlink_metadata(&path).ok();
        entries.push(Entry {
            name,
            is_dir: meta.as_ref().is_some_and(|m| m.is_dir()),
            size: meta.as_ref().map_or(0, |m| m.len()),
            modified: meta.and_then(|m| m.modified().ok()),
            path,
        });
    }
    entries.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.cmp(&b.name)));
    Ok(entries)
}

/// Decimal units, one decimal: `120 B`, `345.7 kB`, `1.0 MB`.
fn size_text(bytes: u64) -> String {
    if bytes < 1000 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64 / 1000.0;
    for unit in ["kB", "MB", "GB", "TB"] {
        if value < 999.95 {
            return format!("{value:.1} {unit}");
        }
        value /= 1000.0;
    }
    format!("{value:.1} PB")
}

fn modified_text(time: Option<SystemTime>) -> String {
    time.map(|t| {
        chrono::DateTime::<chrono::Local>::from(t)
            .format("%Y-%m-%d %H:%M")
            .to_string()
    })
    .unwrap_or_default()
}

fn navigate(ui: &AppWindow, state: &mut State, dir: PathBuf) {
    let (entries, error) = match read(&dir) {
        Ok(entries) => (entries, String::new()),
        Err(e) => (Vec::new(), e.to_string()),
    };
    let rows: Vec<ModelRc<StandardListViewItem>> = entries
        .iter()
        .map(|e| {
            let size = if e.is_dir {
                "Folder".into()
            } else {
                size_text(e.size)
            };
            VecModel::from_slice(&[
                e.name.as_str().into(),
                size.as_str().into(),
                modified_text(e.modified).as_str().into(),
            ])
        })
        .collect();
    ui.set_rows(ModelRc::new(VecModel::from(rows)));
    ui.set_error(error.into());
    ui.set_path(dir.display().to_string().into());
    ui.set_at_root(dir.parent().is_none());
    ui.invoke_reset_view();
    state.entries = entries;
    state.tabs[state.cur].dir.clone_from(&dir);
    let labels: Vec<slint::SharedString> = state
        .tabs
        .iter()
        .map(|t| match t.dir.file_name() {
            Some(n) => n.to_string_lossy().as_ref().into(),
            None => "/".into(),
        })
        .collect();
    ui.set_tabs(ModelRc::new(VecModel::from(labels)));
    ui.set_current_tab(state.cur as i32);
    state.cwd = dir;
    state.last_down = None;
}

/// Shows tab `cur`: its folder and, if it has one, its selection.
fn show_tab(ui: &AppWindow, state: &mut State) {
    let (dir, sel) = (state.tabs[state.cur].dir.clone(), state.tabs[state.cur].sel);
    navigate(ui, state, dir);
    if sel >= 0 && (sel as usize) < state.entries.len() {
        ui.invoke_select_row(sel);
    }
}

fn switch_tab(ui: &AppWindow, state: &mut State, to: usize) {
    state.tabs[state.cur].sel = ui.get_current_row();
    state.cur = to;
    show_tab(ui, state);
}

/// Renames for `find` -> `replace` over the files, and the first conflict, if any.
fn plan_rename(entries: &[Entry], find: &str, replace: &str) -> (Vec<(String, String)>, String) {
    if find.is_empty() {
        return (Vec::new(), String::new());
    }
    let pairs: Vec<(String, String)> = entries
        .iter()
        .filter(|e| !e.is_dir && e.name.contains(find))
        .map(|e| (e.name.clone(), e.name.replace(find, replace)))
        .collect();
    let mut conflict = String::new();
    for (i, (old, new)) in pairs.iter().enumerate() {
        conflict = if new.is_empty() {
            format!("Conflict: the new name for \"{old}\" is empty")
        } else if new.contains('/') {
            format!("Conflict: \"{new}\" (from \"{old}\") contains \"/\"")
        } else if entries.iter().any(|e| &e.name == new) {
            format!("Conflict: \"{new}\" (from \"{old}\") already exists")
        } else if pairs[..i].iter().any(|(_, n)| n == new) {
            format!("Conflict: \"{new}\" (from \"{old}\") is also the new name of another file")
        } else {
            continue;
        };
        break;
    }
    (pairs, conflict)
}

fn update_rename(ui: &AppWindow, state: &State, find: &str, replace: &str) {
    let (pairs, conflict) = plan_rename(&state.entries, find, replace);
    let items: Vec<StandardListViewItem> = pairs
        .iter()
        .map(|(old, new)| format!("{old} \u{2192} {new}").as_str().into())
        .collect();
    ui.set_rename_preview(ModelRc::new(VecModel::from(items)));
    ui.set_rename_ok(!find.is_empty() && conflict.is_empty());
    ui.set_rename_conflict(conflict.into());
}

fn open(ui: &AppWindow, state: &mut State, row: i32) {
    let Some(entry) = state.entries.get(row as usize) else {
        return;
    };
    if entry.is_dir {
        let path = entry.path.clone();
        navigate(ui, state, path);
    } else {
        println!("SPIKE_OPEN {}", entry.path.display());
        std::io::stdout().flush().ok();
    }
}

fn main() -> Result<(), slint::PlatformError> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
    let start = std::env::args_os()
        .nth(1)
        .map_or_else(|| home.clone(), PathBuf::from);
    let start = std::path::absolute(&start).unwrap_or(start);

    let ui = AppWindow::new()?;
    let state = Rc::new(RefCell::new(State {
        tabs: vec![Tab {
            dir: start.clone(),
            sel: -1,
        }],
        cur: 0,
        places: [home, "/".into(), start.clone()],
        entries: Vec::new(),
        cwd: start.clone(),
        last_down: None,
    }));
    // Rows are in the model before the first frame, so that frame shows them.
    navigate(&ui, &mut state.borrow_mut(), start);

    // Each callback borrows `state` only while it runs.
    let handle = |f: fn(&AppWindow, &mut State, i32)| {
        let (ui, state) = (ui.as_weak(), state.clone());
        move |i: i32| f(&ui.unwrap(), &mut state.borrow_mut(), i)
    };
    ui.on_activate_place(handle(|ui, s, i| {
        let dir = s.places[i as usize].clone();
        navigate(ui, s, dir);
    }));
    ui.on_open_row(handle(open));
    ui.on_row_left_down(handle(|ui, s, row| {
        let now = Instant::now();
        let double = s
            .last_down
            .is_some_and(|(r, t)| r == row && now - t < DOUBLE_CLICK);
        s.last_down = if double { None } else { Some((row, now)) };
        if double {
            open(ui, s, row);
        }
    }));
    ui.on_fill_properties(handle(|ui, s, row| {
        let Some(e) = s.entries.get(row as usize) else {
            return;
        };
        ui.set_prop_name(e.name.as_str().into());
        ui.set_prop_path(e.path.display().to_string().into());
        ui.set_prop_size(if e.is_dir {
            "Folder".into()
        } else {
            format!("{} bytes", e.size).into()
        });
        ui.set_prop_modified(modified_text(e.modified).into());
        let weak = ui.as_weak();
        slint::Timer::single_shot(Duration::ZERO, move || {
            weak.unwrap().invoke_show_properties()
        });
    }));
    {
        let (weak, state) = (ui.as_weak(), state.clone());
        ui.on_new_tab(move || {
            let (ui, mut s) = (weak.unwrap(), state.borrow_mut());
            let tab = Tab {
                dir: s.cwd.clone(),
                sel: ui.get_current_row(),
            };
            let cur = s.cur;
            s.tabs[cur].sel = tab.sel;
            s.tabs.push(tab);
            s.cur = s.tabs.len() - 1;
            show_tab(&ui, &mut s);
        });
    }
    {
        let (weak, state) = (ui.as_weak(), state.clone());
        ui.on_close_tab(move || {
            let mut s = state.borrow_mut();
            if s.tabs.len() > 1 {
                let cur = s.cur;
                s.tabs.remove(cur);
                s.cur = cur.min(s.tabs.len() - 1);
                show_tab(&weak.unwrap(), &mut s);
            }
        });
    }
    ui.on_switch_tab(handle(|ui, s, i| {
        if i as usize != s.cur {
            switch_tab(ui, s, i as usize);
        }
    }));
    ui.on_step_tab(handle(|ui, s, step| {
        let n = s.tabs.len() as i32;
        let to = (s.cur as i32 + step).rem_euclid(n) as usize;
        if to != s.cur {
            switch_tab(ui, s, to);
        }
    }));
    {
        let (weak, state) = (ui.as_weak(), state.clone());
        ui.on_prepare_rename(move || {
            update_rename(&weak.unwrap(), &state.borrow(), "", "");
            let weak = weak.clone();
            slint::Timer::single_shot(Duration::ZERO, move || weak.unwrap().invoke_show_rename());
        });
    }
    {
        let (weak, state) = (ui.as_weak(), state.clone());
        ui.on_rename_changed(move |find, replace| {
            update_rename(&weak.unwrap(), &state.borrow(), &find, &replace);
        });
    }
    {
        let (weak, state) = (ui.as_weak(), state.clone());
        ui.on_rename_apply(move |find, replace| {
            let mut s = state.borrow_mut();
            let (pairs, conflict) = plan_rename(&s.entries, &find, &replace);
            if find.is_empty() || !conflict.is_empty() {
                return;
            }
            for (old, new) in pairs {
                if let Err(e) = std::fs::rename(s.cwd.join(&old), s.cwd.join(&new)) {
                    eprintln!("rename {old}: {e}");
                }
            }
            let dir = s.cwd.clone();
            navigate(&weak.unwrap(), &mut s, dir);
        });
    }
    {
        let (weak, state) = (ui.as_weak(), state.clone());
        ui.on_up(move || {
            let mut s = state.borrow_mut();
            if let Some(parent) = s.cwd.parent().map(Path::to_path_buf) {
                navigate(&weak.unwrap(), &mut s, parent);
            }
        });
    }
    {
        let state = state.clone();
        ui.on_path_of(move |row| {
            let s = state.borrow();
            s.entries
                .get(row as usize)
                .map(|e| e.path.display().to_string())
                .unwrap_or_default()
                .into()
        });
    }
    // Slint's menu opens with no item highlighted and has no API to change that; one
    // synthetic Down (public Window API) highlights the first item, *Open* (brief §3.6).
    {
        let weak = ui.as_weak();
        ui.on_menu_opened(move || {
            let weak = weak.clone();
            slint::Timer::single_shot(Duration::ZERO, move || {
                let ui = weak.unwrap();
                let down: slint::SharedString = slint::platform::Key::DownArrow.into();
                ui.window()
                    .dispatch_event(WindowEvent::KeyPressed { text: down.clone() });
                ui.window()
                    .dispatch_event(WindowEvent::KeyReleased { text: down });
            });
        });
    }
    ui.on_autoscroll_done(|| {
        println!("D006_AUTOSCROLL_DONE");
        std::io::stdout().flush().ok();
        std::process::exit(0);
    });

    // BUDGET_FIRST_FRAME: after the first frame is rendered, right before the renderer's
    // buffer swap presents it.
    let autoscroll = std::env::var("D006_AUTOSCROLL").is_ok_and(|v| v == "1");
    let mut first = true;
    let weak = ui.as_weak();
    ui.window()
        .set_rendering_notifier(move |state, _| {
            if first && matches!(state, RenderingState::AfterRendering) {
                first = false;
                println!("BUDGET_FIRST_FRAME");
                std::io::stdout().flush().ok();
                if autoscroll {
                    let weak = weak.clone();
                    slint::Timer::single_shot(Duration::ZERO, move || {
                        weak.unwrap().invoke_start_autoscroll();
                    });
                }
            }
        })
        .expect("renderer must support the rendering notifier (femtovg or skia)");

    ui.run()
}

#[cfg(test)]
mod tests {
    use super::size_text;

    #[test]
    fn sizes() {
        assert_eq!(size_text(0), "0 B");
        assert_eq!(size_text(120), "120 B");
        assert_eq!(size_text(345_678), "345.7 kB");
        assert_eq!(size_text(1_048_576), "1.0 MB");
        assert_eq!(size_text(999_999), "1.0 MB");
    }
}
