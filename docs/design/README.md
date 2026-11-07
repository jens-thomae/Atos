# Design tokens

`tokens.json` is the single source of the design values: type, colour (light and dark), accents, overlays, spacing, radii, elevation, materials, motion, focus ring and control sizes. Only the owner approves changes to it (spec §2). Everything else is generated from it.

- **Version:** 0.2
- **Canvas** (the owner's design canvas, read-only for agents): <https://claude.ai/code/artifact/66471479-138a-4e3c-86b8-037c196e3e06>. `project/Tokens.dc.html` is the token sheet; the mockups supply the values that sheet lacks.
- **Fonts:** Inter and JetBrains Mono (both OFL).

## Change a token

1. Edit `docs/design/tokens.json`. Colours are `#rrggbb`, `rgb(r,g,b)` or `rgba(r,g,b,a)`, so values can be pasted from the canvas.
2. Regenerate (one command, from the repository root):

   ```sh
   cargo run -p tokens
   ```

   This rewrites `components/c4-toolkit/ui/tokens.slint`. Commit both files.
3. `cargo run -p tokens -- --check` fails if the generated file is stale or a §7 contrast budget is missed. CI runs the same check through `cargo nextest run` (`tools/tokens`), and a change to `tokens.json` alone always triggers the full build (`tools/ci/is-docs-only.sh`).

## What is generated

`tokens.slint` exports Slint globals: `Fonts`, `Type` (text styles), `Palette`, `Space`, `Radius`, `Size`, `Elevation`, `Motion`. UI code reads only these, never literals. `cargo run -p tokens -- --check` (and a nextest test) fails on a colour, length or duration literal (`#fff`, `rgb(`, `12px`, `200ms`; zero is allowed) in any `.slint` file under `components/`, except the generated file and the test fixtures in `components/c4-toolkit/test-harness/`.

- Theme: set `Palette.dark`. Accent: set `Palette.accent-name` (an `AccentName`). Every colour follows both.
- Elevation levels have two shadow layers (`elevation-2-near`, `elevation-2-far`); draw them as two stacked rectangles, since Slint draws one shadow per element.
- Overlay colours (`line`, `field`, `hover`, `pressed`, `button-secondary*`, `track`) are one warm tint at the alpha in `overlay.alpha`. `select` and `select-outline` are the accent at the alpha in `overlay.accent-alpha`.
- Springs are `response` and `damping`; the animation engine that uses them is a separate card.

## Proposed names

`proposed` in `tokens.json` lists every token whose name or value is not on the token sheet itself (taken from a mockup, or derived). The owner approves or renames them in the PR; the tool fails if a listed path does not exist. Remove an entry once the owner approves it.

## Known contrast misses (owner decision)

The check fails the build for text on the surfaces, status colours on the window, destructive, the frosted panel over every wallpaper stop and the default (blue) accent. It only warns for the values below, which are the canvas's own. Not checked yet: 3:1 for non-text UI (lines, focus ring, toggle track).

- Success and warning text on the sidebar (light): 4.40:1 and 4.49:1.

- Accents other than blue, as text or as a fill under `on-accent`, miss 4.5:1 in one or both themes (in dark they have no lighter variant yet).
- Warning text on the privacy indicator background (light): 4.29:1.
- White glyph on the Files app tile: 2.97:1 (needs 3:1).
- Accent hover and pressed exist only for blue in light; all others are derived (`accent.derive`).

`cargo run -p tokens -- --check` prints the full list.
