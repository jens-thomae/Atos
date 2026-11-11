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
| `src/platform.rs` | Slint platform on wlr-layer-shell: the #59 spike's backend ([layer-shell-spike.md](../../docs/components/c4-toolkit/layer-shell-spike.md)) without its popups, popup pool and timing hooks, plus one layer surface per output, output hotplug, overlay placement and re-showing a hidden window (#64). Replaced by the C4 backend crate (spike section 6, card 1) |
| `src/accesskit.rs` | The spike's AccessKit port (modified copy of a Slint file, GPL-3.0-only, D-013) |
| `src/toplevels.rs` | Running windows: `ext-foreign-toplevel-list-v1` for the list, atos-comp's `zcosmic_toplevel_info_v1` (v2+) for the activated state, `zcosmic_toplevel_manager_v1.activate` on click |
| `src/icons.rs` | App icon from the app ID: `Icon=` of `<app_id>.desktop`, then hicolor and `pixmaps` in the XDG data directories and Flatpak's export directories |
| `src/capture.rs`, `src/preview.rs` | Window previews for the switcher (#266): copy-capture client, and the scaling to tile size |
| `ui/switcher.slint`, `src/switcher.rs`, `src/switcher_model.rs` | The Alt+Tab window switcher (#226), after the owner's mockups in `docs/design/mockups/`; `switcher_model` is the display-free order, grouping and selection |
| `ui/control-centre.slint` | The control centre panel, after the owner's Control centre mockup; `ui/shell.slint` is the one file `build.rs` compiles (dock and control centre) |
| `src/control_centre.rs` | Opens, closes and feeds the panel; Settings launch by desktop-entry id |
| `src/services.rs`, `src/audio.rs`, `src/portal.rs` | D-Bus services (NetworkManager, BlueZ, power-profiles-daemon, logind), the PipeWire client, and the xdg-desktop-portal Settings backend for dark mode |
| `src/control.rs`, `src/config.rs` | The six tiles as data and the privacy-chip trait; the shell config file (D-010 TOML) |
| `ui/*.slint` controls | Buttons, rows, tiles, slider, search field and panel come from `components/c4-toolkit/ui/widgets/` ([widgets.md](../../docs/components/c4-toolkit/widgets.md)); the shell files keep layout and `Slot`, `LauncherButton` |
| `ui/notice.slint`, `src/notice.rs`, `src/notice_ui.rs` | The disk-not-sealed notice (#138), see below |
| `tests/` | Screenshot and accessibility-tree tests with the C4 harness ([screenshot-tests.md](../../docs/components/c4-toolkit/screenshot-tests.md)) |
| `e2e/` | End-to-end run on atos-comp (nested in headless sway) and its checks, used by CI |

## In the image (#186)

The c1-base build compiles `atos-shell` in its own `shell` stage (our pinned Slint through `tools/slint-fork/slint-fork.sh setup`, thin LTO) and installs it as `/usr/bin/atos-shell`, with `data/atos.portal`. The session wrapper `usr/libexec/atos/atos-session` (C1) starts it next to atos-comp and restarts it after a crash; see "Session" in the [C1 README](../../docs/components/c1-base/README.md). CI boots the image and checks the dock, the launcher and the restart there.

## Window switcher behaviour (#226)

- atos-comp's `System(WindowSwitcher)` and `System(WindowSwitcherPrevious)` (Alt+Tab, Alt+Shift+Tab, and the Super variants) run `atos-shell --switcher next|prev`, which reaches the running shell over the launcher's socket.
- The first request opens a panel over the output (overlay layer, exclusive keyboard) on the previous app; while it is open the compositor still matches Alt+Tab and sends the next request. Releasing Alt and Super (`platform::on_modifiers`) activates the selection; Esc or a click outside cancels; arrows move; backtick picks the next window of the selected app; W asks the app to close the selected window (`zcosmic_toplevel_manager_v1.close`).
- One tile per app (`app_id`), most recently used first. The shell keeps the history itself from the activated state it sees, so windows already open when it started keep opening order until first used.
- **Previews (#266):** `src/capture.rs` captures every listed window while the panel is open: `ext_foreign_toplevel_image_capture_source_manager_v1` (source from the window's ext handle) and `ext_image_copy_capture_v1` into a wl_shm buffer (memfd). atos-comp offers both to clients without a Wayland security context only, so Flatpak apps cannot use them (audit on #266). Captures start only once the panel's first frame is on screen (started earlier, they delayed that frame by about 25 ms with ten windows); each tile fills in when its window's first frame arrives and updates every 250 ms. `preview::downscale` scales a frame to the tile's preview size (`Switcher.preview-width/height`, physical pixels) at once; the full frame stays only in the reused shm buffer. Closing the panel destroys every session and buffer and drops the pictures. Nothing is written to disk or logged except timings (`SWITCHER_OPEN_MS`, `SWITCHER_SHOWN_NS`, `SWITCHER_FIRST_PREVIEW_MS`). A window the compositor will not capture keeps the placeholder with its icon.
- The mockups' blurred backdrop needs a compositor-side blur; the panel sits on `Palette.scrim` for now.

## Dock-taskbar behaviour (#63)

- One floating bar per output, anchored to the bottom edge with a `Space.s3` gap, `Size.dock-height` high, exclusive zone so windows do not cover it.
- One slot per running window, in opening order. The tile is the app's icon, or its title's first letter on `Palette.button-secondary` when no icon is found.
- A dot under every slot (`Space.s1`, `Palette.text-3`); the focused window's dot is wider (`Space.s4`) and in `Palette.accent`.
- Click, Return or Space on a slot, or the AT-SPI default action, activates the window. Accessible name: `<title>, running` or `<title>, focused`.
- Without atos-comp's protocols (for example in plain sway) the shell runs with an empty dock.

## Launcher behaviour (#64)

- Opens from the dock's first button ("Open launcher") or with `atos-shell --launcher`, which toggles the launcher of the shell on the same Wayland display through `$XDG_RUNTIME_DIR/atos-shell-$WAYLAND_DISPLAY.sock`.
- **Shortcut:** atos-comp's `System(Launcher)` action, bound by default to Super and Super+/. Bindings and the command (`atos-shell --launcher`) come from atos-comp itself, so the COSMIC shortcuts file is not needed for it (#131). atos-comp turns its shortcuts off when started with a kiosk command, so the session must start the shell another way.
- **Rebinding:** in `~/.config/atos/shortcuts.toml` (D-010; read when atos-comp starts and when its COSMIC shortcuts config changes, no file watch yet): `[shortcuts]` then `launcher = ["Super+l"]`. A missing key, a broken file or an unparsable binding gives the default.
- A full-output overlay layer surface on the focused output: scrim, centred panel with the search field and the apps. Exclusive keyboard while open. A click on the scrim or Escape closes it.
- **Apps:** desktop entries in `applications/` of `$XDG_DATA_HOME`, Flatpak's user and system export directories and `$XDG_DATA_DIRS`; the first directory with a desktop file ID wins. Left out: `NoDisplay`, `Hidden`, `OnlyShowIn`/`NotShowIn` against `$XDG_CURRENT_DESKTOP`, a missing `TryExec`, `Terminal=true` (no terminal app yet). The list is read at start and again on every opening, off the event loop.
- **Search:** case-insensitive on the name; names that start with the query first, then a word that starts with it, then anywhere.
- **Keyboard:** the field has the focus; Down and Up move the focus through the apps and back to the field (a screen reader reads each app's name), Return or Space starts the focused app, Return in the field starts the first match. Every app is an AT-SPI button whose default action starts it.
- **Opening time:** one launcher window lives all session. Hiding drops its layer surface, and showing creates a new `wl_surface` for the same window (`platform.rs`), so the renderer keeps its caches (glyphs, icon textures, the panel's shadows) and only the first opening pays for them. To spare that one too, the shell renders the hidden launcher once after its own first frame (`platform::warm_up`, into an EGL pbuffer, or surfaceless if the driver has no pbuffer config; `environment.txt` says which).
- **Timing harness** (reusable for other shell surfaces): the shell prints `LAUNCHER_OPEN_MS` (request received to the frame callback of the first frame) and `LAUNCHER_SHOWN_NS` (wall clock at that callback). `e2e/run.sh` writes `date +%s%N` just before each `atos-shell --launcher`, so `launcher-open-ms.txt` covers the shortcut's whole path, process start included. `check.sh` fails if any opening, the cold first one included, exceeds `SHELL_OPEN_MS`; the workflow's check steps use `shell: bash` (pipefail), so the failure fails the job. The shell prints `LAUNCHER_OPEN_MS <ms>` from the trigger to the compositor's frame callback for the first frame; the e2e run checks it against §7's 100 ms on the NUC.
- **Budget gate (#125):** `run.sh` keeps the budgets harness' exit code in `budgets.exit` (0 pass, 1 breach, 2 could not measure) instead of discarding it. `check.sh` always fails on 2; on 1 (idle CPU or cold start over §7, RSS is checked separately against the shell's share) it fails when `SHELL_GATE=1`, which only the NUC job sets, and otherwise warns. Without weston on the NUC the dock stays empty (owner: `apt install weston`, `docs/reference-runner.md`).

## Control centre behaviour (#65)

Contents agreed with the owner on the card. Opened by the dock's rightmost button (accessible name "Control centre"); Escape, a click anywhere outside the panel (the same button when pressed through AT-SPI too), Settings or a power action close it. The window is an overlay-layer surface covering the output, with the panel in its bottom right corner above the dock; that is how an outside click is seen. It takes the keyboard while open.

| Item | Source |
| --- | --- |
| Wi-Fi tile | NetworkManager, `WirelessEnabled`; subtitle is the first Wi-Fi device's active connection |
| Bluetooth tile | BlueZ, first adapter's `Powered`; subtitle is a connected device |
| Power tile | power-profiles-daemon `ActiveProfile`; a click cycles the profiles it offers |
| Do not disturb, Dark mode | `[quick_settings]` in `$XDG_CONFIG_HOME/atos/shell.toml` (`do_not_disturb`, `dark_mode`). Dark mode re-themes the shell at once and is published to apps: the shell is an xdg-desktop-portal Settings backend (`src/portal.rs`, `data/atos.portal`, installed by the image) answering `org.freedesktop.appearance color-scheme` and emitting `SettingChanged` |
| Record screen | Disabled tile, "Not available yet": no recorder service exists |
| Brightness | `/sys/class/backlight` to read, logind `SetBrightness` to write (never below 1, one worker applies the changes in order); the slider is hidden without a backlight |
| Volume, sound outputs | PipeWire native protocol (`pipewire` crate): the default sink's `channelVolumes` on the perceptual (cube-root) scale and `default.configured.audio.sink` in the `default` metadata |
| Privacy chip | `control::PrivacySource` (one method, the chip text or `None`); no implementation exists, so the chip is hidden until a source is handed to the control centre |
| Settings button | Runs the `Exec=` of `org.atos.Settings.desktop`; nothing if it is not installed |
| Power options | logind `Suspend`, `Reboot`, `PowerOff` (interactive, so polkit may ask). Suspend acts at once; Restart and Shut down first show "<action> now?" with Cancel (focused) and the action; Escape cancels the question |

`CONTROL_CENTRE_OPEN_MS` in the shell's output is the time from the open request to the first frame shown; `e2e/` opens the panel five times and `check.sh` fails above `SHELL_OPEN_MS` (100 ms on the NUC, §7).

A tile whose service is missing is shown disabled ("Unavailable"). While the panel is open the services are read again every 3 s; closed, nothing polls. The window is made at start-up, rendered once while hidden (after the shell's first frame, like the launcher's warm-up) and shown and hidden on each use.

## Disk-not-sealed notice (#138)

When `/run/atos/disk-unsealed` exists (written by C11's `atos-tpm-seal` while the install-time no-PCR TPM2 slot is still the unlock; interface in the [C11 README](../../docs/components/c11-installer/README.md)), the shell shows a card in the top right corner of one output: "Your disk is not protected from other systems", what that means in plain words, and to turn on Secure Boot in the firmware settings. **Learn more** opens the C11 page with `xdg-open`. **Dismiss** hides it until the shell restarts, so it is back at the next login while the file lasts. The shell looks at start-up and every 5 s for a minute afterwards (the seal unit may finish after the session starts); after a successful seal the file is gone and nothing shows. Do not disturb does not silence it: it is a security warning. It takes no exclusive zone and no keyboard grab. The shell does not read the LUKS header.

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
