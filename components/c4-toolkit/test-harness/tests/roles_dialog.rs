// A2 (D-006 §3.4): an in-window dialog can take the dialog role (Dialog windows: see follow-up on #62).
slint::include_modules!();

use atos_ui_test::{AccessibleRole, assert_accessible, init};

#[test]
fn dialog_role_is_available() {
    init();
    let ui = RolesDialog::new().unwrap();
    assert_accessible(&ui, AccessibleRole::Dialog, "Properties");
}
