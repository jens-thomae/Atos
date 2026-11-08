# Popups and dialogs in the accessibility tree (A6)

Card: #95. Decision: D-006 §3.4 (A6), D-007. Patch: `0003-a11y-name-popups-…` in the [Slint queue](README.md#patch-queue).

## What the patch does

Slint's winit backend draws a popup as a child of its window: the popup's item tree is attached under the node of the item that opened it (`AccessiblePopup.parent_node` in `internal/backends/winit/accesskit.rs`). The popup root is a window item, which AccessKit mapped to an unnamed `Role::Window`. Now:

| Item | AccessKit role | Name |
| --- | --- | --- |
| popup root, kind `Menu` (`ContextMenuArea`, menu bars) | `Menu` | `accessible-label` of the root, else its `title` |
| popup root, kind `Popup` (`PopupWindow`) | `Dialog` | same |
| popup root, kind `ToolTip` | `Tooltip` | same |
| root of a `Dialog` window | `Dialog` (the compiler sets `accessible-role: dialog` on `Dialog` unless the app set another) | window title, or `accessible-label` if set |
| root of any other window | `Window`, unchanged | window title |

An app can name a `PopupWindow` with `accessible-label` on it; without a name the node is unnamed, as before, but now typed.

Known duplicate: a `Menu` popup root and the menu frame inside it (`menu-base.slint`, patch 0002) both have the `menu` role, so a context menu shows as a `Menu` inside a `Menu`. Collapse them in a follow-up (drop the role from the frame once the root is always named).

## How far a parent relation across surfaces works under AT-SPI

- **Same surface (what we ship today):** a parent relation exists. The popup is a child node of the opener in the same AccessKit tree, so AT-SPI `GetChildren` / `Parent` already link them. The winit backend never creates a separate popup window: it does not implement `create_child_window_adapter`, so popups are always in-window (`PopupWindowLocation::ChildWindow`).
- **Separate Wayland surface (an `xdg_popup` or layer-shell surface with its own AccessKit adapter):** no parent relation. AccessKit builds one tree per adapter, and the AT-SPI side (`accesskit_atspi_common` 0.19.1, `NodeWrapper::relation_set`) exposes only `ControllerFor`. It has no `PopupFor`, `ParentWindowOf` or `EmbeddedBy`. Such a popup shows up as another window under the application, next to the main window, not under the widget that opened it. A screen reader can still read it (role and name are right), but it cannot follow the popup back to its opener by tree structure.
- **Implications.** C3's layer-shell backend (D-006 §3.4, "Accessibility of shell surfaces") must keep popups inside their parent surface's tree where it can. If a shell popup has to be its own surface, give it a name that includes the opener (for example "Network menu") and accept that focus moves to it by `Focus` events, not by tree structure.

This is from reading the code at the pinned versions. It has **not been run** against a live AT-SPI bus (needs Linux, no GPU or compositor here): the real check belongs to #97 (A8, M6 on AT-SPI).

## Tests

`components/c4-toolkit/test-harness/tests/roles_dialog.rs` checks that a `Dialog` window root and a `Window` with `accessible-role: dialog` expose the dialog role and name through the #60 harness (`root_accessibility`). The harness uses Slint's testing backend, so it does not run `accesskit.rs`: the popup-root mapping in the table above was covered by unit tests of the pure kind → role and name rules in `accesskit.rs` (`cargo test -p i-slint-backend-winit --features accessibility,renderer-software --lib accesskit`, run by the `Slint fork` CI job). Driving the whole AccessKit tree needs a window, so #97 should check it on Linux.
