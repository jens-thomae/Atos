// A2/A3 (D-006 §3.4): StandardTableView publishes column headers and rows with state.
slint::include_modules!();

use atos_ui_test::{AccessibleRole, assert_accessible, elements_with_role, init};

#[test]
fn table_has_column_headers_and_rows() {
    init();
    let ui = RolesTable::new().unwrap();
    assert_accessible(&ui, AccessibleRole::Table, "");
    assert_accessible(&ui, AccessibleRole::ColumnHeader, "Name");
    assert_accessible(&ui, AccessibleRole::ColumnHeader, "Size");
    let rows = elements_with_role(&ui, AccessibleRole::Row);
    let got: Vec<_> = rows
        .iter()
        .map(|r| {
            (
                r.accessible_label().unwrap().to_string(),
                r.accessible_item_selected(),
                r.accessible_item_index(),
            )
        })
        .collect();
    assert_eq!(
        got,
        [
            ("docs".to_string(), Some(false), Some(0)),
            ("notes.txt".to_string(), Some(true), Some(1)),
        ]
    );
}
