// SPDX-License-Identifier: MIT OR Apache-2.0
//! The control centre (#65): a panel above the dock's right end with the quick settings agreed on
//! the card. The window exists only while it is open; the settings read from the system and the
//! audio state live here for the whole session so the panel opens with values already in it.
//!
//! Blocking D-Bus calls run on short worker threads (`services.rs`) and hand their result to the
//! event loop; PipeWire runs on its own thread (`audio.rs`). While the panel is open the services
//! are read again every few seconds; closed, nothing polls (idle CPU budget, §7).

use std::cell::RefCell;
use std::io::Write;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use atos_shell::control::{self, PrivacySource, Quick};
use atos_shell::{ControlCentre, OutputItem, Palette, PowerAction, config};
use sctk::shell::wlr_layer::Anchor;
use slint::{ComponentHandle, ModelRc, SharedString, Timer, TimerMode, VecModel};

use crate::audio::{self, Audio};
use crate::portal::Portal;
use crate::{platform, services};

/// The Settings app (C8) by desktop-entry id; nothing happens if it is not installed.
const SETTINGS_ID: &str = "org.atos.Settings";

#[derive(Default)]
struct Session {
    quick: Quick,
    brightness: Option<f32>,
    audio: Audio,
    audio_handle: Option<audio::Handle>,
    /// When the panel was asked for; taken by the first frame shown (`CONTROL_CENTRE_OPEN_MS`).
    opened_at: Option<Instant>,
    /// Open panel, if any.
    open: Option<Rc<ControlCentre>>,
    /// Re-reads the services while the panel is open.
    poll: Timer,
    /// Source of the privacy chip; none is wired up yet, so the chip stays hidden.
    privacy: Option<Box<dyn PrivacySource>>,
    /// Feeds the brightness worker (created on first use).
    brightness_tx: Option<mpsc::Sender<f32>>,
    /// Tells apps about dark mode (xdg-desktop-portal Settings backend).
    portal: Option<Portal>,
    /// Applies dark mode to every shell window (set by `main`).
    theme: Option<Rc<dyn Fn(bool)>>,
}

thread_local! {
    static SESSION: RefCell<Session> = RefCell::new(Session::default());
}

/// Read the config, start PipeWire and apply the stored theme. Call once the event loop can run.
pub fn init(apply_theme: impl Fn(bool) + 'static) {
    let file = config::path();
    let get = |k| file.as_deref().is_some_and(|f| config::get_bool(f, k));
    let (dark, dnd) = (get("dark_mode"), get("do_not_disturb"));
    let handle = audio::start(|a| {
        slint::invoke_from_event_loop(move || {
            SESSION.with(|s| s.borrow_mut().audio = a);
            sync();
        })
        .ok();
    });
    SESSION.with(|s| {
        let mut s = s.borrow_mut();
        s.quick.dark_mode = dark;
        s.quick.do_not_disturb = dnd;
        s.audio_handle = handle;
        s.portal = Portal::start(dark);
        s.theme = Some(Rc::new(apply_theme));
    });
    theme(dark);
    platform::on_frame_done(|w| {
        let opened = SESSION.with(|s| {
            let mut s = s.borrow_mut();
            let mine = s
                .open
                .as_ref()
                .is_some_and(|ui| std::ptr::eq(ui.window(), w));
            if mine { s.opened_at.take() } else { None }
        });
        // The first frame after opening is on screen: §7 "popover fully visible".
        if let Some(t) = opened {
            println!(
                "CONTROL_CENTRE_OPEN_MS {:.1}",
                t.elapsed().as_secs_f64() * 1000.
            );
            std::io::stdout().flush().ok();
        }
    });
}

fn theme(dark: bool) {
    let apply = SESSION.with(|s| s.borrow().theme.clone());
    if let Some(f) = apply {
        f(dark);
    }
}

/// The dock's button: open the panel, or close it if it is open.
pub fn toggle() {
    if SESSION.with(|s| s.borrow().open.is_some()) {
        close();
    } else if let Err(e) = open() {
        eprintln!("control centre: {e}");
    }
}

fn close() {
    let ui = SESSION.with(|s| {
        s.borrow().poll.stop();
        s.borrow_mut().open.take()
    });
    if let Some(ui) = ui {
        ui.hide().ok();
    }
}

