// SPDX-License-Identifier: MIT OR Apache-2.0
//! The launcher (#64): opened from the dock's button or by `atos-shell --launcher`, which
//! atos-comp runs for its rebindable `System(Launcher)` shortcut. It lists the installed apps
//! (`atos_shell::apps`) and starts the chosen one.
//!
//! A hidden layer surface cannot be shown again (platform.rs), so every opening uses a new
//! window. One is always built ahead, EGL context and renderer included, so opening only maps it.

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
    shown: Option<Launcher>,
    /// What the shown launcher lists, in its order.
    results: Vec<App>,
    next: Option<Launcher>,
    opened_at: Option<Instant>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::default();
}

/// Builds the first launcher, reads the installed apps and listens for `--launcher`.
pub fn init() {
    STATE.with(|s| s.borrow_mut().next = build().ok());
    rescan();
    platform::on_frame_done(|w| {
        let opened = STATE.with(|s| {
            let mut s = s.borrow_mut();
            let mine = s
                .shown
                .as_ref()
                .is_some_and(|l| std::ptr::eq(l.window(), w));
            if mine { s.opened_at.take() } else { None }
        });
        // The first frame of a new launcher is on screen: §7 "popover fully visible".
        if let Some(t) = opened {
            println!("LAUNCHER_OPEN_MS {:.1}", t.elapsed().as_secs_f64() * 1000.);
            std::io::stdout().flush().ok();
        }
    });
    if let Err(e) = listen() {
        eprintln!("launcher: no {}: {e}", socket_path().display());
    }
}

pub fn toggle() {
    let shown = STATE.with(|s| s.borrow().shown.is_some());
    if shown { close() } else { open() }
}

fn open() {
    let started = Instant::now();
    let Some(ui) = STATE
        .with(|s| s.borrow_mut().next.take())
        .or_else(|| build().ok())
    else {
        return;
    };
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
        s.results = s.apps.clone();
        s.shown = Some(ui);
        s.opened_at = Some(started);
    });
    // Apps installed since the last opening show up once the scan is done.
    rescan();
}

fn close() {
    let Some(ui) = STATE.with(|s| s.borrow_mut().shown.take()) else {
        return;
    };
    ui.hide().ok();
    drop(ui);
    let next = build().ok();
    STATE.with(|s| s.borrow_mut().next = next);
}

/// A hidden launcher listing every app.
fn build() -> Result<Launcher, slint::PlatformError> {
    let ui = Launcher::new()?;
    ui.on_search(|query| search(&query));
    // Deferred: closing drops the launcher, which must not happen inside its own callback.
    ui.on_launch(|i| drop(slint::invoke_from_event_loop(move || launch(i as usize))));
    ui.on_dismiss(|| drop(slint::invoke_from_event_loop(close)));
    STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        let all = s.apps.clone();
        ui.set_apps(items(s, &all));
    });
    Ok(ui)
}

fn items(s: &mut State, apps: &[App]) -> slint::ModelRc<AppItem> {
    let items: Vec<AppItem> = apps
        .iter()
        .map(|a| {
            let icon = s
                .icons
                .entry(a.icon.clone())
                .or_insert_with(|| icons::load_named(&a.icon))
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
        if let Some(ui) = &s.shown {
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
    match cmd.spawn() {
        // ponytail: one thread per started app, only to reap it. Fine at human launch rates.
        Ok(mut child) => drop(std::thread::spawn(move || child.wait())),
        Err(e) => eprintln!("launcher: {}: {e}", app.id),
    }
}

/// Reads the desktop entries off the event loop; takes the result only if it changed.
fn rescan() {
    std::thread::spawn(|| {
        let found = apps::installed();
        slint::invoke_from_event_loop(move || {
            let (changed, query) = STATE.with(|s| {
                let mut s = s.borrow_mut();
                let changed = s.apps != found;
                if changed {
                    s.apps = found;
                }
                (changed, s.shown.as_ref().map(|l| l.get_query()))
            });
            if !changed {
                return;
            }
            if let Some(q) = query {
                search(&q);
            }
            let next = STATE.with(|s| s.borrow_mut().next.take());
            if let Some(ui) = next {
                STATE.with(|s| {
                    let s = &mut *s.borrow_mut();
                    let all = s.apps.clone();
                    ui.set_apps(items(s, &all));
                    s.next = Some(ui);
                });
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
