# Shared widgets

Card: #197. Files: [`components/c4-toolkit/ui/widgets/`](../../../components/c4-toolkit/ui/widgets), one per widget, all exported from [`ui/widgets.slint`](../../../components/c4-toolkit/ui/widgets.slint).

A control that two screens draw lives here once. The shell imports it (`import { Button } from "../../c4-toolkit/ui/widgets.slint";`); it keeps only layout and shell-specific parts. Rules for agents:

- Change a control's look **here**, never in a copy in a shell or app file. To draw a control a little differently, add a property; do not fork it.
- Values come only from `tokens.slint`. Every widget follows the light/dark switch (`Palette.dark`).
- Each widget has a screenshot (light and dark) and a role/name assertion in [`test-harness/tests/widgets.rs`](../../../components/c4-toolkit/test-harness/tests/widgets.rs), with the probe window in `tests/ui/widgets.slint`. Add both for a new widget; the shell's own screenshots must not change.
- Buttons, rows and tiles activate on click, Return, Space and the accessibility default action, and draw a focus ring for keyboard focus only.
- Text and glyphs inside a widget are `accessible-role: none`; the widget's own element carries the name.

## Action row (`ActionRow`)
Full-width row with one label that runs an action (power options). Properties: `label`. Callback: `clicked()`. Role: button, name `label`.

## Button (`Button`)
Text button, 32 px (`Size.control`). Properties: `label`, `primary` (accent fill), `destructive` (with `primary`: destructive fill and ink), `autofocus` (takes focus when created). Callback: `clicked()`. Role: button, name `label`.

## Chip (`Chip`)
Pill with one line of text (privacy chip). Properties: `label`. Role: text, name `label`. It sizes itself to the text; the parent places it.

## Focus ring (`FocusRing`)
Outline over its parent. Properties: `active`, `radius` (the parent's `border-radius`), `ring` (brush, default `Palette.accent`). Put it as the parent's last child. No accessible role.

## Glyph (`Glyph`)
Line icon from SVG path data on a 24 x 24 grid. Properties: `data`, `color` (default `Palette.text-2`). No accessible role.

## Icon button (`IconButton`)
Square button with a glyph. Properties: `glyph`, `label`, `expandable`, `expanded` (disclosure state for screen readers), `filled` (secondary fill at rest and `Palette.text` glyph, as in the dock; otherwise fill on hover and press only), `radius` (default `Radius.control`), plus `width`/`height` (default `Size.control`). Callback: `clicked()`. Role: button, name `label`.

## Icon row (`IconRow`)
List row with an icon tile and a name (launcher apps). Properties: `label`, `icon` (image; empty shows `initial`), `initial`, `current` (takes keyboard focus when it becomes true). Callbacks: `clicked()`, `focused()` (the row got focus). Role: button, name `label`.

## Panel (`Panel`)
Frosted surface: `Palette.panel`, `Radius.overlay`, hairline `Palette.panel-line`. Override `background`, `border-radius`, `border-color` for a variant (launcher: `Radius.dialog`; notice: `Palette.overlay-card`). No accessible role.

## Radio row (`RadioRow`)
Selectable row with a name and a right-aligned detail, one of a group (sound outputs). Properties: `name`, `detail`, `selected`. Callback: `clicked()`. Role: radio button, checked = `selected`, name `name` or `name, detail`.

## Search field (`SearchField`)
Magnifier, text input and placeholder in a 64 px row (launcher). Properties: `label` (accessible name and placeholder), `text` (in-out), `has-focus` (out). Callbacks: `edited(string)`, `accepted()`. Function: `focus-input()`. `preferred-height` is the content height, not 64 px. Role: text input, name `label`.

## Slider (`Slider`)
Horizontal 0 to 1 slider with a leading glyph (brightness, volume). Properties: `label`, `glyph`, `enabled` (default true), `value` (in-out). Callback: `changed(float)`, fired for changes by the user (pointer, arrows, accessibility actions) in steps of 5 %. Role: slider, value in percent.

## Toggle tile (`ToggleTile`)
Two-line tile with a glyph (quick settings). Properties: `name`, `state`, `glyph`, `on` (accent fill, checked), `enabled` (default true; disabled is dimmed and ignores input). Callback: `clicked()`. Role: button, checkable, name `name, state`.

## What stayed in the shell

| Control | Where | Why |
| --- | --- | --- |
| `Slot` | `dock.slint` | A running window: needs `DockItem`, the dock's tile and dot tokens and a custom focus ring geometry; no other screen has one |
| `LauncherButton` | `dock.slint` | Its four-square glyph is drawn from rectangles, and it takes no keyboard focus today. Making it an `IconButton` would add a focus stop (an accessibility change), so it stays until the owner decides |
| Window scrim (`background: Palette.scrim`) | `launcher.slint` | One token on the window, not a control |
| Dividers, group surface, confirmation text | `dock.slint`, `control-centre.slint`, `launcher.slint` | One-line rectangles or text with no behaviour; a widget would add a name, not remove code |
| Panel shadows | `launcher.slint` | Elevation 3 draws two shadows through a sibling rectangle; not shared yet |