fn open() -> Result<(), Box<dyn std::error::Error>> {
    let started = Instant::now();
    let ui = Rc::new(ControlCentre::new()?);
    ui.set_power_actions(ModelRc::new(VecModel::from(vec![
        PowerAction {
            id: "suspend".into(),
            name: "Suspend".into(),
            confirm: false,
        },
        PowerAction {
            id: "reboot".into(),
            name: "Restart".into(),
            confirm: true,
        },
        PowerAction {
            id: "poweroff".into(),
            name: "Shut down".into(),
            confirm: true,
        },
    ])));
    ui.global::<Palette>()
        .set_dark(SESSION.with(|s| s.borrow().quick.dark_mode));
    wire(&ui);
    SESSION.with(|s| {
        let mut s = s.borrow_mut();
        s.open = Some(ui.clone());
        s.opened_at = Some(started);
    });
    sync();

    // The window covers the output; the panel sits above the dock's right end inside it.
    let placement = platform::Placement {
        anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
        margin: [0; 4],
        overlay: true,
    };
    platform::with_placement(placement, || ui.show())?;

    refresh();
    SESSION.with(|s| {
        // ponytail: polls while open; D-Bus signals if the 3 s lag ever matters
        s.borrow()
            .poll
            .start(TimerMode::Repeated, Duration::from_secs(3), refresh);
    });
    Ok(())
}

fn wire(ui: &Rc<ControlCentre>) {
    ui.on_dismiss(close);
    ui.on_tile_clicked(tile_clicked);
    ui.on_open_settings(|| {
        launch(SETTINGS_ID);
        close();
    });
    ui.on_power_action(|id| {
        let id = id.to_string();
        close();
        std::thread::spawn(move || {
            if let Err(e) = services::power(&id) {
                eprintln!("control centre: {id}: {e}");
            }
        });
    });
    ui.on_brightness_changed(|v| {
        SESSION.with(|s| {
            let mut s = s.borrow_mut();
            s.brightness = Some(v);
            let tx = s.brightness_tx.get_or_insert_with(brightness_worker);
            tx.send(v).ok();
        });
    });
    ui.on_volume_changed(|v| {
        SESSION.with(|s| {
            if let Some(h) = &s.borrow().audio_handle {
                h.send(audio::Command::SetVolume(v));
            }
        });
    });
    ui.on_select_output(|id| {
        SESSION.with(|s| {
            if let Some(h) = &s.borrow().audio_handle {
                h.send(audio::Command::SelectOutput(id as u32));
            }
        });
    });
}

/// One thread applies brightness changes in order and skips the ones a newer value has replaced,
/// so a drag cannot end on an earlier value than where the slider stopped.
fn brightness_worker() -> mpsc::Sender<f32> {
    let (tx, rx) = mpsc::channel::<f32>();
    std::thread::spawn(move || {
        while let Ok(mut v) = rx.recv() {
            while let Ok(newer) = rx.try_recv() {
                v = newer;
            }
            if let Err(e) = services::set_brightness(v) {
                eprintln!("control centre: brightness: {e}");
            }
        }
    });
    tx
}

fn tile_clicked(id: SharedString) {
    let q = SESSION.with(|s| s.borrow().quick.clone());
    match id.as_str() {
        "wifi" => {
            let on = !q.wifi.as_ref().is_some_and(|r| r.on);
            run(move || services::set_wifi(on));
        }
        "bluetooth" => {
            let on = !q.bluetooth.as_ref().is_some_and(|r| r.on);
            run(move || services::set_bluetooth(on));
        }
        "profile" => run(services::cycle_profile),
        "dnd" => store("do_not_disturb", !q.do_not_disturb),
        "dark" => store("dark_mode", !q.dark_mode),
        _ => {}
    }
}

/// A D-Bus change on a worker thread; the panel reads the result back afterwards.
fn run(f: impl FnOnce() -> Result<(), zbus::Error> + Send + 'static) {
    std::thread::spawn(move || {
        if let Err(e) = f() {
            eprintln!("control centre: {e}");
        }
        slint::invoke_from_event_loop(refresh).ok();
    });
}

/// A switch kept in the shell config (D-010); the file is written first, so the panel never shows
/// a state that is not stored.
fn store(key: &str, on: bool) {
    let stored = match config::path() {
        Some(f) => config::set_bool(&f, key, on),
        None => Err("no config directory".into()),
    };
    if let Err(e) = stored {
        eprintln!("control centre: {key}: {e}");
        return;
    }
    SESSION.with(|s| {
        let mut s = s.borrow_mut();
        match key {
            "dark_mode" => s.quick.dark_mode = on,
            _ => s.quick.do_not_disturb = on,
        }
    });
    if key == "dark_mode" {
        theme(on);
        SESSION.with(|s| {
            if let Some(p) = &s.borrow().portal {
                p.set_dark(on);
            }
        });
    }
    sync();
}

