# C3 Shell

Requirements: [`docs/spec.md` §6 C3 Shell](../../docs/spec.md#c3-shell). Decision: D-006 (Slint, single-process shell, 300 MB share of idle memory).

`atos-shell` is one process that draws the shell's layer surfaces on every output: the dock-taskbar with the running windows (#63) and the launcher (#64). The control centre (#65) builds on it.

## Layout

| File | What |
| --- | --- |
| `ui/dock.slint` | The dock-taskbar. Token values only (`components/c4-toolkit/ui/tokens.slint`); layout after the owner's Dock mockup on the design canvas |
| `ui/launcher.slint` | The launcher. Token values only; panel, field and rows after the command palette mockup (there is no launcher mockup yet) |
| `src/launcher.rs` | Opens and closes the launcher, the `--launcher` socket, starts the chosen app |
| `src/apps.rs` | Installed apps from desktop entries, `Exec=` parsing, search by name |
| `data/system_actions.ron` | atos-comp's command for its `System(Launcher)` shortcut, for the image to install |
| `src/platform.rs` | Slint platform on wlr-layer-shell: the #59 spike's backend ([layer-shell-spike.md](../../docs/components/c4-toolkit/layer-shell-spike.md)) without its popups, popup pool and timing hooks, plus one layer surface per output, output hotplug, overlay placement and re-showing a hidden window (#64). Replaced by the C4 backend crate (spike section 6, card 1) |
| `src/accesskit.rs` | The spike's AccessKit port (modified copy of a Slint file, GPL-3.0-only, D-013) |
| `src/toplevels.rs` | Running windows: `ext-foreign-toplevel-list-v1` for the list, atos-comp's `zcosmic_toplevel_info_v1` (v2+) for the activated state, `zcosmic_toplevel_manager_v1.activate` on click |
| `src/icons.rs` | App icon from the app ID: `Icon=` of `<app_id>.desktop`, then hicolor and `pixmaps` in the XDG data directories and Flatpak's export directories |
| `tests/` | Screenshot and accessibility-tree tests with the C4 harness ([screenshot-tests.md](../../docs/components/c4-toolkit/screenshot-tests.md)) |
| `e2e/` | End-to-end run on atos-comp (nested in headless sway) and its checks, used by CI |

## Dock-taskbar behaviour (#63)

- One floating bar per output, anchored to the bottom edge with a `Space.s3` gap, `Size.dock-height` high, exclusive zone so windows do not cover it.
- One slot per running window, in opening order. The tile is the app's icon, or its title's first letter on `Palette.button-secondary` when no icon is found.
- A dot under every slot (`Space.s1`, `Palette.text-3`); the focused window's dot is wider (`Space.s4`) and in `Palette.accent`.
- Click, Return or Space on a slot, or the AT-SPI default action, activates the window. Accessible name: `<title>, running` or `<title>, focused`.
- Without atos-comp's protocols (for example in plain sway) the shell runs with an empty dock.

## Launcher behaviour (#64)

- Opens from the dock's first button ("Open launcher") or with `atos-shell --launcher`, which toggles the launcher of the shell on the same Wayland display through `$XDG_RUNTIME_DIR/atos-shell-$WAYLAND_DISPLAY.sock`.
- **Shortcut:** atos-comp's existing `System(Launcher)` action, bound to Super and Super+/ in `components/c2-compositor/data/keybindings.ron`. It runs the command in `system_actions`; `data/system_actions.ron` sets it to `atos-shell --launcher`, and the image installs it as `/usr/share/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions` (#120). atos-comp turns its shortcuts off when started with a kiosk command, so the session must start the shell another way.
- **Rebinding:** add a binding to `~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom` (RON; atos-comp reloads it live), for example `{ (modifiers: [Super], key: "l"): System(Launcher), (modifiers: [Super]): Disable }`.
- A full-output overlay layer surface on the focused output: scrim, centred panel with the search field and the apps. Exclusive keyboard while open. A click on the scrim or Escape closes it.
- **Apps:** desktop entries in `applications/` of `$XDG_DATA_HOME`, Flatpak's user and system export directories and `$XDG_DATA_DIRS`; the first directory with a desktop file ID wins. Left out: `NoDisplay`, `Hidden`, `OnlyShowIn`/`NotShowIn` against `$XDG_CURRENT_DESKTOP`, a missing `TryExec`, `Terminal=true` (no terminal app yet). The list is read at start and again on every opening, off the event loop.
- **Search:** case-insensitive on the name; names that start with the query first, then a word that starts with it, then anywhere.
- **Keyboard:** the field has the focus; Down and Up move the focus through the apps and back to the field (a screen reader reads each app's name), Return or Space starts the focused app, Return in the field starts the first match. Every app is an AT-SPI button whose default action starts it.
- **Opening time:** one launcher window lives all session. Hiding drops its layer surface, and showing creates a new `wl_surface` for the same window (`platform.rs`), so the renderer keeps its caches (glyphs, icon textures, the panel's shadows) and only the first opening pays for them. The shell prints `LAUNCHER_OPEN_MS <ms>` from the trigger to the compositor's frame callback for the first frame; the e2e run checks it against §7's 100 ms on the NUC.

## Build and test

```sh
tools/slint-fork/slint-fork.sh setup     # once
cd components/c3-shell
tools/dev-vm/vm run cargo nextest run --config ../../third_party/slint/patch.toml
tools/dev-vm/vm run env UPDATE_SCREENSHOTS=1 cargo nextest run --config ../../third_party/slint/patch.toml   # rewrite references
```

The crate is outside the root workspace (it builds Slint through the fork), like the test harness. Its CI is [`c3-shell.yml`](../../.github/workflows/c3-shell.yml): lint and tests, then `e2e/run.sh` and `e2e/check.sh` on a hosted runner. The label `c3-nuc` adds the run on the reference NUC on the GPU (§7 numbers: idle RSS and CPU over 5 minutes, launcher opening ≤ 100 ms).

## Licence

Own files MIT OR Apache-2.0; `src/accesskit.rs` GPL-3.0-only. The binary links Slint, so it is GPL-3.0-only (D-013).
