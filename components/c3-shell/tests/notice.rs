// SPDX-License-Identifier: MIT OR Apache-2.0
//! The disk-not-sealed notice renders from the tokens, names its buttons on the accessibility
//! tree and reports what the user does (#138).

use std::cell::Cell;
use std::rc::Rc;

use atos_shell::Notice;
use atos_shell::notice::{BODY, TITLE};
use atos_ui_test::{
    AccessibleRole, accessibility_tree, assert_accessible, assert_screenshot, find_by_label, init,
};
use slint::{ComponentHandle, LogicalSize};

mod test_font {
    include!(concat!(env!("OUT_DIR"), "/cc_test_font.rs"));
}

fn notice() -> Notice {
    init();
    // Creating it registers the bundled font for the whole process.
    let _font = test_font::FontLoader::new().unwrap();
    let ui = Notice::new().unwrap();
    ui.set_font_family("Noto Sans".into());
    ui.set_heading(TITLE.into());
    ui.set_body(BODY.into());
    ui.window().set_size(LogicalSize::new(384., 200.));
    ui
}

#[test]
fn renders_the_warning() {
    assert_screenshot(&notice(), env!("CARGO_MANIFEST_DIR"), "notice");
}

#[test]
fn renders_the_warning_in_dark_mode() {
    let ui = notice();
    ui.global::<atos_shell::Palette>().set_dark(true);
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "notice-dark");
}

#[test]
fn buttons_are_named_and_report_to_the_shell() {
    let ui = notice();
    assert_accessible(&ui, AccessibleRole::Button, "Learn more");
    assert_accessible(&ui, AccessibleRole::Button, "Dismiss");
    let (docs, gone) = (Rc::new(Cell::new(0)), Rc::new(Cell::new(0)));
    {
        let (docs, gone) = (docs.clone(), gone.clone());
        ui.on_open_docs(move || docs.set(docs.get() + 1));
        ui.on_dismissed(move || gone.set(gone.get() + 1));
    }
    find_by_label(&ui, "Learn more")
        .unwrap()
        .invoke_accessible_default_action();
    find_by_label(&ui, "Dismiss")
        .unwrap()
        .invoke_accessible_default_action();
    assert_eq!(
        (docs.get(), gone.get()),
        (1, 1),
        "{:?}",
        accessibility_tree(&ui)
    );
}
