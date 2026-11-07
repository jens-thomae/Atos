// SPDX-License-Identifier: MIT OR Apache-2.0
//! The launcher renders from the tokens, names the search field and every app on the
//! accessibility tree, and is usable with the keyboard alone (#64). Fixture icons: tests/icons/.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use atos_shell::{Launcher, app_item};
use atos_ui_test::{
    AccessibleRole, accessibility_tree, assert_accessible, assert_screenshot, find_by_label, init,
};
use slint::platform::{Key, WindowEvent};
use slint::{ComponentHandle, Image, LogicalSize, ModelRc, VecModel};

mod test_font {
    include!(concat!(env!("OUT_DIR"), "/test_font.rs"));
}

fn icon(name: &str) -> Image {
    Image::load_from_path(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/icons")
            .join(name),
    )
    .expect("fixture icon")
}

struct Seen {
    launched: Rc<Cell<i32>>,
    closed: Rc<Cell<bool>>,
    searched: Rc<RefCell<String>>,
}

fn launcher() -> (Launcher, Seen) {
    let ui = Launcher::new().unwrap();
    ui.window().set_size(LogicalSize::new(800., 600.));
    ui.set_apps(ModelRc::new(VecModel::from(vec![
        app_item("Calculator", icon("circle.svg")),
        app_item("Files", icon("square.svg")),
        app_item("Terminal", Image::default()),
    ])));
    let seen = Seen {
        launched: Rc::new(Cell::new(-1)),
        closed: Rc::new(Cell::new(false)),
        searched: Rc::new(RefCell::new(String::new())),
    };
    let l = seen.launched.clone();
    ui.on_launch(move |i| l.set(i));
    let c = seen.closed.clone();
    ui.on_dismiss(move || c.set(true));
    let s = seen.searched.clone();
    ui.on_search(move |q| *s.borrow_mut() = q.into());
    ui.show().unwrap();
    (ui, seen)
}

fn key(ui: &Launcher, k: impl Into<slint::SharedString>) {
    let text = k.into();
    ui.window()
        .dispatch_event(WindowEvent::KeyPressed { text: text.clone() });
    ui.window()
        .dispatch_event(WindowEvent::KeyReleased { text });
}

#[test]
fn renders_search_field_and_apps() {
    init();
    // Creating it registers the bundled font for the whole process.
    let _font = test_font::FontLoader::new().unwrap();
    let (ui, _) = launcher();
    ui.set_font_family("Noto Sans".into());
    ui.window().set_size(LogicalSize::new(720., 520.));
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "launcher");
}

#[test]
fn names_the_field_and_every_app() {
    init();
    let (ui, _) = launcher();
    assert_accessible(&ui, AccessibleRole::TextInput, "Search apps");
    let buttons: Vec<String> = accessibility_tree(&ui)
        .into_iter()
        .filter(|(r, _)| *r == AccessibleRole::Button)
        .map(|(_, l)| l)
        .collect();
    assert_eq!(buttons, ["Calculator", "Files", "Terminal"]);
}

// The testing backend cannot report focus, so the focused element shows by what Return and
// Space do: a row launches its app, the field launches the best match (Return) or types (Space).
#[test]
fn keyboard_moves_through_the_apps_and_launches() {
    init();
    let (ui, seen) = launcher();
    key(&ui, Key::DownArrow);
    key(&ui, Key::DownArrow);
    key(&ui, Key::Return);
    assert_eq!(seen.launched.get(), 1);
    key(&ui, Key::DownArrow);
    key(&ui, Key::DownArrow); // stays on the last row
    key(&ui, Key::Space);
    assert_eq!(seen.launched.get(), 2);
    key(&ui, Key::UpArrow);
    key(&ui, Key::UpArrow);
    key(&ui, Key::UpArrow); // back in the field
    key(&ui, Key::Space);
    assert_eq!(*seen.searched.borrow(), " ");
    assert_eq!(seen.launched.get(), 2);
    key(&ui, Key::Escape);
    assert!(seen.closed.get());
}

#[test]
fn typing_searches_and_return_starts_the_best_match() {
    init();
    let (ui, seen) = launcher();
    key(&ui, "f");
    key(&ui, "i");
    assert_eq!(*seen.searched.borrow(), "fi");
    assert_eq!(ui.get_query(), "fi");
    key(&ui, Key::Return);
    assert_eq!(seen.launched.get(), 0);
}

#[test]
fn reset_clears_the_search_and_focuses_the_field() {
    init();
    let (ui, seen) = launcher();
    key(&ui, "x");
    key(&ui, Key::DownArrow);
    ui.invoke_reset();
    assert_eq!(ui.get_query(), "");
    key(&ui, Key::Space); // typed into the field, not a row's launch
    assert_eq!(ui.get_query(), " ");
    assert_eq!(seen.launched.get(), -1);
}

#[test]
fn accessible_action_launches_the_app() {
    init();
    let (ui, seen) = launcher();
    find_by_label(&ui, "Terminal")
        .unwrap()
        .invoke_accessible_default_action();
    assert_eq!(seen.launched.get(), 2);
}

#[test]
fn says_when_nothing_matches() {
    init();
    let (ui, _) = launcher();
    ui.set_apps(ModelRc::new(VecModel::from(Vec::new())));
    assert_accessible(&ui, AccessibleRole::Text, "No apps found");
}