/// Reads Wi-Fi, Bluetooth, the power profile and the backlight on a worker thread.
fn refresh() {
    std::thread::spawn(|| {
        let (wifi, bluetooth) = (services::wifi(), services::bluetooth());
        let profile = services::profiles().map(|(active, _)| active);
        let brightness = services::brightness();
        slint::invoke_from_event_loop(move || {
            SESSION.with(|s| {
                let mut s = s.borrow_mut();
                s.quick.wifi = wifi;
                s.quick.bluetooth = bluetooth;
                s.quick.profile = profile;
                s.brightness = brightness;
            });
            sync();
        })
        .ok();
    });
}

/// Puts the session's state into the open panel. A slider being dragged keeps the user's value.
fn sync() {
    let Some((ui, quick, brightness, audio, chip)) = SESSION.with(|s| {
        let s = s.borrow();
        let chip = control::chip_text(s.privacy.as_deref());
        Some((
            s.open.clone()?,
            s.quick.clone(),
            s.brightness,
            s.audio.clone(),
            chip,
        ))
    }) else {
        return;
    };
    ui.set_privacy(chip.into());
    ui.set_tiles(ModelRc::new(VecModel::from(control::tiles(&quick))));
    ui.set_brightness_available(brightness.is_some());
    if let Some(b) = brightness {
        ui.set_brightness(b);
    }
    ui.set_volume_available(audio.volume.is_some());
    if let Some(v) = audio.volume {
        ui.set_volume(v);
    }
    let outputs: Vec<OutputItem> = audio
        .outputs
        .iter()
        .map(|o| OutputItem {
            id: o.id as i32,
            name: o.name.as_str().into(),
            detail: o.detail.as_str().into(),
            selected: o.selected,
        })
        .collect();
    ui.set_outputs(ModelRc::new(VecModel::from(outputs)));
}

// --- launching the Settings app -----------------------------------------------------------------

// ponytail: a second copy of icons.rs's XDG lookup, so this card does not touch the file the
// launcher card (#64) is changing; one shared helper once both are merged.
fn data_dirs() -> Vec<PathBuf> {
    let var = |k| std::env::var(k).ok().filter(|v| !v.is_empty());
    let home = var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| var("HOME").map(|h| PathBuf::from(h).join(".local/share")));
    let rest = var("XDG_DATA_DIRS").unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    home.into_iter()
        .chain(rest.split(':').map(PathBuf::from))
        .collect()
}

/// The command of `<id>.desktop`'s `Exec=` with the field codes (`%u`, `%F`, ...) dropped.
pub fn exec_command(desktop_entry: &str) -> Option<Vec<String>> {
    let line = desktop_entry
        .lines()
        .skip_while(|l| l.trim() != "[Desktop Entry]")
        .skip(1)
        .take_while(|l| !l.starts_with('['))
        .find_map(|l| l.strip_prefix("Exec="))?;
    let mut args = Vec::new();
    let (mut cur, mut quoted, mut started) = (String::new(), false, false);
    for c in line.trim().chars() {
        match c {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            c if c.is_whitespace() && !quoted => {
                if started {
                    args.push(std::mem::take(&mut cur));
                    started = false;
                }
            }
            c => {
                cur.push(c);
                started = true;
            }
        }
    }
    if started {
        args.push(cur);
    }
    // `%%` is a literal percent; every other field code stands for files or URLs we do not have.
    let args: Vec<String> = args
        .into_iter()
        .filter(|a| !(a.len() == 2 && a.starts_with('%') && a != "%%"))
        .map(|a| a.replace("%%", "%"))
        .collect();
    (!args.is_empty()).then_some(args)
}

fn launch(id: &str) {
    let found = data_dirs().into_iter().find_map(|d| {
        std::fs::read_to_string(d.join("applications").join(format!("{id}.desktop"))).ok()
    });
    let Some(args) = found.as_deref().and_then(exec_command) else {
        return; // not installed
    };
    match std::process::Command::new(&args[0])
        .args(&args[1..])
        .spawn()
    {
        // The shell is the parent; a thread reaps the child so it does not stay a zombie.
        Ok(mut child) => {
            std::thread::spawn(move || child.wait().ok());
        }
        Err(e) => eprintln!("control centre: {id}: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_drops_field_codes_and_honours_quotes() {
        let e = "[Desktop Action x]\nExec=wrong\n[Desktop Entry]\nName=S\nExec=\"/opt/my app/settings\" --page %U %%x\n";
        assert_eq!(
            exec_command(e).unwrap(),
            ["/opt/my app/settings", "--page", "%x"]
        );
        assert_eq!(exec_command("[Desktop Entry]\nName=S\n"), None);
    }
}
