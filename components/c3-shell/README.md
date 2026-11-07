# C3 Shell

Requirements: [`docs/spec.md` §6 C3 Shell](../../docs/spec.md#c3-shell). Decision: D-006 (Slint, single-process shell, 300 MB share of idle memory).

`atos-shell` is one process that draws the shell's layer surfaces on every output. Today (#63) that is the dock-taskbar with the running windows; the control centre (#65) is the second window, and the launcher (#64) builds on it too.

## Layout

| File | What |
| --- | --- |
| `ui/dock.slint` | The dock-taskbar. Token values only (`components/c4-toolkit/ui/tokens.slint`); layout after the owner's Dock mockup on the design canvas |
| `src/platform.rs` | Slint platform on wlr-layer-shell: the #59 spike's backend ([layer-shell-spike.md](../../docs/components/c4-toolkit/layer-shell-spike.md)) without its popups, popup pool and timing hooks, plus one layer surface per output and output hotplug. Replaced by the C4 backend crate (spike section 6, card 1) |
| `src/accesskit.rs` | The spike's AccessKit port (modified copy of a Slint file, GPL-3.0-only, D-013) |
| `src/toplevels.rs` | Running windows: `ext-foreign-toplevel-list-v1` for the list, atos-comp's `zcosmic_toplevel_info_v1` (v2+) for the activated state, `zcosmic_toplevel_manager_v1.activate` on click |
| `src/icons.rs` | App icon from the app ID: `Icon=` of `<app_id>.desktop`, then hicolor and `pixmaps` in the XDG data directories |
| `ui/control-centre.slint` | The control centre panel, after the owner's Control centre mockup; `ui/shell.slint` is the one file `build.rs` compiles (dock and control centre) |
| `src/control_centre.rs` | Opens, closes and feeds the panel; Settings launch by desktop-entry id |
| `src/services.rs`, `src/audio.rs` | D-Bus services (NetworkManager, BlueZ, power-profiles-daemon, logind) and the PipeWire client |
| `src/control.rs`, `src/config.rs` | The six tiles as data; the shell config file (D-010 TOML) |
| `tests/` | Screenshot and accessibility-tree tests with the C4 harness ([screenshot-tests.md](../../docs/components/c4-toolkit/screenshot-tests.md)) |
| `e2e/` | End-to-end run on atos-comp (nested in headless sway) and its checks, used by CI |

## Dock-taskbar behaviour (#63)

- One floating bar per output, anchored to the bottom edge with a `Space.s3` gap, `Size.dock-height` high, exclusive zone so windows do not cover it.
- One slot per running window, in opening order. The tile is the app's icon, or its title's first letter on `Palette.button-secondary` when no icon is found.
- A dot under every slot (`Space.s1`, `Palette.text-3`); the focused window's dot is wider (`Space.s4`) and in `Palette.accent`.
- Click, Return or Space on a slot, or the AT-SPI default action, activates the window. Accessible name: `<title>, running` or `<title>, focused`.
- Without atos-comp's protocols (for example in plain sway) the shell runs with an empty dock.

## Control centre behaviour (#65)

Contents agreed with the owner on the card. Opened by the dock's rightmost button (accessible name "Control centre"); the same button, Escape, Settings or a power action close it. It is an overlay-layer surface at the bottom right, above the dock, taking the keyboard while open.

| Item | Source |
| --- | --- |
| Wi-Fi tile | NetworkManager, `WirelessEnabled`; subtitle is the first Wi-Fi device's active connection |
| Bluetooth tile | BlueZ, first adapter's `Powered`; subtitle is a connected device |
| Power tile | power-profiles-daemon `ActiveProfile`; a click cycles the profiles it offers |
| Do not disturb, Dark mode | `[quick_settings]` in `$XDG_CONFIG_HOME/atos/shell.toml` (`do_not_disturb`, `dark_mode`). Dark mode re-themes the shell at once; publishing it to the portal is not done yet |
| Record screen | Disabled tile, "Not available yet": no recorder service exists |
| Brightness | `/sys/class/backlight` to read, logind `SetBrightness` to write (never below 1); disabled without a backlight |
| Volume, sound outputs | PipeWire native protocol (`pipewire` crate): the default sink's `channelVolumes` on the perceptual (cube-root) scale and `default.configured.audio.sink` in the `default` metadata |
| Privacy chip | Text property of the window, hidden while empty; no source is wired up yet |
| Settings button | Runs the `Exec=` of `org.atos.Settings.desktop`; nothing if it is not installed |
| Power options | logind `Suspend`, `Reboot`, `PowerOff` (interactive, so polkit may ask) |

A tile whose service is missing is shown disabled ("Unavailable"). While the panel is open the services are read again every 3 s; closed, nothing polls. The window is created on each opening and dropped on closing.

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
