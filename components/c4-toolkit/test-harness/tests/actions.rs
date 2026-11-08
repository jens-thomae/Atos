// A4 (D-006 §3.4): every widget exposes the actions an assistant needs.
slint::include_modules!();

use atos_ui_test::{AccessibleRole, elements_with_role, find_by_label, init};

fn actions(ui: &impl slint::ComponentHandle, label: &str) -> Vec<&'static str> {
    find_by_label(ui, label)
        .unwrap_or_else(|| panic!("no element named {label:?}"))
        .accessible_actions()
}

#[test]
fn widgets_expose_their_actions() {
    init();
    let ui = ActionsWidgets::new().unwrap();
    for a in ["SetValue", "ReplaceSelectedText", "SetTextSelection"] {
        assert!(actions(&ui, "Name").contains(&a), "LineEdit lacks {a}");
    }
    assert!(actions(&ui, "Go").contains(&"Click"));
    assert!(actions(&ui, "Check").contains(&"Click"));
    assert!(actions(&ui, "Wifi").contains(&"Click"));
    let combo = actions(&ui, "Mode");
    assert!(
        combo.contains(&"Click") && combo.contains(&"Expand"),
        "{combo:?}"
    );
}

#[test]
fn replace_selected_text() {
    init();
    let ui = ActionsWidgets::new().unwrap();
    let name = find_by_label(&ui, "Name").unwrap();
    name.set_accessible_selection_offsets(0, 5);
    name.replace_accessible_selected_text("bye");
    assert_eq!(ui.get_name(), "bye world");
    // No selection: inserts at the cursor, which the replacement left after "bye".
    name.replace_accessible_selected_text("!");
    assert_eq!(ui.get_name(), "bye! world");
    // An empty replacement deletes the selection.
    name.set_accessible_selection_offsets(0, 4);
    name.replace_accessible_selected_text("");
    assert_eq!(ui.get_name(), " world");
}

#[test]
fn read_only_text_is_not_replaced() {
    init();
    let ui = ActionsWidgets::new().unwrap();
    ui.set_locked(true);
    let locked = find_by_label(&ui, "Locked").unwrap();
    locked.set_accessible_selection_offsets(0, 5);
    locked.replace_accessible_selected_text("x");
    assert_eq!(locked.accessible_value().unwrap(), "fixed");
}

#[test]
fn scroll_into_view() {
    init();
    let ui = ActionsScroll::new().unwrap();
    let far = find_by_label(&ui, "Far").unwrap();
    assert!(far.accessible_actions().contains(&"ScrollIntoView"));
    assert!(
        !find_by_label(&ui, "Outside")
            .unwrap()
            .accessible_actions()
            .contains(&"ScrollIntoView")
    );
    assert_eq!(ui.get_scrolled(), 0.0);
    far.invoke_accessible_scroll_into_view();
    assert!(
        ui.get_scrolled() == -10.0,
        "content-y is {}",
        ui.get_scrolled()
    );
}

#[test]
fn show_context_menu() {
    init();
    let ui = ActionsScroll::new().unwrap();
    let far = find_by_label(&ui, "Far").unwrap();
    assert!(far.accessible_actions().contains(&"ShowContextMenu"));
    let outside = find_by_label(&ui, "Outside").unwrap();
    assert!(!outside.accessible_actions().contains(&"ShowContextMenu"));
    assert!(!outside.invoke_accessible_show_context_menu());
    assert!(elements_with_role(&ui, AccessibleRole::Menu).is_empty());
    assert!(far.invoke_accessible_show_context_menu());
    assert_eq!(elements_with_role(&ui, AccessibleRole::Menu).len(), 1);
}
