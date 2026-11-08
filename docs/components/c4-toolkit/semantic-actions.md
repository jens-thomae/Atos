# Semantic actions per widget (A4)

Card: #93. Decision: D-006 §3.4 (A4), D-007. Patch: `0005-a11y-complete-the-semantic-actions-…` in the [Slint queue](README.md#patch-queue).

## Actions per widget

The winit backend maps AccessKit actions to Slint's `accessible-action-*` callbacks (`internal/backends/winit/accesskit.rs`). A node advertises an action only when it is handled.

| Action | Where it works | Patch change |
| --- | --- | --- |
| `Click` | `Button`, `StandardButton`, `CheckBox`, `Switch`, `RadioButton`, `TabWidget` tabs, list items, table rows, menu items, date and time pickers, `ComboBox` | `ComboBox` opens its popup, as `Expand` does |
| `Focus` | every focusable role | added `Switch` and `RadioButton` |
| `SetValue` | `LineEdit`, `TextEdit`, `SpinBox`, `Slider` | none. `ComboBox` is not covered: Slint code cannot search a model by value (follow-up) |
| `Increment`, `Decrement` | `Slider`, `SpinBox` | none |
| `Expand` | `ComboBox` | none |
| `SetTextSelection` | `LineEdit`, `TextEdit`, `SpinBox` | none (from upstream) |
| `ReplaceSelectedText` | `LineEdit`, `TextEdit` (fluent, cosmic, cupertino, material) | new `accessible-action-replace-selected-text` callback and `TextInput.replace-selected-text()`. Replaces the selection, inserts at the cursor without one, deletes on empty text, ignores read-only inputs |
| `ScrollIntoView` | every node inside a `Flickable` (`ScrollView`, `ListView`, tables) | scrolls all enclosing flickables (`ItemRc::try_scroll_into_visible`, now public) |
| `ShowContextMenu` | every node inside an enabled `ContextMenuArea` (including the built-in text menus) | opens the menu at the centre of the node |

The native Qt style is not patched, as in patch 0002.

## Tests

`components/c4-toolkit/test-harness/tests/actions.rs` (#60 harness). The testing backend gained `accessible_actions()`, `replace_accessible_selected_text`, `invoke_accessible_scroll_into_view` and `invoke_accessible_show_context_menu`, which call the same core helpers as the winit backend. The AccessKit mapping itself (action to callback) is not run headless; #97 (A8) checks it on AT-SPI. The harness skips items outside the visible area, so the scroll test uses a button that is half visible.
