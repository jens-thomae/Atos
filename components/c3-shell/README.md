# C3 Shell

Requirements: [`docs/spec.md` §6 C3 Shell](../../docs/spec.md#c3-shell). Decision: D-006 (Slint, single-process shell, 300 MB share of idle memory).

`atos-shell` is one process that draws the shell's layer surfaces on every output. Today (#63) that is the dock-taskbar with the running windows; the launcher (#64) and control centre (#65) build on it.

## Layout

| File | What |
| --- | --- |
| `ui/dock.slint` | The dock-taskbar. Token values only (`components/c4-toolkit/ui/tokens.slint`); layout after the owner's Dock mockup on the design canvas |
| `src/platform.rs` | Slint platform on wlr-layer-shell: the #59 spike's backend ([layer-shell-spike.md](../../docs/components/c4-toolkit/layer-shell-spike.md)) without its popups, popup pool and timing hooks, plus one layer surface per output and output hotplug. Replaced by the C4 backend crate (spike section 6, card 1) |
| `src/accesskit.rs` | The spike's AccessKit port (modified copy of a Slint file, GPL-3.0-only, D-013) |
| `src/toplevels.rs` | Running windows: `ext-foreign-toplevel-list-v1` for the list, atos-comp's `zcosmic_toplevel_info_v1` (v2+) for the activated state, `zcosmic_toplevel_manager_v1.activate` on click |
| `src/icons.rs` | App icon from the app ID: `Icon=` of `<app_id>.desktop`, then hicolor and `pixmaps` in the XDG data directories |
| `tests/` | Screenshot and accessibility-tree tests with the C4 harness ([screenshot-tests.md](../../docs/components/c4-toolkit/screenshot-tests.md)) |
| `e2e/` | End-to-end run on atos-comp (nested in headless sway) and its checks, used by CI |

## Dock-taskbar behaviour (#63)

- One floating bar per output, anchored to the bottom edge with a `Space.s3` gap, `Size.dock-height` high, exclusive zone so windows do not cover it.
- One slot per running window, in opening order. The tile is the app's icon, or its title's first letter on `Palette.button-secondary` when no icon is found.
- A dot under every slot (`Space.s1`, `Palette.text-3`); the focused window's dot is wider (`Space.s4`) and in `Palette.accent`.
- Click, Return or Space on a slot, or the AT-SPI default action, activates the window. Accessible name: `<title>, running` or `<title>, focused`.
- Without atos-comp's protocols (for example in plain sway) the shell runs with an empty dock.

## Build and test

```sh
tools/slint-fork/slint-fork.sh setup     # once
cd components/c3-shell
tools/dev-vm/vm run cargo nextest run --config ../../third_party/slint/patch.toml
tools/dev-vm/vm run env UPDATE_SCREENSHOTS=1 cargo nextest run --config ../../third_party/slint/patch.toml   # rewrite references
```

The crate is outside the root workspace (it builds Slint through the fork), like the test harness. Its CI is [`c3-shell.yml`](../../.github/workflows/c3-shell.yml): lint and tests, then `e2e/run.sh` and `e2e/check.sh` on a hosted runner. The label `c3-nuc` adds the run on the reference NUC on the GPU (§7 numbers: idle RSS and CPU over 5 minutes).

## Licence

Own files MIT OR Apache-2.0; `src/accesskit.rs` GPL-3.0-only. The binary links Slint, so it is GPL-3.0-only (D-013).
