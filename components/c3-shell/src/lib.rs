// SPDX-License-Identifier: MIT OR Apache-2.0
//! The Atos shell's UI and the parts of it that need no display, so the screenshot and
//! accessibility tests (`tests/`) can use them. The Wayland side is in the binary (`main.rs`).

pub mod config;
pub mod control;
pub mod icons;

slint::include_modules!();

/// The dock's view of one running window. `icon` is empty when the app has none
/// (`icons::load`).
pub fn dock_item(
    id: u32,
    title: &str,
    app_id: &str,
    focused: bool,
    icon: slint::Image,
) -> DockItem {
    let title = if title.is_empty() { app_id } else { title };
    DockItem {
        id: id as i32,
        title: title.into(),
        icon,
        initial: title
            .chars()
            .next()
            .map(|c| c.to_uppercase().collect::<String>())
            .unwrap_or_default()
            .into(),
        focused,
    }
}
