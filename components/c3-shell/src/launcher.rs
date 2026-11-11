// SPDX-License-Identifier: MIT OR Apache-2.0
//! The launcher (#64): opened from the dock's button or by `atos-shell --launcher`, which
//! atos-comp runs for its rebindable `System(Launcher)` shortcut. It lists the installed apps
//! (`atos_shell::apps`) and starts the chosen one.
//!
//! One launcher window lives all session: opening maps it again on a new surface with its
//! renderer's caches (glyphs, icon textures, shadows) still warm, and closing clears the search
//! while it is hidden.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Instant;

use atos_shell::apps::{self, App};
use atos_shell::{AppItem, Launcher, app_item, icons};
use sctk::shell::wlr_layer::Anchor;
use slint::{ComponentHandle, VecModel};

use crate::platform;

const REQUEST: &[u8] = b"launcher";

#[derive(Default)]
struct State {
    apps: Vec<App>,
    icons: HashMap<String, slint::Image>,
    /// The physical size `icons` were loaded for.
    icon_px: u32,
    ui: Option<Launcher>,
    shown: bool,
    started: bool,
    warm: bool,
    /// What the launcher lists, in its order.
    results: Vec<App>,
    opened_at: Option<Instant>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::default();
}

/// Builds the launcher (hidden), reads the installed apps and listens for `--launcher`.
pub fn init() {
    match Launcher::new() {
        Ok(ui) => {
            ui.on_search(|query| search(&query));
            // Deferred: hiding the window inside its own event handler is not safe.
            ui.on_launch(|i| drop(slint::invoke_from_event_loop(move || launch(i as usize))));
            ui.on_dismiss(|| drop(slint::invoke_from_event_loop(close)));
            STATE.with(|s| s.borrow_mut().ui = Some(ui));
        }
        Err(e) => eprintln!("launcher: {e}"),
    }
    // The window's scale is known once it is configured: reload the icons for its physical size.
    platform::on_scale_changed(|w| {
        let query = STATE.with(|s| {
            let s = s.borrow();
            s.ui.as_ref()
                .filter(|l| std::ptr::eq(l.window(), w) && s.shown)
                .map(|l| l.get_query())
        });
        if let Some(q) = query {
            search(&q);
        }
    });
    platform::on_frame_done(|w| {
        let opened = STATE.with(|s| {
            let mut s = s.borrow_mut();
            // After the shell's first frame, so start-up (§7 cold start) does not wait for it:
            // read the apps, then render the hidden launcher once (`warm_up`).
            if !std::mem::replace(&mut s.started, true) {
                rescan();
            }
            let mine = s.ui.as_ref().is_some_and(|l| std::ptr::eq(l.window(), w));
            if mine { s.opened_at.take() } else { None }
        });
        // The first frame after opening is on screen: §7 "popover fully visible".
        // `_SHOWN_NS` is wall-clock time, so the e2e can time from before it runs
        // `atos-shell --launcher` (the shortcut's path, process start included).
        if let Some(t) = opened {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default();
            println!("LAUNCHER_OPEN_MS {:.1}", t.elapsed().as_secs_f64() * 1000.);
            println!("LAUNCHER_SHOWN_NS {}", now.as_nanos());
            std::io::stdout().flush().ok();
        }
    });
    if let Err(e) = listen() {
        eprintln!("launcher: no {}: {e}", socket_path().display());
    }
}

pub fn toggle() {
    let shown = STATE.with(|s| s.borrow().shown);
    if shown { close() } else { open() }
}

fn ui() -> Option<Launcher> {
    STATE.with(|s| s.borrow().ui.as_ref().map(|u| u.clone_strong()))
}

fn open() {
    let started = Instant::now();
    let Some(ui) = ui() else { return };
    let placement = platform::Placement {
        anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
        margin: [0; 4],
        overlay: true,
    };
    if let Err(e) = platform::with_placement(placement, || ui.show()) {
        eprintln!("launcher: {e}");
        return;
    }
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.shown = true;
        s.opened_at = Some(started);
    });
    // Apps installed since the last opening show up once the scan is done.
    rescan();
}

