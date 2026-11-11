// SPDX-License-Identifier: MIT OR Apache-2.0
//! Running windows: `ext-foreign-toplevel-list-v1` lists them (title, app ID), atos-comp's
//! `zcosmic_toplevel_info_v1` adds their state (activated) and `zcosmic_toplevel_manager_v1`
//! activates one. These are the protocols atos-comp (the cosmic-comp fork, D-007) implements;
//! it offers them to unsandboxed clients only. Without them the dock stays empty or cannot
//! activate, but the shell still runs (headless sway in the measurement jobs has neither).

use std::cell::RefCell;

use cosmic_protocols::toplevel_info::v1::client::{
    zcosmic_toplevel_handle_v1, zcosmic_toplevel_info_v1,
};
use cosmic_protocols::toplevel_management::v1::client::zcosmic_toplevel_manager_v1;
use sctk::reexports::client::globals::GlobalList;
use sctk::reexports::client::{Connection, Dispatch, Proxy, QueueHandle, event_created_child};
use sctk::reexports::protocols::ext::foreign_toplevel_list::v1::client::{
    ext_foreign_toplevel_handle_v1 as ext_handle, ext_foreign_toplevel_list_v1 as ext_list,
};

use crate::platform::{State, seat};

/// One running window, as the dock shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Toplevel {
    /// Stable for the window's lifetime (the protocol object ID of its ext handle).
    pub id: u32,
    pub title: String,
    pub app_id: String,
    pub activated: bool,
}

struct Entry {
    handle: ext_handle::ExtForeignToplevelHandleV1,
    cosmic: Option<zcosmic_toplevel_handle_v1::ZcosmicToplevelHandleV1>,
    /// Pending until the handle's `done`; `None` before the first `done`.
    pending: Toplevel,
    shown: bool,
}

type ChangeHook = Box<dyn Fn(Vec<Toplevel>)>;

#[derive(Default)]
struct Toplevels {
    info: Option<zcosmic_toplevel_info_v1::ZcosmicToplevelInfoV1>,
    manager: Option<zcosmic_toplevel_manager_v1::ZcosmicToplevelManagerV1>,
    entries: Vec<Entry>,
}

thread_local! {
    static TOPLEVELS: RefCell<Toplevels> = RefCell::default();
    static ON_CHANGE: RefCell<Option<ChangeHook>> = const { RefCell::new(None) };
}

pub fn bind(globals: &GlobalList, qh: &QueueHandle<State>) {
    // Bound for its events only; the list object lives as long as the connection.
    let _ = globals.bind::<ext_list::ExtForeignToplevelListV1, _, _>(qh, 1..=1, ());
    TOPLEVELS.with(|t| {
        let mut t = t.borrow_mut();
        // Version 2 introduced `get_cosmic_toplevel` on top of the ext list.
        t.info = globals.bind(qh, 2..=3, ()).ok();
        t.manager = globals.bind(qh, 1..=4, ()).ok();
    });
}

/// `hook` gets the full list, in opening order, whenever it changes.
pub fn on_change(hook: impl Fn(Vec<Toplevel>) + 'static) {
    hook(list());
    ON_CHANGE.with(|h| *h.borrow_mut() = Some(Box::new(hook)));
}

pub fn list() -> Vec<Toplevel> {
    TOPLEVELS.with(|t| {
        t.borrow()
            .entries
            .iter()
            .filter(|e| e.shown)
            .map(|e| e.pending.clone())
            .collect()
    })
}

/// Asks the compositor to activate (raise and focus) the window. A no-op without the
/// management protocol or a seat.
pub fn activate(id: u32) {
    TOPLEVELS.with(|t| {
        let t = t.borrow();
        let cosmic = t
            .entries
            .iter()
            .find(|e| e.pending.id == id)
            .and_then(|e| e.cosmic.as_ref());
        if let (Some(m), Some(c), Some(s)) = (&t.manager, cosmic, seat()) {
            m.activate(c, &s);
        }
    });
}

/// Asks the compositor to close the window (a request to the app, as the window's close button).
pub fn close(id: u32) {
    TOPLEVELS.with(|t| {
        let t = t.borrow();
        let cosmic = t
            .entries
            .iter()
            .find(|e| e.pending.id == id)
            .and_then(|e| e.cosmic.as_ref());
        if let (Some(m), Some(c)) = (&t.manager, cosmic) {
            m.close(c);
        }
    });
}

fn changed() {
    let list = list();
    ON_CHANGE.with(|h| {
        if let Some(h) = &*h.borrow() {
            h(list)
        }
    });
}

