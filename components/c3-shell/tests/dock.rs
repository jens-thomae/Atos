// SPDX-License-Identifier: MIT OR Apache-2.0
//! The dock-taskbar renders from the tokens, names every running window on the accessibility
//! tree and reports the clicked window (#63). Fixture icons are in tests/icons/.

use std::cell::Cell;
use std::rc::Rc;

use atos_shell::{Dock, dock_item};
use atos_ui_test::{AccessibleRole, accessibility_tree, assert_screenshot, find_by_label, init};
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, Image, LogicalPosition, LogicalSize, ModelRc, VecModel};

fn icon(name: &str) -> Image {
    Image::load_from_path(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/icons")
            .join(name),
    )
    .expect("fixture icon")
}

/// Two windows of the same app, one of another app (focused); no text is drawn, so the
/// screenshot does not depend on the machine's fonts.
fn dock() -> (Dock, Rc<Cell<i32>>) {
    let ui = Dock::new().unwrap();
    ui.window().set_size(LogicalSize::new(480., 64.));
    ui.set_items(ModelRc::new(VecModel::from(vec![
        dock_item(
            7,
            "Report.txt",
            "org.atos.TextEditor",
            false,
            icon("circle.svg"),
        ),
        dock_item(
            8,
            "Notes.txt",
            "org.atos.TextEditor",
            false,
            icon("circle.svg"),
        ),
        dock_item(9, "Downloads", "org.atos.Files", true, icon("square.svg")),
    ])));
    let clicked = Rc::new(Cell::new(0));
    let c = clicked.clone();
    ui.on_activate(move |id| c.set(id));
    (ui, clicked)
}

#[test]
fn renders_running_windows() {
    init();
    let (ui, _) = dock();
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "dock");
}

#[test]
fn names_every_window_and_the_focused_one() {
    init();
    let (ui, _) = dock();
    let buttons: Vec<String> = accessibility_tree(&ui)
        .into_iter()
        .filter(|(r, _)| *r == AccessibleRole::Button)
        .map(|(_, l)| l)
        .collect();
    assert_eq!(
        buttons,
        [
            "Report.txt, running",
            "Notes.txt, running",
            "Downloads, focused"
        ]
    );
}

#[test]
fn accessible_action_activates_the_window() {
    init();
    let (ui, clicked) = dock();
    find_by_label(&ui, "Notes.txt, running")
        .unwrap()
        .invoke_accessible_default_action();
    assert_eq!(clicked.get(), 8);
}

#[test]
fn click_activates_the_window() {
    init();
    let (ui, clicked) = dock();
    ui.show().unwrap();
    // The centre of the third slot's tile.
    let slot = find_by_label(&ui, "Downloads, focused").unwrap();
    let (pos, size) = (slot.absolute_position(), slot.size());
    let position = LogicalPosition::new(pos.x + size.width / 2., pos.y + size.height / 2.);
    let w = ui.window();
    w.dispatch_event(WindowEvent::PointerMoved { position });
    w.dispatch_event(WindowEvent::PointerPressed {
        position,
        button: PointerEventButton::Left,
    });
    w.dispatch_event(WindowEvent::PointerReleased {
        position,
        button: PointerEventButton::Left,
    });
    assert_eq!(clicked.get(), 9);
}

#[test]
fn window_without_icon_or_title_falls_back() {
    init();
    let item = dock_item(1, "", "org.example.app", false, Image::default());
    assert_eq!(item.title, "org.example.app");
    assert_eq!(item.initial, "O");
}
