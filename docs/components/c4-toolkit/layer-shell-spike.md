# Spike: Slint on wlr-layer-shell with an AccessKit tree (#59)

Card: #59 · Written: 2026-11-06 · Code: [`spikes/c4-layer-shell/`](../../../spikes/c4-layer-shell/) (throwaway, outside the workspace) · CI: [`.github/workflows/t59-layer-shell.yml`](../../../.github/workflows/t59-layer-shell.yml)

This spike tests the largest known risk of D-006 (§4.3 costs, §5): whether Slint can draw shell surfaces through a layer-shell backend of our own, with an accessibility tree, and at what cost. It decides nothing. Proposals for the owner are flagged in [section 7](#7-for-the-owner).

## Summary

**Yes, and more cheaply than D-006 estimated.** A panel-like layer surface and a popover (an `xdg_popup` parented to it) render through Slint's public FemtoVG renderer. Both appear on AT-SPI with their controls named, and an AT-SPI *click* on the panel's button opens the popover.

- **No Slint patch was needed.** The backend uses public `slint::platform` API, plus `#[doc(hidden)]` hooks that Slint's own Qt and testing backends implement ([section 5](#5-slint-internals-touched-and-the-risk-on-each-release)). The patch queue stays empty for this card.
- **The accessibility port is small.** Slint's 1,011-line AccessKit adapter runs unchanged except for an 85-line diff (52 added, 33 removed). It **3-way-merges with no conflicts onto Slint `master` (1.19.0-dev)**, and the spike builds and passes its checks there without changes, after raising the `accesskit` and `accesskit_unix` pins.
- **The popover meets §7 on the NUC's GPU, with a wide margin.** Key press to popover presented: **33.4 ms for the first open and 29.0 ms median (max 34.4 ms) over 29 more** when each open builds its own EGL context and renderer (the obvious port of Slint's popup model). With a **pre-warmed popup window that is reused**: **11.6 ms first, 2.5 ms median (max 4.8 ms)**. Budget: ≤ 100 ms. These are lower bounds (headless output, [section 3](#3-how-the-popover-time-is-measured)). On software rendering (hosted CI, dev VM), only the pooled mode keeps the first open under 100 ms.
- **Memory is a third of the single-process shell share.** On the NUC, idle RSS is **100.7 MB** 5 s after the first frame, and **98.4 MB (pooled) or 105.1 MB (not pooled) after 30 popover opens**. The share is 300 MB (D-006 G5). About 68 MB of it is file-backed (Mesa's Intel driver, Slint). Idle CPU over 60 s was 0.00 %.
- **Estimate to productise: 8–11 builder cards** ([section 6](#6-cards-to-productise)), within D-006's 6–12 for the layer-shell backend plus its accessibility port.

## 1. Approach

```
Slint component (.slint)                     AT-SPI bus (D-Bus)
        │                                            ▲
slint::Window ── WindowAdapter = LayerWindow ── AccessKitAdapter (port of Slint's accesskit.rs)
        │            │        │                       └─ accesskit_unix::Adapter, one per shown surface
        │            │        └─ FemtoVGRenderer (public API) on an EGL context (glutin)
        │            └─ wl_surface + role: zwlr_layer_surface_v1 (panel) or xdg_popup (popover)
        └─ Platform = WaylandPlatform: smithay-client-toolkit + calloop event loop
```

- **Platform** (`src/platform.rs`, about 1,200 lines including input and dispatch boilerplate). `slint::platform::Platform` with its own calloop loop. Slint timers drive the dispatch timeout, and frame callbacks pace rendering. `invoke_from_event_loop` goes through a calloop channel.
- **Top-level windows become layer surfaces.** The panel's height comes from the component's preferred size (`WindowProperties::layout_constraints`). It is anchored top, left and right, with an exclusive zone.
- **Slint popups become `xdg_popup`s.** Slint asks the backend for a popup window through `WindowAdapterInternal::create_child_window_adapter`. The spike returns a `LayerWindow` that, on `set_visible(true)`, creates an `xdg_popup` with a positioner at the position Slint gives, calls `zwlr_layer_surface_v1.get_popup` and takes a grab with the last input serial. The compositor's `popup_done` closes the popup in Slint. Slint 1.18.1's winit backend does not implement this hook at all: its popups are drawn inside the parent window, which a 40 px panel would clip.
- **Rendering.** One GLES context per surface, created surfaceless with the window, so `renderer()` exists before the window is shown (Slint measures text through it). The EGL window surface is created on configure at the configured size. Mesa applies a `wl_egl_window` resize only after the next swap, so a surface created earlier at a placeholder size shows its first frame at the wrong size. The spike first hit this: the popover was mapped, but showed a 1×1 buffer. Swap interval 0; frame callbacks pace the loop.
- **Popup pool** (`T59_POPUP_POOL`, on by default). One hidden popup window is created after the panel's first frame and reused, keeping its EGL context and renderer. On hide only the role objects are destroyed. The `wl_surface` stays and takes the popup role again. Turned off, every open builds the context and renderer, as Slint's model implies.
- **Accessibility** (`src/accesskit.rs`). A copy of Slint 1.18.1's `internal/backends/winit/accesskit.rs` with a small shim. `WinitWindowAdapter` is aliased to our `LayerWindow`, and `accesskit_winit::Adapter` is replaced by a wrapper around `accesskit_unix::Adapter`. The tree builder, node IDs, text-run handling and action mapping are upstream's code. Each surface registers as one window of the application on AT-SPI while it is shown. A hidden pooled popover is therefore off the bus, and no tree is built for a window without a component. That window-without-component case panics inside `accesskit_consumer`, which the winit backend never meets.

## 2. What the spike shows

`measure.sh` runs headless sway, starts the spike with the AT-SPI bus switched on and does the following:

1. Dumps the tree with only the panel (`atspi-1-panel.txt`), then presses the panel's *Quick settings* button **through AT-SPI's Action interface**, the path an assistant uses as its fallback (C12). Then it dumps the tree again with the popover open (`atspi-2-popover.txt`).
2. Checks that the popover is on screen: one pixel inside it must differ from one outside it. Checked for the AT-SPI open and for a keyboard open in both pool modes. CI fails otherwise.
3. Opens and closes the popover N times from the keyboard (`wtype`: Space opens, Escape closes), with and without the pool, and records the popover times and the RSS after 5 s idle.
4. Runs the budgets harness for start-up, idle RSS and idle CPU.

The tree with the popover open (dev VM; the same in hosted CI):

```
application 'c4-layer-shell' []
  frame 'Atos panel' ['enabled', 'focusable', 'sensitive', 'showing', 'visible']
    push button 'Quick settings' ['enabled', 'focusable', 'sensitive', 'showing', 'visible']
    label '12:00' ['enabled', 'sensitive', 'showing', 'visible']
  frame '' ['enabled', 'focusable', 'sensitive', 'showing', 'visible']
    label 'Quick settings' ['enabled', 'sensitive', 'showing', 'visible']
    check box 'Wi-Fi' ['checkable', 'checked', 'enabled', 'focusable', 'sensitive', 'showing', 'visible']
    check box 'Bluetooth' ['checkable', 'enabled', 'focusable', 'sensitive', 'showing', 'visible']
    push button 'Close' ['enabled', 'focusable', 'sensitive', 'showing', 'visible']
```

Every control has a role and a name. The gap is the popover's own node: a `frame` with no name and no parent relation to the panel. This is D-011's A6 ("popups belong to their app"), the same as for Slint's winit popups, and it is in the cards below. The screenshots (`1-panel.png`, `2-popover.png`) are in the run's `t59-results-*` artifact.

## 3. How the popover time is measured

**Popover fully visible** = the compositor's presentation time of the popover's first frame (`wp_presentation` feedback, `CLOCK_MONOTONIC`), minus the time the spike received the key press that opened it (`CLOCK_MONOTONIC`, read on receipt).

- **Covers:** Slint's popup instantiation and layout, the backend's surface and role set-up, the compositor round trip for the popup's configure, rendering, and the compositor presenting the frame.
- **Not covered:** input device and kernel latency before the compositor, and scanout after presentation. On a headless output "presented" means the compositor committed the frame to its virtual output, so add up to one refresh interval for a real display. The §7 budget (100 ms) leaves room for that, but the NUC numbers below are a lower bound on what a user sees.
- The first open after start is reported separately (the "cold" case §4.1 G1 insists on). The popover has no open animation. If the design system gives it one, "fully visible" ends when the animation ends.
- Input comes from `wtype` (keyboard) because the NUC has it and no pointer injector. The panel takes the keyboard (`KeyboardInteractivity::Exclusive`, `T59_EXCLUSIVE_KEYBOARD`, a measurement setting) so no click is needed first. A real panel uses on-demand focus.

## 4. Measurements

### 4.1 Reference NUC, GPU

[Run 42246103328](https://github.com/jens-thomae/Atos/actions/runs/42246103328), job `measure-nuc`, 2026-11-06. Intel Celeron N5105, kernel 6.8.0-147, sway 1.9 headless on `gles2`, Mesa 25.2.8. Renderer proof: sway's Wayland clients and the spike's own context both report `Mesa Intel(R) UHD Graphics (JSL)`. 30 keyboard opens per mode, idle CPU over 60 s.

| Metric | Budget | New EGL context per open | Pre-warmed popup pool |
| --- | --- | --- | --- |
| Popover fully visible, first open | ≤ 100 ms | **33.4 ms** ✅ | **11.6 ms** ✅ |
| Popover fully visible, later opens, median / max (n = 29) | ≤ 100 ms | **29.0 / 34.4 ms** ✅ | **2.5 / 4.8 ms** ✅ |
| Idle RSS after 30 opens | ≤ 300 MB (shell share) | 105.1 MB (anon 37.0, file 68.1) ✅ | 98.4 MB (anon 30.7, file 67.7) ✅ |
| Start to first panel frame (budgets harness) | – | | 83 ms |
| Idle RSS 5 s after first frame (budgets harness) | ≤ 300 MB | | 100.7 MB ✅ |
| Idle CPU over 60 s | ≤ 1 % | | 0.00 % ✅ |

The popover was on screen in every opening path (pixel inside 250,250,250 against 64,64,64 outside), and the AT-SPI tree matched [section 2](#2-what-the-spike-shows) line for line.

What the numbers say:

- Without the pool, about 25–30 ms of each open is building the context and FemtoVG (shaders, glyph atlas). On this GPU that fits the budget three times over. With the pool, an open costs a configure round trip and one frame.
- 2.5 ms is less than a refresh interval because the headless output presents on commit. On a real 60 Hz display, add up to 16.7 ms.
- These numbers are for one simple popover. A launcher or control centre with more content costs more per frame; the pool keeps the set-up cost out of it.

### 4.2 Hosted CI (software rendering, indicative)

Same run, job `measure-hosted`: x86_64 Xeon 8370C, sway on pixman, llvmpipe. 20 opens per mode.

| Metric | New EGL context per open | Pre-warmed popup pool |
| --- | --- | --- |
| Popover fully visible, first open | 101.9 ms ❌ | 28.4 ms |
| Later opens, median / max (n = 19) | 45.4 / 85.2 ms | 2.7 / 4.8 ms |
| Idle RSS after 20 opens | 180.2 MB | 137.3 MB |

On software GL, building a context costs far more, and only the pooled mode keeps the first open under budget. This matters for the software fallback of D-006.

### 4.3 Dev VM (indicative only)

Lima VM on an Apple M1 Max, aarch64, sway 1.9 with pixman, llvmpipe. Not the reference hardware. Software rendering, and VM timing noise of tens of milliseconds between runs.

| Metric | Budget | New EGL context per open | Pre-warmed popup pool |
| --- | --- | --- | --- |
| Popover fully visible, first open | ≤ 100 ms | 111.6 ms ❌ | 28.2 ms ✅ |
| Popover fully visible, later opens, median / max (n = 9) | ≤ 100 ms | 38.6 / 88.9 ms | 3.5 / 8.4 ms |
| Idle RSS after 10 opens | ≤ 300 MB (shell share) | 178.6 MB | 140.7 MB |
| Start to first panel frame (budgets harness) | – | | 181 ms (85 ms in another run) |
| Idle RSS 5 s after first frame (budgets harness) | ≤ 300 MB | | 140.3 MB |
| Idle CPU over 10 s | ≤ 1 % | | 0.10 % |

RSS breakdown (pooled): RssAnon 62 MB, RssFile 78 MB, almost all of the file-backed part Mesa's driver. Without the pool, RSS climbs to about 180–190 MB after a few opens and then stays flat over 30 opens (no leak: every popup window was dropped). It is allocator and driver retention from repeated context creation. The same run on Slint `master` gave 125 ms and 15.5 ms for the first open (no pool and pool).

## 5. Slint internals touched, and the risk on each release

| What | Where | Kind | Used by |
| --- | --- | --- | --- |
| `Platform`, `WindowAdapter`, `WindowEvent`, `WindowProperties`, `FemtoVGRenderer`, `OpenGLInterface`, timers, `EventLoopProxy` | `slint::platform` | Public API | Backend |
| `WindowAdapter::internal` with `i_slint_core::InternalToken` | `i-slint-core` | `#[doc(hidden)]` | Backend |
| `WindowAdapterInternal::create_child_window_adapter`, `handle_focus_change`, `register_item_tree`, `unregister_item_tree` | `i_slint_core::window` | `#[doc(hidden)]` trait | Backend: popups and the tree's update triggers |
| `WindowInner::from_pub(..).close_all_popups()` | `i_slint_core::window` | Internal | Backend: compositor dismissal and Escape |
| `i_slint_core::accessibility::*`, `item_tree::*`, `items::{ItemRc, WindowItem, AccessibleRole, …}`, `WindowInner::{focus_item, active_popups, try_component, ensure_tree_instantiated, set_focus_item}`, `PropertyTracker`, `ItemCache`, `textlayout::sharedparley::CachedTextInputAccessibilityState` | `i-slint-core` | Internal | The AccessKit port (unchanged upstream code) |

`i-slint-core` is pinned `=1.18.1`, as Slint's own crates pin each other. Internal items carry no semver promise.

**Risk per Slint release.**

- **The port.** It is a fork of one upstream file. Every Slint release that changes `internal/backends/winit/accesskit.rs` must be merged into it. The procedure is a 3-way merge of upstream's change onto our copy (`git merge-file ours base theirs`), then a build. **Measured dry run, 1.18.1 → `master` at `b4448d8` (2026-11-06, 1.19.0-dev):** upstream changed the file by 55 diff lines since 1.18.1 and moved `accesskit` from 0.24 to 0.25 (`accesskit_unix` 0.22 to 0.24). The merge had **0 conflicts**. The spike needed **0 code changes**, only the three version pins. It built and passed the tree, pixel and timing checks. Effort: about 15 minutes, mostly build time. That is one data point, not a forecast: a release that restructures the adapter (for example moving it into `i-slint-core`, as its own doc comment suggests) costs a re-port, likely one card.
- **The backend's hooks** are the ones Slint's own Qt and testing backends implement, so they change rarely and visibly. A break there shows up as a compile error, not a silent change.
- **Behaviour without a compile error is the real risk.** Example from this spike: a window with no component crashes `accesskit_consumer`, which upstream never hits. The CI job (tree, pixel and timing checks) is the guard and must run on every Slint bump.
- **Licence.** `src/accesskit.rs` is Slint's GPL-3.0-only file and stays under it (D-013). The spike's manifest says GPL-3.0-only.

**Compared with D-006 §3.4's expectation** ("rechecked, and often adapted, on every Slint release, a few hours to a day per minor release"): the first measured rebase cost minutes. The estimate stays until a real release is followed. Repeat this measurement in [rebase.md](rebase.md)'s log at the first real rebase.

## 6. Cards to productise

Estimate in builder cards (one session each), from what the spike had to build and what it skipped (each skip is marked `ponytail:` in the code).

| # | Card | Est. |
| --- | --- | --- |
| 1 | C4 crate for the layer-shell backend: platform, event loop, layer surfaces, popups, popup pool, with unit tests and the CI job of this spike as its integration test | 2 |
| 2 | Input: modifiers, key repeat, full keysym mapping, pointer cursor shapes (`cursor-shape-v1`), axis value120 scrolling, touch | 1–2 |
| 3 | Outputs: one surface per output, hotplug, fractional scaling (`wp_fractional_scale_v1` + viewporter) | 1–2 |
| 4 | Popups: nested menus (popup in popup), tooltips, constraint handling, Escape and close semantics matching Slint's in-window popups, grab rules | 1 |
| 5 | Accessibility: move the port into the Slint patch queue as a backend-neutral module (see 7.2), name and role the popover and relate it to its parent (A6), window bounds, focus across surfaces, tree checks in CI | 1–2 |
| 6 | Rendering: damage tracking (buffer age), presentation-paced frames, shared GL context or shader cache across surfaces, measured against the popover budget and G5 | 1 |
| 7 | Text input for shell surfaces (`text-input-v3`, IME), needed for the launcher and command palette | 1 |

**Total: 8–11 cards**, high confidence for 1–4, medium for 5–7. D-006 §3.4 expected 4–8 for the backend plus 2–4 for its accessibility port (6–12). Clipboard is not counted here; it is the separate clipboard card.

## 7. For the owner

1. **Proposed: shell popovers use a pre-warmed, reused popup window** (one per popover kind, or a small pool), not a new window per open. On the NUC's GPU both modes pass (33 ms against 12 ms for the first open), so this buys margin for heavier popovers. On the software fallback it decides the budget (102 ms against 28 ms in hosted CI), and it saves RSS there (about 40 MB). The cost is one idle EGL context per pooled window. On the NUC the pooled run still ended with less RSS than the unpooled one (98 MB against 105 MB after 30 opens). A design consequence for C3/C4, not decided by this spike.
2. **Proposed: carry the AccessKit adapter as a patch in the Slint queue, not as a copy in C4.** The patch would move `accesskit.rs` out of the winit backend into a backend-neutral internal module, generic over a small window trait. The rebase routine (`slint-fork.sh rebase`) then shows conflicts per release, instead of a manual 3-way merge of a copied file. The spike kept the copy because it measures the port's diff size directly.
3. The keyboard-exclusive panel (`T59_EXCLUSIVE_KEYBOARD`) and the `wtype` input path are measurement choices, not shell design.

## 8. Reproduce

```sh
tools/slint-fork/slint-fork.sh setup
tools/dev-vm/vm run cargo build --release -p budgets
tools/dev-vm/vm run bash -c 'cd spikes/c4-layer-shell && cargo build --release --config ../../third_party/slint/patch.toml'
(cd spikes/c4-layer-shell && ../../tools/dev-vm/vm run bash -c 'T=$CARGO_TARGET_DIR/release; ./measure.sh $T/c4-layer-shell $T/budgets out/vm')
```

On CI: any PR touching the spike runs the hosted job. The label `t59-nuc` adds the NUC run on the GPU (same-repo branches only).
