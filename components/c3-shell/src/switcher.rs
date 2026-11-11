// SPDX-License-Identifier: MIT OR Apache-2.0
//! The Alt+Tab window switcher (#226). atos-comp runs `atos-shell --switcher next` (or `prev`)
//! for its `System(WindowSwitcher)` shortcuts, which reaches this shell over the launcher's
//! socket. The panel takes the keyboard while shown, so the compositor still matches Alt+Tab and
//! sends the next request, and releasing Alt reaches `platform::on_modifiers`: that activates the
//! selection. Order and selection are `atos_shell::switcher_model`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Write;
use std::rc::Rc;
use std::time::Instant;

use atos_shell::switcher_model::{Mru, Switcher as Selection, Win};
use atos_shell::{Switcher, SwitcherItem, apps, icons, switcher_item};
use sctk::shell::wlr_layer::Anchor;
use slint::{ComponentHandle, Model, VecModel};

use crate::{capture, platform, toplevels};

#[derive(Default)]
struct State {
    ui: Option<Switcher>,
    shown: bool,
    mru: Mru,
    /// Every window, in opening order.
    wins: Vec<Win>,
    sel: Selection,
    icons: HashMap<String, slint::Image>,
    /// App names by desktop file ID, read when the switcher first opens.
    names: Option<HashMap<String, String>>,
    /// The panel has seen a keyboard event of its own since opening.
    keyboard: bool,
    /// Counts openings, so an old timer does not cancel a newer panel.
    opening: u32,
    /// Window previews by window ID, scaled to tile size; only while shown (#266).
    previews: HashMap<u32, slint::Image>,
    /// When the open request arrived; taken by the panel's first frame.
    opened_at: Option<Instant>,
    /// When the panel was shown; taken by the first preview.
    shown_at: Option<Instant>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::default();
}

pub fn init() {
    let ui = match Switcher::new() {
        Ok(ui) => ui,
        Err(e) => return eprintln!("switcher: {e}"),
    };
    // Window callbacks run inside the window's event handling: hiding it there is not safe.
    let later = |f: fn()| move || drop(slint::invoke_from_event_loop(f));
    ui.on_cancel(later(close));
    ui.on_confirm(later(commit));
    ui.on_close_window(later(close_window));
    ui.on_same_app(later(|| edit(|s| s.same_app())));
    ui.on_move(|d| drop(slint::invoke_from_event_loop(move || step(d > 0))));
    ui.on_pick(|i| {
        drop(slint::invoke_from_event_loop(move || {
            edit(|s| (s.tile, s.win) = (i as usize, 0));
            commit()
        }))
    });
    STATE.with(|s| s.borrow_mut().ui = Some(ui));
    // Wall-clock time too, so a test can time from before it runs `atos-shell --switcher`.
    platform::on_frame_done(|w| {
        let opened = STATE.with(|s| {
            let mut s = s.borrow_mut();
            let mine = s.ui.as_ref().is_some_and(|u| std::ptr::eq(u.window(), w));
            if mine { s.opened_at.take() } else { None }
        });
        if let Some(t) = opened {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default();
            println!("SWITCHER_OPEN_MS {:.1}", t.elapsed().as_secs_f64() * 1000.);
            println!("SWITCHER_SHOWN_NS {}", now.as_nanos());
            std::io::stdout().flush().ok();
        }
    });
    platform::on_modifiers(|held| {
        STATE.with(|s| s.borrow_mut().keyboard = true);
        if !held && STATE.with(|s| s.borrow().shown) {
            drop(slint::invoke_from_event_loop(commit));
        }
    });
}

/// The compositor's window list changed: remember who is active, refresh an open switcher.
pub fn windows_changed(list: &[toplevels::Toplevel]) {
    let open = STATE
        .try_with(|s| {
            let Ok(mut s) = s.try_borrow_mut() else {
                return false;
            };
            if let Some(t) = list.iter().find(|t| t.activated) {
                s.mru.activated(t.id);
            }
            s.wins = list
                .iter()
                .map(|t| Win {
                    id: t.id,
                    title: t.title.clone(),
                    app_id: t.app_id.clone(),
                })
                .collect();
            s.shown
        })
        .unwrap_or(false);
    if open {
        edit(|_| {});
        previews();
    }
}

/// Alt+Tab (`forward`) or Alt+Shift+Tab: opens the switcher, or moves the selection.
pub fn step(forward: bool) {
    if STATE.with(|s| s.borrow().shown) {
        edit(|s| s.step(forward));
    } else {
        open(forward);
    }
}

