// One screenshot (light and dark) and one role/name assertion per shared widget
// (components/c4-toolkit/ui/widgets/, documented in docs/components/c4-toolkit/widgets.md).
slint::include_modules!();

use atos_ui_test::{AccessibleRole, assert_accessible, assert_screenshot, init};

macro_rules! widget_test {
    ($test:ident, $probe:ident, $role:ident, $label:expr, $shot:expr) => {
        #[test]
        fn $test() {
            init();
            let ui = $probe::new().unwrap();
            assert_accessible(&ui, AccessibleRole::$role, $label);
            assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), $shot);
            ui.set_dark(true);
            assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), concat!($shot, "-dark"));
        }
    };
}

widget_test!(
    action_row,
    ProbeActionRow,
    Button,
    "Restart",
    "widget-action-row"
);
widget_test!(button, ProbeButton, Button, "Cancel", "widget-button");
widget_test!(
    chip,
    ProbeChip,
    Text,
    "Microphone · Meetings",
    "widget-chip"
);
widget_test!(
    focus_ring,
    ProbeFocusRing,
    Button,
    "Ringed",
    "widget-focus-ring"
);
widget_test!(glyph, ProbeGlyph, Button, "Glyph host", "widget-glyph");
widget_test!(
    icon_button,
    ProbeIconButton,
    Button,
    "Settings",
    "widget-icon-button"
);
widget_test!(icon_row, ProbeIconRow, Button, "Files", "widget-icon-row");
widget_test!(panel, ProbePanel, Button, "Panel host", "widget-panel");
widget_test!(
    radio_row,
    ProbeRadioRow,
    RadioButton,
    "Desk speakers, Built-in",
    "widget-radio-row"
);
widget_test!(
    search_field,
    ProbeSearchField,
    TextInput,
    "Search apps",
    "widget-search-field"
);
widget_test!(slider, ProbeSlider, Slider, "Volume", "widget-slider");
widget_test!(
    toggle_tile,
    ProbeToggleTile,
    Button,
    "Wi-Fi, Home-5G",
    "widget-toggle-tile"
);
