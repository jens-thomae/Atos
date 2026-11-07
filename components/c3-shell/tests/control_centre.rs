// SPDX-License-Identifier: MIT OR Apache-2.0
//! The control centre renders from the tokens, exposes every control on the accessibility tree
//! with a name and state, and reports what the user does (#65).

use std::cell::RefCell;
use std::rc::Rc;

use atos_shell::control::{Quick, Radio, tiles};
use atos_shell::{ControlCentre, OutputItem, PowerAction};
use atos_ui_test::{
    AccessibleRole, accessibility_tree, assert_accessible, assert_screenshot, find_by_label, init,
};
use slint::platform::{Key, WindowEvent};
use slint::{ComponentHandle, LogicalSize, ModelRc, VecModel};

mod test_font {
    include!(concat!(env!("OUT_DIR"), "/cc_test_font.rs"));
}

type Log = Rc<RefCell<Vec<String>>>;

fn panel() -> (ControlCentre, Log) {
    init();
    // Creating it registers the bundled font for the whole process.
    let _font = test_font::FontLoader::new().unwrap();
    let ui = ControlCentre::new().unwrap();
    ui.set_font_family("Noto Sans".into());
    ui.window().set_size(LogicalSize::new(364., 520.));
    let q = Quick {
        wifi: Some(Radio {
            on: true,
            detail: "Home-5G".into(),
        }),
        bluetooth: Some(Radio {
            on: true,
            detail: "Headphones".into(),
        }),
        dark_mode: false,
        do_not_disturb: false,
        profile: Some("balanced".into()),
    };
    ui.set_tiles(ModelRc::new(VecModel::from(tiles(&q))));
    ui.set_privacy("Microphone · Meetings".into());
    ui.set_brightness_available(true);
    ui.set_brightness(0.7);
    ui.set_volume_available(true);
    ui.set_volume(0.6);
    ui.set_outputs_open(true);
    ui.set_outputs(ModelRc::new(VecModel::from(vec![
        OutputItem {
            id: 1,
            name: "Desk speakers".into(),
            detail: "".into(),
            selected: true,
        },
        OutputItem {
            id: 2,
            name: "Headphones".into(),
            detail: "Bluetooth".into(),
            selected: false,
        },
        OutputItem {
            id: 3,
            name: "External display".into(),
            detail: "HDMI".into(),
            selected: false,
        },
    ])));
    ui.set_power_actions(ModelRc::new(VecModel::from(vec![
        PowerAction {
            id: "suspend".into(),
            name: "Suspend".into(),
        },
        PowerAction {
            id: "reboot".into(),
            name: "Restart".into(),
        },
        PowerAction {
            id: "poweroff".into(),
            name: "Shut down".into(),
        },
    ])));
    let log: Log = Rc::default();
    let l = log.clone();
    ui.on_tile_clicked(move |id| l.borrow_mut().push(format!("tile {id}")));
    let l = log.clone();
    ui.on_open_settings(move || l.borrow_mut().push("settings".into()));
    let l = log.clone();
    ui.on_power_action(move |id| l.borrow_mut().push(format!("power {id}")));
    let l = log.clone();
    ui.on_select_output(move |id| l.borrow_mut().push(format!("output {id}")));
    let l = log.clone();
    ui.on_volume_changed(move |v| l.borrow_mut().push(format!("volume {v:.2}")));
    let l = log.clone();
    ui.on_dismiss(move || l.borrow_mut().push("dismiss".into()));
    (ui, log)
}

#[test]
fn renders_the_agreed_contents() {
    let (ui, _) = panel();
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "control-centre");
}

#[test]
fn renders_with_the_power_menu_and_dark_mode() {
    let (ui, _) = panel();
    ui.global::<atos_shell::Palette>().set_dark(true);
    ui.set_privacy("".into());
    ui.set_outputs_open(false);
    ui.set_power_open(true);
    ui.window().set_size(LogicalSize::new(364., 400.));
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "control-centre-dark-power");
}

