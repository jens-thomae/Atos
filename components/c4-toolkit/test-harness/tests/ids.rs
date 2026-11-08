// A7 (D-006 §3.4, D-011 A7): `accessible-id` reaches the tree, and list and table rows derive theirs.
slint::include_modules!();

use atos_ui_test::{AccessibleRole::*, accessible_ids, init};

fn id(
    role: atos_ui_test::AccessibleRole,
    id: &str,
) -> (atos_ui_test::AccessibleRole, Option<String>) {
    (role, Some(id.into()))
}

#[test]
fn explicit_ids_and_derived_row_ids() {
    init();
    let ids = accessible_ids(&IdsProbe::new().unwrap());
    for want in [
        id(Button, "save"),
        id(TextInput, "name"),
        id(Checkbox, "on"),
        id(Dialog, "dlg"),
        id(List, "list"),
        id(ListItem, "list/item-0"),
        id(ListItem, "list/item-1"),
        id(Table, "files"),
        id(ColumnHeader, "files/column-0"),
        id(ColumnHeader, "files/column-1"),
        id(Row, "files/row-0"),
        id(Row, "files/row-1"),
    ] {
        assert!(ids.contains(&want), "missing {want:?} in {ids:?}");
    }
}

#[test]
fn widgets_without_an_id_publish_none() {
    init();
    let ids = accessible_ids(&IdsProbe::new().unwrap());
    // The second list and table have no id, so neither do their rows (no "/item-0").
    assert!(
        ids.iter()
            .all(|(_, i)| i.as_deref().is_none_or(|i| !i.starts_with('/')))
    );
    assert_eq!(
        ids.iter()
            .filter(|(r, i)| *r == ListItem && i.is_none())
            .count(),
        1
    );
    assert_eq!(
        ids.iter()
            .filter(|(r, i)| matches!(r, Row | ColumnHeader) && i.is_none())
            .count(),
        2
    );
}

#[test]
fn ids_are_unique() {
    init();
    let ids: Vec<_> = accessible_ids(&IdsProbe::new().unwrap())
        .into_iter()
        .filter_map(|(_, i)| i)
        .collect();
    let mut sorted = ids.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(sorted.len(), ids.len(), "duplicate ids in {ids:?}");
}
