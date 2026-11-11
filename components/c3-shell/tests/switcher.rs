// SPDX-License-Identifier: MIT OR Apache-2.0
//! The window switcher renders from the tokens in both themes, names every tile on the
//! accessibility tree and reports clicks and keys (#226). Fixture icons: tests/icons/.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use atos_shell::{Palette, Switcher, switcher_item};
use atos_ui_test::{AccessibleRole, accessibility_tree, assert_screenshot, find_by_label, init};
use slint::platform::{Key, WindowEvent};
use slint::{
    ComponentHandle, Image, LogicalSize, ModelRc, Rgba8Pixel, SharedPixelBuffer, VecModel,
};

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

/// A fixed stand-in for a captured window (#266): a title bar, a sidebar and text lines in
/// `tint`, at a window's aspect ratio. Test content, not UI colours.
fn window_picture(tint: [u8; 3]) -> Image {
    let (w, h) = (336, 240);
    let mut buf = SharedPixelBuffer::<Rgba8Pixel>::new(w, h);
    for (i, p) in buf.make_mut_slice().iter_mut().enumerate() {
        let (x, y) = (i as u32 % w, i as u32 / w);
        let c = if y < 24 {
            [tint[0] / 2, tint[1] / 2, tint[2] / 2]
        } else if x < 72 {
            [230, 230, 235]
        } else if y % 20 < 8 && x < 96 + (y * 7 % 180) {
            tint
        } else {
            [250, 250, 250]
        };
        *p = Rgba8Pixel {
            r: c[0],
            g: c[1],
            b: c[2],
            a: 255,
        };
    }
    Image::from_rgba8(buf)
}

/// The tiles with previews: a stacked app, two single windows and one not captured.
fn with_previews(ui: &Switcher) {
    ui.set_items(ModelRc::new(VecModel::from(vec![
        switcher_item(
            "Design",
            "Files",
            2,
            icon("square.svg"),
            window_picture([40, 110, 220]),
        ),
        switcher_item(
            "release-notes.md",
            "Text Editor",
            1,
            icon("circle.svg"),
            window_picture([200, 90, 40]),
        ),
        switcher_item(
            "Window modes and how they behave when tiled",
            "Web",
            1,
            icon("circle.svg"),
            Image::default(),
        ),
        switcher_item(
            "~/src/shell",
            "Terminal",
            1,
            Image::default(),
            window_picture([30, 30, 30]),
        ),
    ])));
}

fn switcher() -> Switcher {
    let ui = Switcher::new().unwrap();
    ui.window().set_size(LogicalSize::new(1000., 400.));
    let item = |t, a, n, i: Image| switcher_item(t, a, n, i, Image::default());
    ui.set_items(ModelRc::new(VecModel::from(vec![
        item("Design", "Files", 2, icon("square.svg")),
        item("release-notes.md", "Text Editor", 1, icon("circle.svg")),
        item(
            "Window modes and how they behave when tiled",
            "Web",
            1,
            icon("circle.svg"),
        ),
        item("~/src/shell", "Terminal", 1, Image::default()),
    ])));
    ui.set_selected(1);
    ui.show().unwrap();
    ui
}

fn shot(dark: bool, name: &str, previews: bool) {
    init();
    // Creating it registers the bundled font for the whole process.
    let _font = test_font::FontLoader::new().unwrap();
    let ui = switcher();
    if previews {
        with_previews(&ui);
    }
    ui.set_font_family("Noto Sans".into());
    ui.global::<Palette>().set_dark(dark);
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), name);
}

#[test]
fn renders_light() {
    shot(false, "switcher", false);
}

#[test]
fn renders_dark() {
    shot(true, "switcher-dark", false);
}

#[test]
fn renders_previews_light() {
    shot(false, "switcher-previews", true);
}

#[test]
fn renders_previews_dark() {
    shot(true, "switcher-previews-dark", true);
}

#[test]
fn previews_leave_the_tile_names_unchanged() {
    init();
    let ui = switcher();
    let names = |ui: &Switcher| -> Vec<String> {
        accessibility_tree(ui)
            .into_iter()
            .filter(|(r, _)| *r == AccessibleRole::ListItem)
            .map(|(_, l)| l)
            .collect()
    };
    let before = names(&ui);
    with_previews(&ui);
    assert_eq!(names(&ui), before);
}

#[test]
fn names_every_tile_with_its_windows() {
    init();
    let ui = switcher();
    let tiles: Vec<String> = accessibility_tree(&ui)
        .into_iter()
        .filter(|(r, _)| *r == AccessibleRole::ListItem)
        .map(|(_, l)| l)
        .collect();
    assert_eq!(
        tiles,
        [
            "Design, Files, 2 windows",
            "release-notes.md, Text Editor",
            "Window modes and how they behave when tiled, Web",
            "~/src/shell, Terminal",
        ]
    );
    assert!(find_by_label(&ui, "Open windows").is_some());
    // The key hints are exposed, and the focused element's label follows the selection.
    assert!(
        find_by_label(
            &ui,
            "Alt Tab next, Shift back, backtick same app, W close window, Escape cancel"
        )
        .is_some()
    );
    assert!(
        find_by_label(
            &ui,
            "Window switcher, selected: release-notes.md, Text Editor"
        )
        .is_some()
    );
    ui.set_selected(3);
    assert!(find_by_label(&ui, "Window switcher, selected: ~/src/shell, Terminal").is_some());
}

#[test]
fn keys_and_clicks_reach_the_shell() {
    init();
    let ui = switcher();
    let seen = Rc::new(RefCell::new(Vec::<String>::new()));
    let picked = Rc::new(Cell::new(-1));
    for (name, reg) in [
        ("cancel", 0),
        ("same-app", 1),
        ("close-window", 2),
        ("confirm", 3),
    ] {
        let s = seen.clone();
        let f = move || s.borrow_mut().push(name.into());
        match reg {
            0 => ui.on_cancel(f),
            1 => ui.on_same_app(f),
            2 => ui.on_close_window(f),
            _ => ui.on_confirm(f),
        }
    }
    let s = seen.clone();
    ui.on_move(move |d| s.borrow_mut().push(format!("move {d}")));
    let p = picked.clone();
    ui.on_pick(move |i| p.set(i));
    for k in ["`", "w", "W", "\u{1b}", "\n"] {
        ui.window()
            .dispatch_event(WindowEvent::KeyPressed { text: k.into() });
        ui.window()
            .dispatch_event(WindowEvent::KeyReleased { text: k.into() });
    }
    for k in [Key::LeftArrow, Key::RightArrow] {
        ui.window()
            .dispatch_event(WindowEvent::KeyPressed { text: k.into() });
        ui.window()
            .dispatch_event(WindowEvent::KeyReleased { text: k.into() });
    }
    assert_eq!(
        *seen.borrow(),
        [
            "same-app",
            "close-window",
            "close-window",
            "cancel",
            "confirm",
            "move -1",
            "move 1"
        ]
    );
    find_by_label(&ui, "~/src/shell, Terminal")
        .unwrap()
        .invoke_accessible_default_action();
    assert_eq!(picked.get(), 3);
}