fn open(forward: bool) {
    let started = Instant::now();
    let Some(ui) = STATE.with(|s| s.borrow().ui.as_ref().map(|u| u.clone_strong())) else {
        return;
    };
    // Both want the exclusive keyboard.
    crate::launcher::close();
    let ready = STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        if s.wins.is_empty() {
            return false;
        }
        let ordered = s.mru.order(&s.wins);
        s.sel = Selection::open(&ordered);
        if !forward {
            // Back from the current window: the least recently used tile.
            s.sel.tile = 0;
            s.sel.step(false);
        }
        true
    });
    if !ready {
        return;
    }
    render();
    let placement = platform::Placement {
        anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
        margin: [0; 4],
        overlay: true,
    };
    if let Err(e) = platform::with_placement(placement, || ui.show()) {
        return eprintln!("switcher: {e}");
    }
    let opening = STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.shown = true;
        s.keyboard = false;
        s.opening += 1;
        s.opened_at = Some(started);
        s.shown_at = Some(Instant::now());
        s.opening
    });
    // After the panel is shown: frames fill the tiles in as they arrive.
    previews();
    // Without the keyboard (another client holds it) nothing would ever see Alt released.
    slint::Timer::single_shot(std::time::Duration::from_secs(1), move || {
        let stuck = STATE.with(|s| {
            let s = s.borrow();
            s.shown && s.opening == opening && !s.keyboard
        });
        if stuck {
            close();
        }
    });
}

fn close() {
    let was_shown = STATE.with(|s| std::mem::take(&mut s.borrow_mut().shown));
    if was_shown && let Some(ui) = STATE.with(|s| s.borrow().ui.as_ref().map(|u| u.clone_strong()))
    {
        ui.hide().ok();
    }
    // Every capture ends and every picture is dropped with the panel (#266).
    capture::stop();
    STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        s.previews = HashMap::new();
        s.shown_at = None;
        if was_shown && let Some(ui) = &s.ui {
            ui.set_items(Rc::new(VecModel::<SwitcherItem>::default()).into());
        }
    });
}

/// Captures every window of the open switcher (new ones too) at the tiles' preview size.
fn previews() {
    let Some((ids, size)) = STATE.with(|s| {
        let s = s.borrow();
        let ui = s.ui.as_ref().filter(|_| s.shown)?;
        let scale = ui.window().scale_factor();
        let size = (
            (ui.get_preview_width() * scale).ceil() as u32,
            (ui.get_preview_height() * scale).ceil() as u32,
        );
        Some((s.wins.iter().map(|w| w.id).collect::<Vec<_>>(), size))
    }) else {
        return;
    };
    capture::start(&ids, size, preview_arrived);
}

/// A window's frame arrived: show it in its tile if that tile shows this window.
fn preview_arrived(id: u32, image: slint::Image) {
    STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        if !s.shown {
            return;
        }
        if let Some(t) = s.shown_at.take() {
            println!(
                "SWITCHER_FIRST_PREVIEW_MS {:.1}",
                t.elapsed().as_secs_f64() * 1000.
            );
            std::io::stdout().flush().ok();
        }
        s.previews.insert(id, image.clone());
        let Some(ui) = &s.ui else { return };
        let items = ui.get_items();
        for (i, g) in s.sel.groups.iter().enumerate() {
            let win = &g.windows[if i == s.sel.tile { s.sel.win } else { 0 }];
            if win.id == id
                && let Some(mut item) = items.row_data(i)
            {
                item.preview = image.clone();
                items.set_row_data(i, item);
            }
        }
    });
}

/// Alt was released: activates the selected window.
fn commit() {
    let id = STATE.with(|s| s.borrow().sel.selected().map(|w| w.id));
    close();
    if let Some(id) = id {
        toplevels::activate(id);
    }
}

fn close_window() {
    let id = STATE.with(|s| s.borrow().sel.selected().map(|w| w.id));
    if let Some(id) = id {
        toplevels::close(id);
        // Gone from the tiles at once, for this opening only: the compositor's list follows
        // when the app has closed it, and an app that refuses stays in the shell's list.
        edit(|s| s.hide(id));
    }
}

/// Changes the selection (or only re-reads the windows), then redraws.
fn edit(f: impl FnOnce(&mut Selection)) {
    let empty = STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        let ordered = s.mru.order(&s.wins);
        s.sel.update(&ordered);
        f(&mut s.sel);
        s.sel.groups.is_empty()
    });
    if empty {
        close();
    } else {
        render();
    }
}

fn render() {
    STATE.with(|s| {
        let s = &mut *s.borrow_mut();
        let Some(ui) = s.ui.as_ref().map(|u| u.clone_strong()) else {
            return;
        };
        let names = s.names.get_or_insert_with(|| {
            apps::installed()
                .into_iter()
                .map(|a| (a.id, a.name))
                .collect()
        });
        let px = (ui.window().scale_factor() * 64.).ceil() as u32;
        let items: Vec<SwitcherItem> = s
            .sel
            .groups
            .iter()
            .enumerate()
            .map(|(i, g)| {
                let win = &g.windows[if i == s.sel.tile { s.sel.win } else { 0 }];
                let name = names
                    .get(&format!("{}.desktop", g.app_id))
                    .cloned()
                    .unwrap_or_else(|| g.app_id.rsplit('.').next().unwrap_or_default().to_owned());
                let icon = s
                    .icons
                    .entry(g.app_id.clone())
                    .or_insert_with(|| icons::load(&g.app_id, px))
                    .clone();
                let title = if win.title.is_empty() {
                    &name
                } else {
                    &win.title
                };
                let preview = s.previews.get(&win.id).cloned().unwrap_or_default();
                switcher_item(title, &name, g.windows.len(), icon, preview)
            })
            .collect();
        ui.set_items(Rc::new(VecModel::from(items)).into());
        ui.set_selected(s.sel.tile as i32);
    });
}