#[test]
fn every_control_has_a_name_and_a_role() {
    let (ui, _) = panel();
    let tree = accessibility_tree(&ui);
    let has = |role, label: &str| tree.iter().any(|(r, l)| *r == role && l == label);
    for l in [
        "Wi-Fi, Home-5G",
        "Bluetooth, Headphones",
        "Do not disturb, Off",
        "Dark mode, Off",
        "Power, Balanced",
        "Record screen, Not available yet",
        "Open Settings",
        "Power options",
        "Hide sound outputs",
    ] {
        assert!(
            has(AccessibleRole::Button, l),
            "missing button {l:?} in {tree:?}"
        );
    }
    assert!(has(AccessibleRole::Slider, "Brightness"));
    assert!(has(AccessibleRole::Slider, "Volume"));
    assert!(has(AccessibleRole::RadioButton, "Desk speakers"));
    assert!(has(AccessibleRole::RadioButton, "Headphones, Bluetooth"));
    assert!(has(AccessibleRole::Text, "Microphone · Meetings"));
}

#[test]
fn tiles_expose_their_state_and_record_is_disabled() {
    let (ui, log) = panel();
    let wifi = find_by_label(&ui, "Wi-Fi, Home-5G").unwrap();
    assert_eq!(wifi.accessible_checked(), Some(true));
    assert_eq!(
        find_by_label(&ui, "Dark mode, Off")
            .unwrap()
            .accessible_checked(),
        Some(false)
    );
    let rec = find_by_label(&ui, "Record screen, Not available yet").unwrap();
    assert_eq!(rec.accessible_enabled(), Some(false));
    rec.invoke_accessible_default_action();
    assert!(log.borrow().is_empty());
}

#[test]
fn accessible_actions_report_to_the_shell() {
    let (ui, log) = panel();
    find_by_label(&ui, "Wi-Fi, Home-5G")
        .unwrap()
        .invoke_accessible_default_action();
    find_by_label(&ui, "Open Settings")
        .unwrap()
        .invoke_accessible_default_action();
    find_by_label(&ui, "Headphones, Bluetooth")
        .unwrap()
        .invoke_accessible_default_action();
    let v = find_by_label(&ui, "Volume").unwrap();
    v.set_accessible_value("30");
    assert_eq!(
        *log.borrow(),
        ["tile wifi", "settings", "output 2", "volume 0.30"]
    );
    assert!((ui.get_volume() - 0.3).abs() < 1e-6);
}

#[test]
fn power_options_open_a_menu_of_three_actions() {
    let (ui, log) = panel();
    assert!(find_by_label(&ui, "Shut down").is_none());
    find_by_label(&ui, "Power options")
        .unwrap()
        .invoke_accessible_default_action();
    assert!(ui.get_power_open());
    assert_accessible(&ui, AccessibleRole::Button, "Suspend");
    assert_accessible(&ui, AccessibleRole::Button, "Restart");
    find_by_label(&ui, "Shut down")
        .unwrap()
        .invoke_accessible_default_action();
    assert_eq!(*log.borrow(), ["power poweroff"]);
}

#[test]
fn escape_dismisses() {
    let (ui, log) = panel();
    ui.show().unwrap();
    let w = ui.window();
    let press = |k: Key| {
        let t: slint::SharedString = k.into();
        w.dispatch_event(WindowEvent::KeyPressed { text: t.clone() });
        w.dispatch_event(WindowEvent::KeyReleased { text: t });
    };
    press(Key::Escape);
    assert_eq!(log.borrow().last().map(String::as_str), Some("dismiss"));
}

#[test]
fn a_missing_privacy_source_hides_the_chip() {
    let (ui, _) = panel();
    ui.set_privacy("".into());
    assert!(
        !accessibility_tree(&ui)
            .iter()
            .any(|(r, _)| *r == AccessibleRole::Text)
    );
}
