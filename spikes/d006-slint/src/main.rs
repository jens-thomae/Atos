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

struct State {
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
    state.cwd = dir;
    state.last_down = None;
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

/// `glGetString(name)` through the context's loader (GL_RENDERER = 0x1F01).
fn gl_string(get_proc_address: &dyn Fn(&std::ffi::CStr) -> *const std::ffi::c_void, name: u32) -> String {
    let p = get_proc_address(c"glGetString");
    if p.is_null() {
        return "unknown (no glGetString)".into();
    }
    // SAFETY: glGetString has this signature in every GL and GL ES version.
    let f: unsafe extern "system" fn(u32) -> *const std::ffi::c_char = unsafe { std::mem::transmute(p) };
    let s = unsafe { f(name) };
    if s.is_null() {
        "unknown".into()
    } else {
        unsafe { std::ffi::CStr::from_ptr(s) }.to_string_lossy().into_owned()
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

    // BUDGET_FIRST_FRAME. femtovg and Skia: after the first frame is rendered, right before the
    // renderer's buffer swap presents it. Software renderer (SLINT_BACKEND=winit-software), which has
    // no rendering notifier: the first change of animation-tick() in app.slint (see README).
    let autoscroll = std::env::var("D006_AUTOSCROLL").is_ok_and(|v| v == "1");
    let first_frame = {
        let weak = ui.as_weak();
        move || {
            println!("BUDGET_FIRST_FRAME");
            std::io::stdout().flush().ok();
            if autoscroll {
                let weak = weak.clone();
                slint::Timer::single_shot(Duration::ZERO, move || {
                    weak.unwrap().invoke_start_autoscroll();
                });
            }
        }
    };
    if std::env::var("SLINT_BACKEND").is_ok_and(|v| v.contains("software")) {
        // Renderer proof (stderr: stdout carries the markers): no GL, no Mesa in this process.
        eprintln!("D006_RENDERER: slint software (CPU)");
        ui.on_first_frame(first_frame);
        ui.invoke_arm_first_frame();
    } else {
        let mut first_frame = Some(first_frame);
        ui.window()
            .set_rendering_notifier(move |state, api| {
                match state {
                    RenderingState::RenderingSetup => {
                        // Renderer proof: the GL_RENDERER string of the context the app drew with.
                        if let slint::GraphicsAPI::NativeOpenGL { get_proc_address } = api {
                            eprintln!("D006_RENDERER: slint gl {}", gl_string(get_proc_address, 0x1F01));
                        } else {
                            eprintln!("D006_RENDERER: slint unknown graphics API");
                        }
                    }
                    RenderingState::AfterRendering => {
                        if let Some(f) = first_frame.take() {
                            f();
                        }
                    }
                    _ => {}
                }
            })
            .expect("renderer must support the rendering notifier (femtovg or skia)");
    }

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
