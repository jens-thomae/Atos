// A5 (D-006 §3.4): virtualised rows report position and size of set, so any row is addressable.
slint::include_modules!();

use atos_ui_test::{AccessibleRole, elements_with_role, init};
use slint::{ModelRc, SharedString, StandardListViewItem, VecModel};

fn check(items: Vec<i_slint_backend_testing::ElementHandle>) {
    assert!(
        !items.is_empty() && items.len() < 1000,
        "list must be virtualised"
    );
    for (i, e) in items.iter().enumerate() {
        assert_eq!(e.accessible_item_index(), Some(i));
        assert_eq!(e.accessible_item_count(), Some(1000));
    }
}

fn item(i: i32) -> StandardListViewItem {
    let mut it = StandardListViewItem::default();
    it.text = SharedString::from(format!("item {i}"));
    it
}

#[test]
fn list_items() {
    init();
    let ui = RolesList::new().unwrap();
    ui.set_items(ModelRc::new(VecModel::from_iter((0..1000).map(item))));
    check(elements_with_role(&ui, AccessibleRole::ListItem));
    let lists = elements_with_role(&ui, AccessibleRole::List);
    assert_eq!(lists[0].accessible_item_count(), Some(1000));
}

#[test]
fn table_rows() {
    init();
    let ui = RolesBigTable::new().unwrap();
    ui.set_data(ModelRc::new(VecModel::from_iter(
        (0..1000).map(|i| ModelRc::new(VecModel::from(vec![item(i)]))),
    )));
    check(elements_with_role(&ui, AccessibleRole::Row));
}
