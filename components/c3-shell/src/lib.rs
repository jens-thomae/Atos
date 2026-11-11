// SPDX-License-Identifier: MIT OR Apache-2.0
//! The Atos shell's UI and the parts of it that need no display, so the screenshot and
//! accessibility tests (`tests/`) can use them. The Wayland side is in the binary (`main.rs`).

pub mod apps;
pub mod config;
pub mod control;
pub mod icons;
pub mod notice;
pub mod switcher_model;

slint::include_modules!();

/// The launcher's view of one app. `icon` is empty when the app has none (`icons::load_named`).
pub fn app_item(name: &str, icon: slint::Image) -> AppItem {
    AppItem {
        name: name.into(),
        icon,
        initial: initial(name),
    }
}

fn initial(s: &str) -> slint::SharedString {
    s.chars()
        .next()
        .map(|c| c.to_uppercase().collect::<String>())
        .unwrap_or_default()
        .into()
}

/// The dock's view of one running window. `icon` is empty when the app has none
/// (`icons::load`).
pub fn dock_item(
    id: u32,
    title: &str,
    app_id: &str,
    focused: bool,
    minimized: bool,
    icon: slint::Image,
) -> DockItem {
    let title = if title.is_empty() { app_id } else { title };
    DockItem {
        id: id as i32,
        title: title.into(),
        icon,
        initial: initial(title),
        focused,
        minimized,
    }
}

/// The window switcher's view of one tile. `icon` is empty when the app has none (`icons::load`).
/// `windows` is how many windows the app has; more than one shows a stacked look.
pub fn switcher_item(
    title: &str,
    app_name: &str,
    windows: usize,
    icon: slint::Image,
    preview: slint::Image,
) -> SwitcherItem {
    SwitcherItem {
        title: title.into(),
        app_name: app_name.into(),
        icon,
        preview,
        initial: initial(if title.is_empty() { app_name } else { title }),
        windows: windows as i32,
    }
}
