// A2 (D-006 §3.4): an in-window dialog can take the dialog role (Dialog windows: see follow-up on #62).
slint::include_modules!();

use atos_ui_test::{AccessibleRole, assert_accessible, init, root_accessibility};

#[test]
fn dialog_role_is_available() {
    init();
    let ui = RolesDialog::new().unwrap();
    assert_accessible(&ui, AccessibleRole::Dialog, "Properties");
}

// A6: a `Dialog` window root has the dialog role by default and an explicit role on a `Window` is kept.
// The winit backend turns it into an AccessKit dialog named by the title (not run in this headless
// harness): see docs/components/c4-toolkit/popups-and-dialogs.md.
#[test]
fn dialog_window_has_dialog_role() {
    init();
    let ui = RolesDialogWindow::new().unwrap();
    assert_eq!(root_accessibility(&ui).0, Some(AccessibleRole::Dialog));
    let ui = RolesWinDlg::new().unwrap();
    assert_eq!(
        root_accessibility(&ui),
        (Some(AccessibleRole::Dialog), "X".into())
    );
}