/// Hides the launcher; while hidden, clears the search for the next opening.
fn close() {
    let was_shown = STATE.with(|s| std::mem::take(&mut s.borrow_mut().shown));
    let Some(ui) = ui().filter(|_| was_shown) else {
        return;
    };
    ui.hide().ok();
    let searched = !ui.get_query().is_empty();
    ui.invoke_reset();
    if searched {
        search("");
    }
}

fn items(s: &mut State, apps: &[App]) -> slint::ModelRc<AppItem> {
    let px = s.ui.as_ref().map_or(0, |ui| {
        (ui.get_icon_size() * ui.window().scale_factor()).ceil() as u32
    });
    if px != std::mem::replace(&mut s.icon_px, px) {
        s.icons.clear();
    }
    let items: Vec<AppItem> = apps
        .iter()
        .map(|a| {
            let icon = s
                .icons
                .entry(a.icon.clone())
                .or_insert_with(|| icons::load_named(&a.icon, px))
                .clone();
            app_item(&a.name, icon)
        })
        .collect();
    Rc::new(VecModel::from(items)).into()
}

fn search(query: &str) {
    STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        s.results = apps::search(&s.apps, query).into_iter().cloned().collect();
        let results = s.results.clone();
        let model = items(s, &results);
        if let Some(ui) = &s.ui {
            ui.set_apps(model);
        }
    });
}

fn launch(i: usize) {
    let Some(app) = STATE.with(|s| s.borrow().results.get(i).cloned()) else {
        return;
    };
    close();
    let mut cmd = std::process::Command::new(&app.argv[0]);
    cmd.args(&app.argv[1..]);
    if let Some(dir) = &app.dir {
        cmd.current_dir(dir);
    }
    crate::x11::spawn_detached(cmd, format!("launcher: {}", app.id));
}

/// Reads the desktop entries off the event loop; takes the result only if it changed.
fn rescan() {
    std::thread::spawn(|| {
        let found = apps::installed();
        slint::invoke_from_event_loop(move || {
            let (query, warm) = STATE.with(|s| {
                let mut s = s.borrow_mut();
                let changed = s.apps != found;
                s.apps = found;
                let query =
                    changed.then(|| s.ui.as_ref().map(|u| u.get_query()).unwrap_or_default());
                (query, std::mem::replace(&mut s.warm, true))
            });
            if let Some(q) = query {
                search(&q);
            }
            if let (false, Some(ui)) = (warm, ui()) {
                // Any output at least this high shows the same panel, so the cached shadows,
                // glyphs and icons are the ones the first opening draws.
                platform::warm_up(ui.window(), slint::LogicalSize::new(1920., 1080.));
            }
        })
        .ok();
    });
}

/// One socket per Wayland display in the user's runtime directory (mode 0700).
fn socket_path() -> PathBuf {
    let dir = std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_default();
    let display = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".into());
    let display = display.rsplit('/').next().unwrap_or_default().to_owned();
    PathBuf::from(dir).join(format!("atos-shell-{display}.sock"))
}

fn listen() -> std::io::Result<()> {
    let path = socket_path();
    // A socket left by a shell that exited; a running one loses its socket to us.
    std::fs::remove_file(&path).ok();
    let listener = UnixListener::bind(&path)?;
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut buf = Vec::new();
            if stream
                .take(REQUEST.len() as u64)
                .read_to_end(&mut buf)
                .is_ok()
                && buf == REQUEST
            {
                slint::invoke_from_event_loop(toggle).ok();
            }
        }
    });
    Ok(())
}

/// `atos-shell --launcher`: asks the running shell to open or close its launcher.
pub fn request() -> Result<(), Box<dyn std::error::Error>> {
    let path = socket_path();
    UnixStream::connect(&path)
        .and_then(|mut s| s.write_all(REQUEST))
        .map_err(|e| format!("no shell at {}: {e}", path.display()).into())
}