fn with_entry(handle_id: u32, f: impl FnOnce(&mut Entry)) {
    TOPLEVELS.with(|t| {
        if let Some(e) = t
            .borrow_mut()
            .entries
            .iter_mut()
            .find(|e| e.pending.id == handle_id)
        {
            f(e)
        }
    });
}

impl Dispatch<ext_list::ExtForeignToplevelListV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ext_list::ExtForeignToplevelListV1,
        event: ext_list::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let ext_list::Event::Toplevel { toplevel } = event {
            TOPLEVELS.with(|t| {
                let mut t = t.borrow_mut();
                let cosmic = t
                    .info
                    .as_ref()
                    .map(|i| i.get_cosmic_toplevel(&toplevel, qh, toplevel.id().protocol_id()));
                let id = toplevel.id().protocol_id();
                t.entries.push(Entry {
                    handle: toplevel,
                    cosmic,
                    pending: Toplevel {
                        id,
                        ..Toplevel::default()
                    },
                    shown: false,
                });
            });
        }
    }

    event_created_child!(State, ext_list::ExtForeignToplevelListV1, [
        ext_list::EVT_TOPLEVEL_OPCODE => (ext_handle::ExtForeignToplevelHandleV1, ()),
    ]);
}

impl Dispatch<ext_handle::ExtForeignToplevelHandleV1, ()> for State {
    fn event(
        _: &mut Self,
        handle: &ext_handle::ExtForeignToplevelHandleV1,
        event: ext_handle::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let id = handle.id().protocol_id();
        match event {
            ext_handle::Event::Title { title } => with_entry(id, |e| e.pending.title = title),
            ext_handle::Event::AppId { app_id } => with_entry(id, |e| e.pending.app_id = app_id),
            ext_handle::Event::Done => {
                with_entry(id, |e| e.shown = true);
                changed();
            }
            ext_handle::Event::Closed => {
                TOPLEVELS.with(|t| {
                    let mut t = t.borrow_mut();
                    if let Some(i) = t.entries.iter().position(|e| e.pending.id == id) {
                        let e = t.entries.remove(i);
                        if let Some(c) = e.cosmic {
                            c.destroy();
                        }
                        e.handle.destroy();
                    }
                });
                changed();
            }
            _ => {}
        }
    }
}

impl Dispatch<zcosmic_toplevel_info_v1::ZcosmicToplevelInfoV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &zcosmic_toplevel_info_v1::ZcosmicToplevelInfoV1,
        _: zcosmic_toplevel_info_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }

    // Version 1's `toplevel` event creates handles; we bind version 2 or later, which never sends it.
    event_created_child!(State, zcosmic_toplevel_info_v1::ZcosmicToplevelInfoV1, [
        zcosmic_toplevel_info_v1::EVT_TOPLEVEL_OPCODE => (zcosmic_toplevel_handle_v1::ZcosmicToplevelHandleV1, 0),
    ]);
}

/// User data: the protocol ID of the ext handle this cosmic handle extends.
impl Dispatch<zcosmic_toplevel_handle_v1::ZcosmicToplevelHandleV1, u32> for State {
    fn event(
        _: &mut Self,
        _: &zcosmic_toplevel_handle_v1::ZcosmicToplevelHandleV1,
        event: zcosmic_toplevel_handle_v1::Event,
        ext_id: &u32,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zcosmic_toplevel_handle_v1::Event::State { state } = event {
            let activated = parse_activated(&state);
            with_entry(*ext_id, |e| e.pending.activated = activated);
            changed();
        }
    }
}

impl Dispatch<zcosmic_toplevel_manager_v1::ZcosmicToplevelManagerV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &zcosmic_toplevel_manager_v1::ZcosmicToplevelManagerV1,
        _: zcosmic_toplevel_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

/// The state array is native-endian u32 values (wl_array); 2 is `activated`.
fn parse_activated(state: &[u8]) -> bool {
    let activated = zcosmic_toplevel_handle_v1::State::Activated as u32;
    state
        .as_chunks::<4>()
        .0
        .iter()
        .any(|c| u32::from_ne_bytes(*c) == activated)
}

#[cfg(test)]
mod tests {
    use super::parse_activated;

    #[test]
    fn activated_is_found_in_the_state_array() {
        let bytes = |v: &[u32]| v.iter().flat_map(|x| x.to_ne_bytes()).collect::<Vec<u8>>();
        assert!(parse_activated(&bytes(&[0, 2])));
        assert!(!parse_activated(&bytes(&[0, 1, 3])));
        assert!(!parse_activated(&[]));
    }
}
