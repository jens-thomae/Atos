// SPDX-License-Identifier: MIT OR Apache-2.0
//! The Atos shell: one process (D-006) drawing the shell's layer surfaces on every output.
//! Today that is the dock-taskbar with the running windows (#63) and the launcher (#64).
//! `atos-shell --launcher` opens or closes the launcher of the running shell.

mod accesskit;
mod audio;
mod control_centre;
mod launcher;
mod notice_ui;
mod platform;
mod portal;
mod services;
mod switcher;
mod toplevels;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use atos_shell::{Dock, DockItem, Palette, config, dock_item};
use sctk::reexports::client::Proxy;
use sctk::shell::wlr_layer::Anchor;
use slint::{ComponentHandle, Model, VecModel};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().nth(1).as_deref() == Some("--launcher") {
        return launcher::request();
    }
    if std::env::args().nth(1).as_deref() == Some("--switcher") {
        let forward = std::env::args().nth(2).as_deref() != Some("prev");
        return launcher::request_switcher(forward);
    }
    slint::platform::set_platform(Box::new(platform::WaylandPlatform::new()?))
        .map_err(|e| format!("{e:?}"))?;

    // One model for all docks: every output shows the same running windows.
    let items = Rc::new(VecModel::<DockItem>::default());
    let docks = Rc::new(RefCell::new(HashMap::<u32, Dock>::new()));
    // Icons are loaded for the physical size of the sharpest dock (the model is shared); when a
    // dock's scale becomes known or changes, the same list is read again.
    let refresh = {
        let (items, docks) = (items.clone(), docks.clone());
        let icons = RefCell::new(Icons::default());
        Rc::new(move |list: Vec<toplevels::Toplevel>| {
            let px = docks
                .try_borrow()
                .map(|d| dock_icon_px(&d))
                .unwrap_or_default();
            update(&items, &list, &mut icons.borrow_mut(), px)
        })
    };
    {
        let refresh = refresh.clone();
        toplevels::on_change(move |list| {
            switcher::windows_changed(&list);
            refresh(list)
        });
    }
    {
        let refresh = refresh.clone();
        platform::on_scale_changed(move |_| refresh(toplevels::list()));
    }
    let first_error = Rc::new(RefCell::new(None));
    {
        let (docks, first_error) = (docks.clone(), first_error.clone());
        platform::on_outputs(move |output, added| {
            let key = output.id().protocol_id();
            if !added {
                if let Some(dock) = docks.borrow_mut().remove(&key) {
                    dock.hide().ok();
                }
                return;
            }
            match new_dock(output, &items) {
                Ok(dock) => {
                    docks.borrow_mut().insert(key, dock);
                }
                Err(e) => {
                    eprintln!("dock on output {key}: {e}");
                    first_error.borrow_mut().get_or_insert(e);
                }
            }
        });
    }
    if docks.borrow().is_empty() {
        let why = first_error.borrow_mut().take();
        return Err(why.unwrap_or_else(|| "no output".into()));
    }
    launcher::init();
    switcher::init();
    {
        let docks = docks.clone();
        control_centre::init(move |dark| {
            for dock in docks.borrow().values() {
                dock.global::<Palette>().set_dark(dark);
            }
        });
    }
    let dark = config::path().is_some_and(|f| config::get_bool(&f, "dark_mode"));
    notice_ui::init(dark);
    slint::run_event_loop_until_quit()?;
    Ok(())
}

fn new_dock(
    output: &sctk::reexports::client::protocol::wl_output::WlOutput,
    items: &Rc<VecModel<DockItem>>,
) -> Result<Dock, Box<dyn std::error::Error>> {
    let dock = platform::with_output(output, Dock::new)?;
    dock.set_items(items.clone().into());
    dock.on_activate(|id| toplevels::activate(id as u32));
    dock.on_open_launcher(launcher::toggle);
    dock.on_open_control_centre(control_centre::toggle);
    // Bottom of the output, floating: the gap to the screen edges comes from the tokens.
    let gap = dock.get_edge_gap() as i32;
    let placement = platform::Placement {
        anchor: Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
        margin: [0, gap, gap, gap],
        overlay: false,
    };
    platform::with_placement(placement, || dock.show())?;
    Ok(dock)
}

/// Keeps the model in step with the compositor's list, changing only rows that differ so the
/// docks do not rebuild every slot on each title change. Icons are read once per app ID.
fn update(items: &VecModel<DockItem>, list: &[toplevels::Toplevel], icons: &mut Icons, px: u32) {
    if px != std::mem::replace(&mut icons.px, px) {
        icons.map.clear();
    }
    let new: Vec<DockItem> = list
        .iter()
        .map(|t| {
            let icon = icons
                .map
                .entry(t.app_id.clone())
                .or_insert_with(|| atos_shell::icons::load(&t.app_id, px))
                .clone();
            dock_item(t.id, &t.title, &t.app_id, t.activated, icon)
        })
        .collect();
    while items.row_count() > new.len() {
        items.remove(items.row_count() - 1);
    }
    for (i, item) in new.into_iter().enumerate() {
        match items.row_data(i) {
            Some(old) if old == item => {}
            Some(_) => items.set_row_data(i, item),
            None => items.push(item),
        }
    }
}

/// Icons by app ID, loaded for `px` physical pixels.
#[derive(Default)]
struct Icons {
    px: u32,
    map: HashMap<String, slint::Image>,
}

/// The physical size of the biggest dock tile (a dock not configured yet counts as scale 1).
fn dock_icon_px(docks: &HashMap<u32, Dock>) -> u32 {
    docks
        .values()
        .map(|d| (d.get_tile_size() * d.window().scale_factor()).ceil() as u32)
        .max()
        .unwrap_or(40)
}
