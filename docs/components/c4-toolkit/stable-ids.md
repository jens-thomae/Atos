# Stable element IDs (A7)

Card: #96. Decision: D-006 §3.4 (A7), D-011 A7. Patch: `0005-a11y-derive-row-ids-…` in the [Slint queue](README.md#patch-queue).

## Does AT-SPI get it? Yes, no fix needed

Slint's winit backend sets AccessKit `author_id` from `accessible-id` on every node (`accesskit.rs`, `build_node_without_children`). At the pinned versions, `accesskit_atspi_common` 0.19.1 (`node.rs`, `accessible_id`) returns `author_id` and `accesskit_unix` 0.22.1 exposes it as the `AccessibleId` property of `org.a11y.atspi.Accessible`. Read from the code, **not run** against a live AT-SPI bus (no Linux here): #97 (A8) should check it.

## Convention

An `accessible-id` is a constant, unique per window, stable across restarts. Set it on every control an assistant must name (this is a rule for app and shell code; the compiler does not enforce it). It needs an `accessible-role` on the element, which every standard widget has.

## What the patch adds

Rows are instantiated by the widget, so an app cannot name them. If the list or table has an `accessible-id`, its parts derive one:

| Part | ID |
| --- | --- |
| `StandardListView` item *n* | `<id>/item-<n>` |
| `StandardTableView` row *n* | `<id>/row-<n>` |
| `StandardTableView` column header *n* | `<id>/column-<n>` |

Without an id on the widget the parts have none (an empty id is not published). Indices are model positions, so they are stable for the same model; they follow a sorted or reordered model.

Not covered: menu items, tabs, combo box entries (no id), and unnamed elements in general. Giving every control a default id from its place in the source needs compile-time paths that stay unique across component instances and repeaters; proposed as a follow-up if wanted.

## Tests

`components/c4-toolkit/test-harness/tests/ids.rs` (harness helper `accessible_ids`): explicit ids on a button, line edit, checkbox, list, table and dialog; derived row, item and header ids; no ids without a parent id; uniqueness. The testing backend reads `accessible-id` directly, so the `author_id` hop is the code reading above, not a test.
