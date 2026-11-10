# atos-comp code map

For an agent with a C2 card. All paths are relative to `components/c2-compositor/` (about 73,000 lines of Rust, a fork of cosmic-comp on [Smithay](https://github.com/Smithay/smithay); see the [README](README.md)). Line numbers are left out on purpose: search for the names. Verified by script against `epoch-1.11.0` plus our changes (see the PR of #199); re-run the check after a merge from upstream.

Terms: **Common** is the state shared by everything; **Shell** owns outputs, workspaces and windows; a **mapped** window is a `CosmicMapped` (a window or a stack of tabs).

## 1. Structure

| Path | What it is |
| --- | --- |
| `src/main.rs`, `src/lib.rs` | `main` calls `atos_comp::run` (`lib.rs`): parses `--help`, `--version`, `--no-xwayland` and a kiosk command; then logger, session socket, event loop, `State::new`, `backend::init_backend_auto`, theme watch, `event_loop.run`. The loop closure calls `refresh` (end of `lib.rs`) every iteration. |
| `src/state.rs` | `State` (event loop data) holds `BackendData` and `Common`. `Common` holds the Smithay protocol states, `config`, `shell` (an `Arc<RwLock<Shell>>`), clocks, D-Bus and Xwayland state. `State::new` creates every Wayland global. Also `Common::send_frames`, `send_dmabuf_feedback`, `update_primary_output`. |
| `src/backend/` | Where pixels go and input comes from. `mod.rs` (`init_backend_auto`), `kms/` (real hardware), `winit.rs` (nested window), `x11.rs` (nested in X11), `render/` (shared rendering). |
| `src/input/` | `mod.rs` (`process_input_event`), `actions.rs` (what shortcuts do), `gestures/` (touchpad swipes), `tablet_emu.rs`. |
| `src/shell/` | Window management. `mod.rs` (`Shell`, `WorkspaceSet`), `workspace.rs`, `layout/{floating,tiling}`, `element/` (windows and tab stacks as scene elements), `focus/`, `grabs/` (move, resize, menus), `seats.rs`, `zoom.rs`. |
| `src/wayland/` | `handlers/` implements Smithay handler traits on `State`; `protocols/` holds our own server side of COSMIC and other protocols that Smithay does not provide. |
| `src/config/` | Compositor config on top of cosmic-config; `atos_shortcuts.rs` is the Atos part. Types live in the `atos-comp-config` crate. |
| `src/dbus/`, `src/libei.rs`, `src/session.rs`, `src/systemd.rs`, `src/theme.rs` | System integration (section 6). |
| `src/xwayland.rs` | Xwayland and the X window manager. |
| `src/utils/` | Helpers: `iced/` (iced widgets as compositor elements), `geometry.rs`, `tween.rs`, `screenshot.rs`, `quirks.rs`. |
| `data/` | `keybindings.ron` (default shortcuts), `tiling-exceptions.ron`, `atos-comp.service`. |
| `resources/` | `i18n/` (fluent strings), `icons/`, `cursor.rgba`, `protocols/wayland-drm.xml`. |
| `examples/` | One example: custom window decorations through `Hooks` (`src/hooks.rs`). |

## 2. Main loop and state

One thread, one calloop event loop (`calloop`), no async runtime in the compositor itself (D-Bus runs on `zbus` futures spawned into the loop, `DBusState::spawn` in `src/dbus/mod.rs`). Everything is `&mut State`.

1. A backend inserts sources: DRM vblank, libinput, winit or X11 events, Wayland clients, timers, config watchers.
2. Client requests land in `impl ...Handler for State` blocks in `src/wayland/handlers/`. A surface commit goes through `CompositorHandler::commit` in `handlers/compositor.rs`.
3. Input goes through `State::process_input_event` (`src/input/mod.rs`).
4. At the end of each iteration `refresh` in `lib.rs` calls `Shell::refresh` and the protocol refreshes (toplevel info, workspaces, idle inhibit, overlap notify).
5. Rendering is scheduled per output (`BackendData::schedule_render` in `src/state.rs`) and runs on vblank.

## 3. Backends and rendering

- **Selection**: `init_backend_auto` in `src/backend/mod.rs`. `COSMIC_BACKEND=kms|winit|x11` forces one. Without it: if `DISPLAY` or `WAYLAND_DISPLAY` is set it tries `x11::init_backend` and falls back to `winit::init_backend`, otherwise `kms::init_backend`. It then creates the first seat (`shell::create_seat`).
- **KMS** (`src/backend/kms/`): `mod.rs` (`KmsState`, `init_backend`, libinput and session, `apply_config_for_outputs`), `device.rs` (one DRM device, connectors, leases), `surface/mod.rs` (one output: `schedule_render`, `on_vblank`, `redraw`), `surface/timings.rs` (frame timing), `render/{gles,pixman}.rs` (renderers per device), `drm_helpers.rs`, `socket.rs`.
- **winit / X11**: `winit.rs` and `x11.rs` each have `init_backend`, `render_output` and `apply_config_for_outputs`. They are for development; one window is one output.
- **Rendering**: `src/backend/render/mod.rs`. `workspace_elements` builds the element list for an output, `cursor_elements` the cursor, `render_output` draws and returns damage, `init_shaders` loads `shaders/*.frag` (rounded corners, shadow, blur, clipping). Damage tracking is Smithay's: `OutputDamageTracker` in `winit.rs` and `x11.rs`, the DRM compositor on KMS (`kms/surface/mod.rs`, which also decides direct and overlay scanout) (switches `COSMIC_DISABLE_DIRECT_SCANOUT`, `COSMIC_DISABLE_OVERLAY_SCANOUT`).
- `render/element.rs` (`CosmicElement`, the element enum), `render/cursor.rs`, `render/shadow.rs`, `render/wayland/` (blur, clipped surfaces), `render/animations/spring.rs` (`Spring`).

## 4. Input path

libinput (`LibinputInputBackend`, set up in `backend/kms/mod.rs`; winit and X11 events in their backends) delivers `InputEvent`s to `State::process_input_event` (`src/input/mod.rs`), one `match` arm per event kind (`Keyboard`, `PointerMotion`, `PointerMotionAbsolute`, `GestureSwipeBegin`, touch, tablet, ...). Keyboard: `process_keyboard_filter` looks the key up in `Config.shortcuts`; a hit runs `handle_shortcut_action` in `src/input/actions.rs`, which `match`es on the action. Pointer: the position is clamped to outputs, the surface under it is found in `Shell` and the pointer focus is set (`PointerFocusTarget`, `src/shell/focus/target.rs`); clicks update keyboard focus (`KeyboardFocusTarget`, same file; `Shell::set_focus` area in `src/shell/focus/mod.rs`). Input devices are configured by `update_device` in `src/config/input_config.rs`. Synthetic input arrives through `src/libei.rs` and `src/dbus/ei.rs`; the accessibility keyboard monitor is `src/dbus/a11y_keyboard_monitor.rs`.

## 5. Shell and layout

- `Shell` (`src/shell/mod.rs`): `outputs`, `seats` (`Seats`), `workspaces` (one `WorkspaceSet` per output, or one shared set), `pending_windows`, `pending_layers`, `overview_mode` (`OverviewMode`), and all window operations: `map_window`, `map_layer`, `unmap_surface`, `move_request`, `resize_request`, `maximize_request`, `minimize_request`, `unfullscreen_request`, `toggle_stacking`, `toggle_sticky`, `set_overview_mode`, `move_workspace`, `refresh`.
- `Workspace` (`src/shell/workspace.rs`): one `FloatingLayout`, one `TilingLayout`, fullscreen and maximized state (`ManagedLayer`), focus stack, `animations_going`, `update_animations`.
- **Floating** (`layout/floating/mod.rs`): `FloatingLayout`, per-window `Animation` enum (tiled, minimize, shake), `map_internal`. Grabs in `floating/grabs/`.
- **Tiling** (`layout/tiling/mod.rs`, the biggest file): `TilingLayout` keeps a tree of nodes (`id_tree`) and animates between two trees (`ANIMATION_DURATION`, `MINIMIZE_ANIMATION_DURATION`); `map`, `map_internal`, `unmap_window_internal`, `move_current_node`, `update_orientation`. `tiling/blocker.rs` holds back a tree change until clients have committed the new size; `tiling/grabs/` has resize and swap.
- **Elements** (`src/shell/element/`): `CosmicMapped` (`mod.rs`) is either a `CosmicWindow` (`window.rs`, server decoration as an iced element) or a `CosmicStack` (`stack.rs`, `stack/tabs.rs`); `CosmicSurface` (`surface.rs`) wraps a toplevel or X11 window; `resize_indicator.rs`, `swap_indicator.rs`, `stack_hover.rs`.
- **Overlays**: popups (xdg popups, `PopupGrab` in `src/shell/grabs/mod.rs`), window menus (`shell/grabs/menu/`), the window-move grab (`grabs/moving.rs`), zoom (`zoom.rs`, `ZoomState`), session lock surfaces (`handlers/session_lock.rs`).
- **Layer shell**: `handlers/layer_shell.rs` (`new_layer_surface`, `layer_destroyed`) queues the surface; `Shell::map_layer` maps it, `layer_surface_check_inital_configure` in `handlers/compositor.rs` waits for the first configure, and Smithay's per-output `layer_map` arranges it and yields the usable area that layouts use.

## 6. Wayland protocols (`src/wayland/`)

`handlers/` file, or `protocols/` for our own server code. One line each.

- Core and shell: `compositor.rs` (surface commit, initial configure), `shm.rs`, `buffer.rs`, `dmabuf.rs`, `drm.rs` and `protocols/drm.rs` (wl_drm), `drm_syncobj.rs`, `xdg_shell/` (toplevels, popups, move/resize/fullscreen requests), `decoration.rs` (xdg and KDE server decoration), `layer_shell.rs`, `session_lock.rs`, `fractional_scale.rs`, `output.rs`.
- Seat and input: `seat.rs`, `data_device.rs`, `selection.rs`, `primary_selection.rs`, `data_control/`, `text_input.rs`, `input_method.rs`, `virtual_keyboard.rs`, `keyboard_shortcuts_inhibit.rs`, `pointer_constraints.rs`, `pointer_warp.rs`, `tablet_manager.rs`, `xwayland_keyboard_grab.rs`, `xwayland_shell.rs`.
- Windows and activation: `xdg_activation.rs`, `xdg_foreign.rs`, `foreign_toplevel_list.rs`, `toplevel_info.rs` and `toplevel_management.rs` (COSMIC toplevel protocols; implementation in `protocols/`), `workspace.rs` (ext and COSMIC workspace protocols, `protocols/workspace/`), `overlap_notify.rs`, `idle_inhibit.rs`, `idle_notify.rs`, `security_context.rs`, `drm_lease.rs`.
- Outputs: `output_configuration.rs` (wlr and COSMIC output management, `protocols/output_configuration/`), `output_power.rs`.
- Capture: `image_capture_source.rs`, `image_copy_capture/` (screen and window capture, `render.rs` draws into client buffers).
- COSMIC extras: `corner_radius.rs`, `background_effect.rs` (blur), `a11y.rs`, `keyboard_layout.rs`, `protocols/session_lock_layer.rs`.

## 7. Config, D-Bus, Xwayland, session

- **Config**: `Config::load` (`src/config/mod.rs`) reads cosmic-config entries (shortcuts, input, workspaces, appearance, outputs) and registers watchers that end in `config_changed`. Output layout is stored in `$XDG_STATE_HOME/atos-comp/outputs.ron` (`read_outputs`, `write_outputs`). `atos-comp-config/src/lib.rs` has the plain types (`CosmicCompConfig`, `XkbConfig`, `ZoomConfig`, `CursorHideConfig`), `input.rs`, `workspace.rs`, `output/`. Atos adds `src/config/atos_shortcuts.rs` (D-010 TOML file `~/.config/atos/shortcuts.toml`, the launcher binding) applied by `load_and_apply` after the COSMIC shortcuts load.
- **D-Bus** (`src/dbus/`): `mod.rs` (`DBusState`, `init`), `logind.rs`, `power.rs`, `name_owners.rs` (checks peers), `ei.rs`, `a11y_keyboard_monitor.rs`. The `systemd` feature adds readiness notification (`src/systemd.rs`) and journald logging.
- **Xwayland**: `src/xwayland.rs`, `State::launch_xwayland` and the `XwmHandler` impl (`map_window_request`, `move_request`, ...). Disabled by `--no-xwayland`.
- **Session**: `src/session.rs` talks to `cosmic-session` over `COSMIC_SESSION_SOCK` (unused under Atos).

## 8. Where do I change ...

| Task | File | Function / type |
| --- | --- | --- |
| Add a keybinding to an existing action | `data/keybindings.ron` | default entries; user overrides come from cosmic-config (`Config::load` in `src/config/mod.rs`) |
| Add a new shortcut action | `src/input/actions.rs` | `handle_shortcut_action` (the `match`); the shortcut enum is `shortcuts::Action` in the `cosmic-settings-config` crate (a new variant needs a carried change there); internal ones go in `PrivateAction` (`src/config/key_bindings.rs`) |
| Rebind or add an Atos shortcut (launcher) | `src/config/atos_shortcuts.rs` | `launcher_bindings`, `apply`, `load_and_apply` |
| Change a window animation (tiling, minimize) | `src/shell/layout/tiling/mod.rs` | `ANIMATION_DURATION`, `MINIMIZE_ANIMATION_DURATION`, `animations_going` |
| Change a window animation (floating, shake) | `src/shell/layout/floating/mod.rs` | `Animation`, `ANIMATION_DURATION`, `SHAKE_ANIMATION_DURATION` |
| Add an animation curve | `src/backend/render/animations/spring.rs` | `Spring`, `value_at` |
| Add a Wayland protocol (Smithay has it) | `src/state.rs` and `src/wayland/handlers/` | `State::new` (create global and state in `Common`), new handler file, add to `handlers/mod.rs` |
| Add a protocol of our own (XML) | `src/wayland/protocols/` | pattern: `corner_radius.rs` (server side) and `handlers/corner_radius.rs` |
| Change tiling behaviour (insert, move, orientation) | `src/shell/layout/tiling/mod.rs` | `map_internal`, `move_current_node`, `update_orientation`, `unmap_window_internal` |
| Change tiling resize or swap by mouse | `src/shell/layout/tiling/grabs/` | `resize.rs`, `swap.rs` |
| Tiling exceptions (apps that always float) | `data/tiling-exceptions.ron` | read by the config (`Config::load`) |
| Where a new floating window is placed | `src/shell/layout/floating/mod.rs` | `map_internal`, `map_anchored` |
| Window state requests (maximize, fullscreen, minimize) | `src/wayland/handlers/xdg_shell/mod.rs` | `maximize_request`, `fullscreen_request`, `minimize_request`; logic in `Shell::maximize_request` (`src/shell/mod.rs`) |
| Window decoration look and buttons | `src/shell/element/window.rs` | `CosmicWindow`, `CosmicWindowInternal` (`view` also via `src/hooks.rs`) |
| Layer-surface handling (panels, dock, launcher) | `src/wayland/handlers/layer_shell.rs` | `new_layer_surface`, `layer_destroyed`; `Shell::map_layer` in `src/shell/mod.rs` |
| Output configuration (mode, scale, position) | `src/state.rs` | `LockedBackend::apply_config_for_outputs`, backend `apply_config_for_outputs` in `src/backend/kms/mod.rs`; protocol side `src/wayland/handlers/output_configuration.rs` (`apply_configuration`) |
| Remember output layout | `src/config/mod.rs` | `read_outputs`, `write_outputs` |
| Screen capture, screenshots | `src/wayland/handlers/image_copy_capture/` | `new_session`, `render_session`, `render_workspace_to_buffer`, `render_window_to_buffer` in `render.rs` |
| Rendering effects (corners, shadow, blur) | `src/backend/render/` | `init_shaders`, `shaders/*.frag`, `shadow.rs`, `wayland/blur_effect.rs` |
| What is drawn on an output, and in what order | `src/backend/render/mod.rs` | `workspace_elements`, `render_output` |
| Focus rules (who gets keyboard focus) | `src/shell/focus/` | `KeyboardFocusTarget` (`target.rs`), `order.rs` (stacking order of focus targets) |
| Pointer behaviour (hiding, constraints) | `src/input/mod.rs` | `process_input_event` (`PointerMotion` arm); `src/wayland/handlers/pointer_constraints.rs` |
| Touchpad gestures (workspace swipe) | `src/input/gestures/mod.rs` | `SwipeAction`; handling in `src/input/actions.rs` (`handle_action`) |
| Workspaces (create, move, overview) | `src/shell/mod.rs` | `WorkspaceSet`, `move_workspace`, `set_overview_mode` |
| Input device settings (touchpad, keyboard) | `src/config/input_config.rs` | `update_device`; keyboard in `Config::xkb_config` |
| Session lock / idle | `src/wayland/handlers/session_lock.rs` | `lock`, `unlock`, `new_surface`; `src/wayland/handlers/idle_notify.rs` |
| Xwayland window handling | `src/xwayland.rs` | `map_window_request`, `launch_xwayland` |
| Startup flags and environment | `src/lib.rs` | `run`, `print_help` |

## 9. Running, tests, logs

- **Build** (Linux only; system libraries are listed in `.github/workflows/c2-compositor.yml`, or use the dev VM, `tools/dev-vm/vm run ...`): `cd components/c2-compositor && cargo build --locked`.
- **Quick look, nested**: start a Wayland session (`weston --backend=headless --renderer=pixman --socket=w0`, or any compositor), then `WAYLAND_DISPLAY=w0 COSMIC_BACKEND=winit target/debug/atos-comp`. The compositor prints its own socket (`wayland-N`); run clients with `WAYLAND_DISPLAY=wayland-N zenity` or `weston-simple-shm`. The demo screenshot in the README was made this way. Without `COSMIC_BACKEND` and with `DISPLAY` set it tries the X11 backend first.
- **On hardware (KMS)**: run from a text console with no other compositor on the seat (the session image starts it through greetd, see [C1](../c1-base/README.md)).
- **Tests**: `cargo test --locked` and `cargo clippy --all-targets --locked -- -D warnings` (what `c2-compositor.yml` runs). There are few unit tests (`src/config/atos_shortcuts.rs`, `src/backend/kms/device.rs`, `src/backend/render/cursor.rs`); there is no compositor-level test suite in this directory.
- **End to end**: `tools/dev-vm/smoke.sh` checks only weston plus a client, not atos-comp. The image test `components/c1-base/shell-boot-test.sh` boots the real image, so it exercises `atos-comp`, the launcher shortcut and the shell together (needs KVM, CI only).
- **Logs**: `tracing`, set up in `src/logger/mod.rs` (`init_logger`). Filter with `RUST_LOG`, e.g. `RUST_LOG=atos_comp=debug,smithay=debug`. Debug builds default to `info` and log `atos_comp` and `smithay` at debug; release builds default to `warn`. Output goes to stderr and, with the `systemd` feature (default), to the journal (`journalctl --user -b`, filter by the process name). Protocol tracing is libwayland's `WAYLAND_DEBUG=server` (not ours). Feature `debug` (`cargo build --features debug`) adds the egui overlay (`src/debug.rs`, toggled by the `Debug` shortcut). Tracy: feature `profile-with-tracy`.
- **Environment switches**: `COSMIC_BACKEND`, `COSMIC_RENDER_DEVICE`, `COSMIC_DRM_ALLOW_DEVICES`, `COSMIC_DRM_BLOCK_DEVICES`, `COSMIC_DISABLE_SYNCOBJ`, `COSMIC_DISABLE_DIRECT_SCANOUT`, `COSMIC_DISABLE_OVERLAY_SCANOUT`, `COSMIC_ENFORCE_DBUS_OWNERS`.

## 10. COSMIC leftovers unused by Atos

Candidates for later cleanup cards, one card per group, each a decision first (README lists what we kept on purpose). Nothing here was changed.

- **Session start-up**: `data/atos-comp.service` still has `BindsTo=cosmic-session.target`, `Wants`, `After` and `Before` on `cosmic-session-pre.target`; `src/session.rs` (`COSMIC_SESSION_SOCK`, `Message::SetEnv`) and its use in `src/lib.rs`. Atos starts `atos-comp` from greetd (C1).
- **Environment names**: the `COSMIC_*` variables in section 9.
- **Config IDs and paths**: `com.system76.CosmicSettings.*` (shortcuts, window rules, workspaces, in `src/config/mod.rs` and in the `justfile` install paths `share/cosmic/...`), the `cosmic-comp` cosmic-config ID in `atos-comp-config/src/lib.rs`, `CosmicCompConfig`. Whatever C8 settings writes must match these until they are replaced.
- **Greeter and settings daemon**: `GreeterAccessibilityState` and the `cosmic-greeter` state in `src/backend/mod.rs`; `cosmic-settings-daemon-config` and `cosmic-settings-config` dependencies in `Cargo.toml`.
- **COSMIC look**: `libcosmic` theme and iced widgets for decorations, stacks, menus, indicators (`src/shell/element/`, `src/shell/grabs/menu/`, `src/utils/iced/`, `src/theme.rs`); `COSMIC_TK`. Replaced when C4 design tokens arrive.
- **COSMIC protocols** (`cosmic-protocols`): `toplevel_info`, `toplevel_management`, `workspace/cosmic_v2.rs`, `corner_radius`, `a11y`, `output_configuration/handlers/cosmic.rs`, `overlap_notify`, `keyboard_layout`, `image_capture_source` (parts). Used by cosmic-panel, cosmic-workspaces, cosmic-settings, none of which Atos ships; decide per protocol whether `atos-shell` needs it.
- **i18n**: `resources/i18n/` has about 80 languages from COSMIC's Weblate; Atos has none of its own yet (`atos_comp.ftl`, `i18n.toml`).
- **Packaging**: `justfile` and `cargo.just` (COSMIC install layout), `README.upstream.md`, `data/tiling-exceptions.ron` (app IDs of COSMIC apps); `data/keybindings.ron` is COSMIC's default set (`System(Terminal)`, workspace and tiling keys).
- **Type and module names** with `Cosmic` (`CosmicMapped`, `CosmicSurface`, `CosmicWindow`, `CosmicStack`): rename last, it touches most files and makes upstream merges harder (D-007).
