// Example test for docs/components/c4-toolkit/screenshot-tests.md.
slint::include_modules!();

use atos_ui_test::{AccessibleRole, assert_accessible, assert_screenshot, init};

#[test]
fn greeting() {
    init();
    let ui = Greeting::new().unwrap();
    assert_accessible(&ui, AccessibleRole::Text, "Greeting");
    assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "greeting");
}
