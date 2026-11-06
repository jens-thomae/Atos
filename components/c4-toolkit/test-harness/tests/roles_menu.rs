// A2 (D-006 §3.4): the context-menu popup is a menu with named menu items.
slint::include_modules!();

use atos_ui_test::{AccessibleRole, assert_accessible, elements_with_role, init};

#[test]
fn menu_and_items() {
    init();
    let ui = RolesMenu::new().unwrap();
    ui.invoke_open();
    assert_accessible(&ui, AccessibleRole::MenuItem, "Open");
    assert_accessible(&ui, AccessibleRole::MenuItem, "Copy Path");
    assert_eq!(elements_with_role(&ui, AccessibleRole::Menu).len(), 1);
}
