# D-006: toolkit recommendation (iced/libcosmic or Slint)

Card: #14 · Written: 2026-11-05 · Status of D-006: **Open**. This write-up is a recommendation for the owner. It decides nothing and does not edit the decisions log.

Inputs: the method in [`D-006-prototype-brief.md`](D-006-prototype-brief.md) (#9), the numbers in [`D-006-measurements.md`](D-006-measurements.md) (#12), the agent test in [`D-006-agent-test.md`](D-006-agent-test.md) (#13), the COSMIC write-up [`D-007-cosmic-relationship.md`](D-007-cosmic-relationship.md) (#3, D-007 now **Decided**), the assistant requirements in [`D-011-mcp.md`](D-011-mcp.md) §5.2 (#31), and the prototype READMEs [`spikes/d006-iced/`](../../spikes/d006-iced/README.md) (#10) and [`spikes/d006-slint/`](../../spikes/d006-slint/README.md) (#11). Every external claim links to its source; all links were opened on 2026-11-05 (see [Sources](#sources)).

## Summary for the owner

**Recommendation: Slint, with its binaries shipped under GPL-3.0-only, on one condition: a GPU run on the NUC passes the exact gates in [section 4](#4-recommendation). The owner's part is two package and group commands, and both are reversible ([section 3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it)).**

- Neither toolkit passes every gate today. Both need patches we carry ourselves, because we never contribute upstream.
- **The total cost is similar. The risk is not.** We estimate about 14–24 builder cards for Slint and about 15–29 for libcosmic ([3.4](#34-our-patches-the-gaps-as-patches-we-carry)).
  - **Slint's in-app accessibility gap is small.** Its tree is published for normal windows and correct for 9 of 26 controls. Its AccessKit layer already sets stable IDs (`author_id`; AT-SPI exposure unverified), selected state and row position. Missing are five roles (row, column header, menu, menu item, dialog) and their use in the standard widgets.
  - **Slint's biggest cost is the shell.** It has no layer-shell support, so the dock-taskbar, top bar and notifications need our own Wayland backend. That backend also gets no accessibility tree unless we port Slint's AccessKit adapter onto internal (`#[doc(hidden)]`) API.
  - **libcosmic's biggest cost is publishing the tree at all.** Today 26 of 26 controls are missing, in normal windows and shell surfaces alike, and upstream iced hasn't solved this since 2020. The work sits in a fork of a fork with no releases, plus a rework of the theme.
- **Performance on the NUC splits.** Slint wins on scrolling: 0 dropped frames against 69. libcosmic wins on start-up and memory: 49 ms and 34 MB against 185 ms and 154 MB. Everything is software-rendered. Slint's first launch after the compositor starts breached the budget (610 ms).
- **Memory matters most for the shell.** Every shell process would be a Slint client, and the idle desktop budget is 800 MB. The GPU condition therefore includes a memory limit for the shell.
- **Licence is the main policy cost of Slint.** Its royalty-free and commercial licences both forbid shipping a product that exposes Slint's API, and our SDK does that (C4, C12 "users build their own apps", Phase 4). **So every binary we distribute that links Slint is GPL-3.0-only: the shell, the native apps and the SDK.** Our own source files can still be MIT or Apache-2.0, and that choice decides whether proprietary third-party apps are possible ([3.5](#35-licence)). libcosmic (MPL-2.0) and iced (MIT) leave the licence open.

## 1. Context

D-006 (spec §5) chooses the one toolkit for the shell (C3) and the native apps (C5), built as C4. It is one of the Phase 0 gate decisions (§8), alongside D-007 (Decided) and D-008 (Open). The two candidates were each prototyped as the same Files app (#10, #11), measured the same way (#12), and extended by agents (#13), as set out in the brief.

These spec changes since the brief weigh on the decision:

- **§2 priority 1, performance and stability**, wins when priorities conflict. §7 budgets are release blockers.
- **§2 priority 4, AI integration**, and **§6 C12**: assistants operate apps through MCP. For apps without MCP they use the accessibility tree.
- **§6 C4**: "The accessibility tree is complete (every control has a role and name)". Accessibility gaps block release.
- **D-007 (Decided)**: we fork cosmic-comp for C2 only. C3–C5 are our own code on the D-006 toolkit, and we make no upstream contributions. Any toolkit gap is a patch we carry.
- **D-011 §5.2** turns "complete tree" into nine testable requirements, A1–A9.

## 2. Options

| | libcosmic | Slint |
| --- | --- | --- |
| What it is | System76's toolkit for COSMIC. It wraps a fork of iced (pop-os/iced) with COSMIC widgets, theme and application framework | A UI toolkit by SixtyFPS GmbH with its own markup language (`.slint`) compiled to Rust, and several renderers and backends |
| Version measured | git rev `daca62bb`, with pop-os/iced `229186b5` (brief §2) | 1.18.1 (2026-09-21), still the newest release today ([releases][slint-releases]) |
| Renderer measured | `iced_tiny_skia` on the CPU (the default build has no `wgpu`) | femtovg on OpenGL ES, which ran on Mesa llvmpipe in every environment |
| Licence | MPL-2.0 (libcosmic), MIT (pop-os/iced) | GPL-3.0-only, Royalty-free 2.0 or Software 3.0 (commercial), your choice ([LICENSE.md][slint-license]) |

Plain upstream iced isn't an option on its own: it has no AccessKit integration in 0.14.0 or on `master` (brief §2; D-007 §1.5). It returns only as a fallback in [section 6](#6-what-would-change-the-recommendation).

## 3. Results

### 3.1 Scoring table (brief §9)

Sources: **#12** = [`D-006-measurements.md`](D-006-measurements.md), NUC section unless marked VM or CI; **#13** = [`D-006-agent-test.md`](D-006-agent-test.md). Medians, with (min–max). Performance gates are **provisional**, because every number is software-rendered ([3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it)). ✅ pass, ❌ fail, ⚠️ pass with a caveat.

| Priority (§2) | Row | Kind | libcosmic | Slint |
| --- | --- | --- | --- | --- |
| 1 Performance and stability | M1 cold start ≤ 300 ms (warm cache, NUC) | Gate | ✅ 49.2 ms (48.1–65.8) | ⚠️ 184.5 ms (130.5–610.2). The first launch after compositor start breached at 610 ms (#12 footnote ¹). CI isn't counted (brief §6), but for context: there, first launches breached for both toolkits. libcosmic's took 2146 ms and 801 ms; Slint's took about 2 s, and two of them timed out at > 3000 ms on one runner |
| | M2 10k first paint ≤ 500 ms (NUC) | Gate | ✅ 76.5 ms (76.3–82.7) | ⚠️ 276.5 ms (236.4–638.5), with the same first-launch breach |
| | M3 idle RSS | Compare (but see the shell memory condition in [section 4](#4-recommendation)) | **33.7 MB** | 154.3 MB. Part of this is llvmpipe (LLVM loaded in-process). An in-process GPU driver (iris) also costs memory, so a GPU run won't remove all of it |
| | M4 idle CPU ≤ 1 % (300 s) | Gate | ✅ 0.00 % | ✅ 0.01 % |
| | M5 frame interval p50 / p95 / p99 while scrolling 10k (NUC) | Compare | 75.7 / 239.6 / 258.3 ms | **17.3 / 19.2 / 20.5 ms** |
| | M5 dropped frames per 10 s run (NUC) | Gate (§7) | ❌ **69** (64–74) on the default CPU renderer. `wgpu` not measured | ✅ **0** (0–1) |
| | Crashes or hangs in any run (#10–#13) | Gate (0) | ✅ 0, `a11y` on | ✅ 0 in final runs. One unexplained Wayland `Broken pipe` in a shared VM, not reproduced (#12 M1–M4) |
| 2 Design | Effort to implement design-system tokens | Compare | Higher: `cosmic-theme` encodes COSMIC's design. Our tokens mean reworking it and every widget's style (D-007 §2b), with merge pain if we follow upstream | Lower: tokens become a `global` singleton in `.slint`, and our components are our own `.slint` files. We write a component library either way; Slint's markup makes it data-like ([3.2](#32-c4-requirements-per-toolkit)) |
| 3 Familiar | Default widgets match platform conventions | Compare | Context menu opens on right-click only, with no arrow keys. The list takes no focus and shows no focus ring. Enter is delivered twice (#10 README) | Table draws no focus ring and reports no focus. The menu opens with no item highlighted. Shift+F10 only works on Windows. No double-click event (#11 README). Both needed workarounds; Slint's are smaller |
| 4 Integration | Fit for the shell (layer-shell, popups) | Compare | **Better**: layer-shell and Wayland popups through its `wayland` and `applet` features ([`Cargo.toml`][libcosmic-cargo]). This is proven in production by COSMIC's own panel and applets ([cosmic-panel][cosmic-panel], [cosmic-applets][cosmic-applets]). Those surfaces have no accessibility tree either (same A1 gap) | **Gap**: no layer-shell. The maintainers suggest apps send the protocol themselves on Slint's surface ([discussion #1765][slint-1765]). Third-party `layer-shika` is early ([lib.rs][layer-shika]). Needs our own backend, and that backend has no accessibility tree without more work ([3.4](#34-our-patches-the-gaps-as-patches-we-carry)) |
| | Fit with D-007 | Compare | cosmic-comp's own small UI (stack tabs, indicators) is drawn with libcosmic and would match without restyling (D-007 §5) | cosmic-comp's libcosmic UI has to be restyled or redrawn in our tokens. D-007 §6 says that's needed "whatever D-006 picks" |
| Accessibility (release blocker) | M6 controls missing a correct role or name, of 26 | Gate (0 with a fix path) | ❌ **26** missing (tree is one unnamed `frame`). Fix path: our patch, large ([3.4](#34-our-patches-the-gaps-as-patches-we-carry)) | ❌ **17** missing or wrong, 9 correct. Fix path: our patch, small |
| | M7 keyboard walkthrough, verified through AT-SPI, of 12 | Gate (12) | ❌ **0** verifiable. Behaviourally 12 of 12 in VM and CI. On the NUC, steps 8, 9 and 11 weren't reproduced (cause not established) | ❌ **6** fully + 2 partly verified, 4 not verifiable. Nothing failed. Behaviourally 12 of 12 everywhere, including the NUC |
| Agent productivity | M8 runs completed, of 3 | Compare | 0. Every run failed only check 7 (empty tree, inherited from the toolkit) | **3** |
| | Median wall time; compile-error iterations; wrong-API attempts | Compare | 6 m 54 s; 0, 1, 1; 0, 1, 0 | 6 m 31 s; 3, 2, 2; 1, 1, 1 (0 if Slint-language errors are excluded, #13 §6.8) |
| | Agent-ready docs (`llms.txt`, Markdown API) | Compare | None, none | `llms.txt` is a site index only; no Markdown API docs. Docs sources are MDX in the repository |
| | Headless screenshot testing (§6 C4) | Compare | `iced_test` (headless `Simulator`) exists in the pop-os/iced fork (`test/` at [`d5d638c3`][pop-iced-tree]) but isn't exposed by libcosmic. Not tried | **Built in**: a testing backend with element handles ([testing crate][slint-testing]), `slint-viewer --screenshot` (added in 1.17.0, [changelog][slint-changelog]), and an opt-in MCP introspection server with tree, actions and `take_screenshot` (`mcp` feature, [`mcp_server.rs`][slint-mcp]). Not tried |
| Cost and risk | M9 build time, stripped binary, crates, prototype lines (VM) | Compare | 181.8 s, 21.2 MB, 679, 560 | 129.4 s, 20.7 MB, 561, 495 |
| | Licence | Compare | MPL-2.0 + MIT: no constraint on our licence | GPL-3.0-only in practice for an OS with an SDK ([3.5](#35-licence)) |
| | Project health | Compare | No releases, no API stability, a fork of a fork ([3.6](#36-project-health)) | Regular releases from a funded company with two core maintainers ([3.6](#36-project-health)) |

**Gate summary.** libcosmic fails M5, M6 and M7. Slint fails M6 and M7, and its M1 and M2 pass only on the median, with a first-launch breach. The brief lets a candidate that fails a gate be recommended only with a credible fix path. Since we don't contribute upstream, the only fix path for either is our own patch, so [3.4](#34-our-patches-the-gaps-as-patches-we-carry) decides the accessibility gates. The GPU run in [3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it) decides the performance gates.

### 3.2 C4 requirements per toolkit

| §6 C4 requirement | libcosmic | Slint |
| --- | --- | --- |
| One toolkit for shell and apps | Yes: COSMIC uses it for both | Apps: yes. Shell: only with our own layer-shell backend and an accessibility port for it ([3.4](#34-our-patches-the-gaps-as-patches-we-carry)) |
| Implements every design-system component and token | Through `cosmic-theme`, which has COSMIC's own structure. Every widget's style needs rework | Tokens as `.slint` globals; the components are our own `.slint` library. Slint's shipped styles (fluent, material, cupertino, cosmic) are references, not something to theme |
| AccessKit: screen reader, keyboard, high contrast | AccessKit linked, tree never published. Keyboard works through app code only. High contrast not checked | AccessKit tree published and focus state correct. Keyboard works with workarounds. High contrast not checked |
| Complete tree (every control has a role and name) | No: 26 of 26 missing | No: 17 of 26 wrong or missing, because five roles don't exist ([`enums.rs` at v1.18.1][slint-enums]; still absent on `master` today, [`enums.rs` at master][slint-enums-master]) |
| llms.txt, Markdown API docs, a runnable example per widget | None. 14 examples for 52 widgets (D-007 §4) | Partial `llms.txt`, no Markdown API. Per-widget examples exist in its docs. We'd write C4's own agent docs either way, since C4's API is ours |
| Headless inspection and screenshot harness | Possible at the iced layer (`iced_test`); needs wiring into libcosmic | Testing backend, `slint-viewer --screenshot` and the MCP introspection server are there. **The MCP server is a dev and test tool only.** It opens an HTTP port that bypasses the permission broker (D-011 §6.3), so it must never be on in shipped builds |
| Matching GTK and Qt themes | `cosmic-theme` already exports to GTK 4 and Qt with COSMIC's values (D-007 §4). It's a starting point for a generator from our tokens | Nothing. We write the token → GTK CSS and Qt palette generator ourselves. It's toolkit-independent work, so libcosmic only saves the start |

### 3.3 Software rendering: how much the recommendation depends on it

**What was measured.** Every number above is software-rendered. Sway ran headless with pixman. libcosmic drew with `iced_tiny_skia` on the CPU. Slint drew with femtovg on OpenGL ES, which ran on Mesa **llvmpipe** (#12, the NUC's `egl:` line). The N5105's GPU was used nowhere.

**What a GPU would change.** This is our expectation, not a measurement:

- **libcosmic.** The default build has no GPU path, so its 69 dropped frames are what the default build does. COSMIC Files ships with the `wgpu` feature on (D-007 §1.5). With `wgpu`, scrolling could pass, but start-up time and RSS would probably rise (GPU device set-up, shader compilation, driver memory). Neither direction is measured.
- **Slint.** Its M1 first-launch breach, part of its 154 MB RSS, and its CI timeouts are plausibly llvmpipe's cost: LLVM is loaded and shaders are JIT-compiled in-process (#12 Limitations). A hardware driver doesn't pay that, so a GPU run would likely improve M1 and M3 and keep M5. Also unmeasured.

**How much the recommendation depends on it.** The recommendation rests on [3.4](#34-our-patches-the-gaps-as-patches-we-carry) to [3.7](#37-fit-with-d-007): the patch cost, project health and fit with D-007. A GPU run changes it only in two cases:

1. **Slint fails one of the gates G1–G5** in [4.1](#41-the-gpu-gates-exact). Then the recommendation goes to libcosmic if libcosmic passes them, or to no recommendation if both fail ([4.2](#42-outcomes)).
2. **libcosmic with `wgpu` passes G1–G5 too.** That removes libcosmic's performance fail. It doesn't remove the accessibility patch, the fork-of-a-fork cost or the theme rework. [4.2](#42-outcomes) says why Slint still stands then, and the one exception.

**So yes: measure on the GPU before deciding.** Priority 1 is the tie-breaker, both candidates' performance gates are provisional, and the run is cheap. The pass and fail rules are in [section 4](#4-recommendation). Run four variants in the same run:

- libcosmic, default build (CPU, as before);
- libcosmic `--features wgpu`;
- Slint, default build (femtovg on GL);
- Slint with its own software renderer (`SLINT_BACKEND=winit-software`, or the `renderer-software` feature).

The last variant has no Mesa in the process, so it separates llvmpipe's share of Slint's memory and start-up from Slint's own. It's also a possible renderer for small shell surfaces. Its `BUDGET_FIRST_FRAME` hook needs another trigger, because the current rendering notifier isn't supported there (#11 README); the builder card picks one and documents it.

#### Work for a builder card first (not the owner)

The current workflow can't measure the GPU as it stands. A new card (the planner files it) changes `tools/d006/measure.sh` and `d006-measure.yml`:

1. **Renderer setting.** Sway uses `WLR_RENDERER=gles2` with `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128`, set explicitly rather than left to wlroots' automatic choice. Pixman stays the default when no flag is set.
2. **Proof of which renderer the apps used.** `environment.txt` must show what the *apps* got, not what the machine has:
   - **GL renderer:** the `egl:` line comes only from the `Wayland platform:` block of `eglinfo -B` output, taken while sway runs (or `eglinfo -B -p wayland`, if the installed `mesa-utils` supports `-p`). Today's line reads every platform, and the GBM and device platforms will report `iris` whatever sway does.
   - **Per app:** each prototype logs its renderer once at start-up: the GL renderer string for Slint's femtovg, the wgpu adapter name and backend for libcosmic `wgpu`.

   A run counts as a GPU run only if both name the Intel driver (`iris` for GL, an Intel adapter on the Vulkan backend for wgpu), not `llvmpipe` or `lavapipe`. If wgpu falls back to GL or lavapipe, the libcosmic `wgpu` result is recorded as not measured.
3. **The four variants above**, built on the hosted runner as today.
4. **A mode that uses an already running compositor**, for option B: `D006_COMPOSITOR=existing` skips starting sway and uses the current `WAYLAND_DISPLAY` and `SWAYSOCK`. Without it, `measure.sh` would start a nested headless pixman sway and measure software rendering again.

#### What the owner does

The runner today is an unprivileged service user with no seat, which is why sway ran headless with pixman (#12 deviation 1). Option A gives that user access to the GPU's render node and nothing more. It needs no login at the screen.

**Option A (recommended).** On the NUC, logged in as the owner (console or SSH). Do this while no job is running, since step 3 restarts the runner.

1. Check whether the Vulkan driver is already there. If `dpkg -s` prints `Status: install ok installed`, skip step 2 and step 2 of the undo.

   ```sh
   dpkg -s mesa-vulkan-drivers 2>/dev/null | grep '^Status' || echo "not installed"
   ```

2. Install the Intel Vulkan driver (for libcosmic's `wgpu` build). Note the "NEW packages" line apt prints, for the undo.

   ```sh
   sudo apt-get install -y --no-install-recommends mesa-vulkan-drivers
   ```

3. Let the runner open the GPU's render node, and restart the runner so it picks this up:

   ```sh
   sudo usermod -aG render runner
   sudo systemctl restart 'actions.runner.*'
   ```

4. Check:

   ```sh
   ls -l /dev/dri/renderD128                       # crw-rw---- root render
   ps -o user=,supgrp= -C Runner.Listener          # runner  runner,render
   ```

What this changes: one group membership (render nodes allow GPU rendering and compute only, not display or input), and one driver package. No service, port, sudo right or persistent setting is added.

Then the agent starts the run with `gh workflow run d006-measure.yml -f nuc=true` once the card above is merged, and the owner undoes the change. **Undo** (same session):

```sh
sudo gpasswd -d runner render
sudo systemctl restart 'actions.runner.*'
ps -o user=,supgrp= -C Runner.Listener                    # runner  runner (no render)
sudo apt-get remove -y mesa-vulkan-drivers                # only if step 2 installed it
```

If step 2's "NEW packages" line listed more than `mesa-vulkan-drivers`, remove those too by name. Don't use `apt-get autoremove` blindly; it may remove packages that other steps installed.

If the run's renderer lines still say `llvmpipe` (meaning headless sway didn't hand the GPU to its clients), use option B. That wlroots picks the render node in headless mode is expected but **unverified on the NUC**.

**Option B (fallback): a real display, as the owner, without touching the runner.** This needs a monitor and keyboard on the NUC. It runs entirely in the owner's own session, with no root.

1. On another machine, download the GPU run's artifact (the hosted `build` job's binaries and scripts) from the workflow run page. Copy it to the NUC as `~/d006.tar.gz`.
2. Log in on the NUC's console (tty1) as the owner. The login gives a logind seat, so sway can open the display.
3. Unpack it and start sway with the config the card provides:

   ```sh
   mkdir ~/d006 && tar -xzf ~/d006.tar.gz -C ~/d006 && cd ~/d006 && sway -c tools/d006/sway-drm.conf
   ```

   The card writes `tools/d006/sway-drm.conf` with the brief's floating rule, the real output at its native mode, and one line `exec sh -c 'D006_COMPOSITOR=existing tools/d006/measure.sh ./d006-iced ./d006-slint ./budgets ./out-gpu; swaymsg exit'`. In a sway config, two separate `exec` lines would start at the same time, so `swaymsg exit` would quit sway immediately.
4. Leave the machine alone until sway exits by itself (about 2 h for four variants with five 5-minute idle windows each). Then copy `~/d006/out-gpu` off the machine for the card.

**Undo:** `rm -rf ~/d006 ~/d006.tar.gz`. Nothing else changed.

### 3.4 Our patches: the gaps as patches we carry

Neither toolkit's upstream will take our fixes (no upstream contributions; COSMIC also bans LLM content, D-007 §1.3). Each gap is a downstream patch we rebase for as long as we follow upstream. Estimates are in **builder cards** (one agent session each, spec §9) and rough added lines. They are judgements from reading the code at the revisions linked, not measurements. The ranges are wide on purpose.

The rows are the D-011 §5.2 requirements A1–A9, plus the C3 and C4 gaps found in the prototypes.

| Gap | libcosmic patch | Est. | Slint patch | Est. |
| --- | --- | --- | --- | --- |
| A1 tree published | In pop-os/iced `winit/`: build `TreeUpdate`s from `UserInterface::a11y_nodes()` on every UI change, route AccessKit action requests back to widgets, and handle every Wayland surface (popups, layer surfaces). Upstream iced has tried since 2020 ([#552][iced-552], draft [#3111][iced-3111]); the author will do it himself ([#3281][iced-3281]) | 4–8 cards, 1–2k lines, **high uncertainty**. Covers app windows and layer surfaces together, because both go through the same `winit/` and `platform_specific` code | **Works for winit windows only** (app windows and their popups). Slint's AccessKit integration lives in the winit backend ([`accesskit.rs`][slint-accesskit]). Shell surfaces from our own backend get no tree: see the row "Accessibility of shell surfaces" | 0 for apps |
| A2 roles | Add roles and `a11y_nodes` to list, table, row, column header, menu, menu item, dialog, `text_input` ([libcosmic#1429][lc-1429]) and tab bar; make the list focusable | 4–8 cards, 1.5–3k lines | Add `Row`, `ColumnHeader`, `Menu`, `MenuItem`, `Dialog` to `AccessibleRole` ([`enums.rs`][slint-enums]) and map them in [`accesskit.rs`][slint-accesskit]. Set them in `StandardTableView`, `ContextMenuArea` and the dialog | 2–3 cards, 200–500 lines |
| A3 states (selected and others) | Wire selected and expanded states per widget | in A2 | Plumbing exists (`set_selected` from `accessible-item-selected`, [`accesskit.rs`][slint-accesskit] L890–898). Set it on table rows | in A2 |
| A4 semantic actions | Part of the A1 routing | in A1 | AccessKit actions are mapped (`Click`, `Focus`, `SetValue`, `ReplaceSelectedText` and more). Check per widget, especially `ScrollIntoView` and `ShowContextMenu` | 1 card (check and fill) |
| A5 virtualised list addressable | Row index and count on the fork's `list` | in A2 | `set_position_in_set` and `set_size_of_set` exist (L900–911). Make `ListView` and `StandardTableView` set them for non-instantiated rows | 1 card |
| A6 popups belong to their app | Per-surface adapters with parent relation | in A1 | Popup shows as a separate unnamed `frame`. Name it and give it the menu or dialog role. A parent relation across Wayland surfaces may be limited by AT-SPI | 1–2 cards, uncertain |
| A7 stable IDs | Not checked; nothing seen that sets `author_id` | 1–2 cards | `set_author_id` from the element's accessible ID exists (L794–796). Whether Slint 1.18.1's AccessKit version (`accesskit` 0.24, `accesskit_winit` 0.33) exposes it as AT-SPI `AccessibleId` is **unverified** (D-011 A7). Make our components always set it, and check the exposure | 0–1 card |
| A8 tree on within budget | Measure after A1 | 1 card | Measure | 1 card |
| A9 password fields | `text_input` needs a node first | in A2 | `PasswordInput` role exists (L709) | 0 |
| Clipboard | Exists | 0 | No public API ([#2570][slint-2570], open). Expose the backend's clipboard, or keep the hidden-`TextInput` workaround from #11 | 1 card |
| Keyboard behaviour (menus, focus rings) | `context_menu` has no arrow keys. List focus ring | 1–2 cards | Menu initial highlight, Shift+F10, table focus ring, double-click | 1–2 cards (or in our own components) |
| Shell surfaces (C3) | Exists (`wayland` feature) | 0 | **Own backend or a winit-backend patch** for `zwlr_layer_shell_v1` and shell popups, through Slint's public `slint::platform` API with smithay-client-toolkit and femtovg or Skia. Reference: `layer-shika` ([lib.rs][layer-shika]) | 4–8 cards, 1.5–3k lines, **high uncertainty** |
| Accessibility of shell surfaces (C4 complete tree, C12 fallback) | In A1 (same code path) | 0 extra | Our layer-shell backend needs its own AccessKit adapter (`accesskit_unix` directly, since there's no winit window). That means porting Slint's ~1,000-line `accesskit.rs` to our backend. The hooks it needs (`WindowAdapterInternal`, including `handle_focus_change`, [`window.rs` at v1.18.1][slint-window] L220–264) are `#[doc(hidden)]`, not public `slint::platform` API, and the item tree it walks is in the internal `i-slint-core` crate. The alternative, layer-shell inside winit and Slint's winit backend, means forking winit too, so it's not proposed | 2–4 cards, 1–1.5k lines (mostly a port), **high uncertainty** |
| Scrolling | Turn on `wgpu` (configuration), pending the GPU run | 0 + measure | Passes | 0 |
| Design tokens | Rework `cosmic-theme` and every widget's style. This conflicts with most upstream merges | 4–8 cards | Our own `.slint` component library (needed with either toolkit, so not counted) | 0 extra |

**Totals (initial), summing the rows above:**

- **libcosmic: about 15–29 cards.** A1 4–8, A2 4–8, A7 1–2, A8 1, keyboard 1–2, design tokens 4–8. Of these, 11–21 are accessibility and keyboard work.
- **Slint: about 14–24 cards.** In-app accessibility 6–9 (A2 2–3, A4 1, A5 1, A6 1–2, A7 0–1, A8 1), clipboard 1, keyboard 1–2, layer-shell backend 4–8, accessibility of shell surfaces 2–4.

**The totals overlap, so cost alone doesn't decide.** The difference is risk and location:

- **Slint's large items** (layer-shell backend, shell-surface accessibility) are mostly new code of ours, built on Slint's public and internal APIs. Its patches inside Slint (roles, widgets) are small.
- **libcosmic's large items** (A1 tree publication, token rework) are patches inside two upstream repositories that change daily. A1 is a problem upstream iced hasn't solved since 2020.

Each toolkit has high-uncertainty items: A1 for libcosmic, and the layer-shell backend plus its accessibility port for Slint.

**Carrying cost (ongoing):**

- **libcosmic:** two repositories with no releases and no API stability. libcosmic `master` had 109 commits in 90 days (D-007 §1.2). pop-os/iced has 31 commits in the 90 days to today and is 685 commits behind upstream iced. The A1 patch sits in `winit/src/lib.rs`, a hot file. The token rework touches most widgets. Following upstream means a rebase of large patches against daily changes. Freezing the fork means owning roughly 1.9 MB of libcosmic Rust plus the iced fork outright. **Either way this is a toolkit we maintain.**
- **Slint:** one repository with versioned releases (every one to four months, [3.6](#36-project-health)). Our patches touch `enums.rs`, `accesskit.rs` and a few `std-widgets` files, which change in some releases (1.18.0 and 1.18.1 changed accessibility code, per the [changelog][slint-changelog]). The layer-shell backend uses public `slint::platform` API for windows and rendering. But its accessibility port uses doc-hidden `WindowAdapterInternal` and internal `i-slint-core` items, which carry no semver promise (the testing crate likewise pins `=x.y.z`). **So the backend must be rechecked, and often adapted, on every Slint release, minor or patch.** Expect a few hours to a day per minor release, more when Slint changes its accessibility internals (as it did in 1.18.0). **That's an estimate; measure it on the first rebase**, as D-007 §6 asks for cosmic-comp.

### 3.5 Licence

| | libcosmic | iced (pop-os fork and upstream) | Slint |
| --- | --- | --- | --- |
| Licence | MPL-2.0 ([LICENSE][libcosmic-license]) | MIT ([LICENSE][iced-license]) | GPL-3.0-only **or** Royalty-free 2.0 **or** Software 3.0, at our choice ([LICENSE.md][slint-license]) |
| Effect on our code | File-level copyleft: modified libcosmic files stay MPL-2.0 and their source must be published. Our own files may use any licence | None beyond the notice | Depends on the option (below) |

**Slint's three options against an OS:**

- **Royalty-free 2.0** ([text][slint-rf]): allows use in a Desktop, Mobile or Web Application, modified or not, with attribution (the `AboutSlint` widget in an About screen, or a badge on the download page). It excludes embedded systems, and **"You may not distribute an Application that exposes Slint's APIs"** (paraphrase of §3; the text says "exposes the APIs, in whole or in part"). An OS whose SDK (C4, Phase 4) and "build your own app" flow (C12) hand Slint's API to other developers exposes it. Slint's [LICENSE.md][slint-license] also says the Royalty-free licence is meant for applications "installed as one application among many". A desktop shell isn't that. **Not usable for Atos** as specified.
- **Software 3.0, commercial** ([text][slint-sw], [pricing][slint-pricing]): paid per developer seat (every person designing, developing or testing), subscription-based, with a perpetual fallback only after 12 paid months. It has **the same ban on distributing an application that exposes the APIs** (§3). Agents as "seats" is undefined. **Not usable as written** for an SDK. A custom licence negotiated with SixtyFPS might be; that's an owner question, not an upstream contribution.
- **GPL-3.0-only** ([text][slint-gpl]): works for an OS with an SDK. Since Rust links statically, **every binary we distribute that links Slint (shell, native apps, SDK examples) is conveyed under GPL-3.0-only**, with source. Our own source files may carry a GPL-compatible permissive licence (Slint's [LICENSE.md][slint-license]: "your own files can stay MIT or Apache-2.0"), but the shipped binaries are GPL-3.0.

**What this means for the owner's decisions:**

- **Our own source licence decides whether proprietary third-party apps are possible. This is the real decision.** A third party can build a proprietary native app on our SDK only if C4's own source is permissive (MIT or Apache-2.0) and they take Slint's Royalty-free licence (free, with the About-Slint attribution) or a commercial licence for their app. If C4's own source is GPL, proprietary native apps on our SDK are impossible. GPL-3.0 apps work either way. Flatpak apps on other toolkits (GTK, Qt, Electron) aren't affected.
- **Extensions (C8, Phase 4).** C8 says extensions run out of process or in WASM. Out-of-process extensions talking over a protocol aren't derivative works. But an extension loaded into the GPL-3.0 shell process would in practice have to be GPL-compatible. That supports C8's out-of-process rule rather than conflicting with it.
- **Apps users build with an assistant (C12)** aren't distributed while they stay on the user's machine, so no obligation applies. Once a user shares one, it needs GPL-3.0 or the user's own Slint Royalty-free licence.
- **Ownership (§2 priority 6).** GPL-3.0's installation-information clause (§6 of the licence) requires that users of a device we ship can install modified versions. That supports "fully owned by its user" and the developer mode (C1); it doesn't conflict with it.

**Against what the owner already accepts:** C2 is GPL-3.0-only (D-007), so the clause above already applies to the image wherever C2 does. Slint under GPL-3.0 extends the same licence from C2 to the C3–C5 and SDK binaries; it adds no new kind of obligation. It does decide the licence of most shipped binaries, while the project licence is still open. With libcosmic, the project licence stays free: MPL-2.0 for modified libcosmic files, anything for ours.

### 3.6 Project health

Checked today with the GitHub API ([Sources](#sources)). "Last 52 weeks" is commits by author on the default branch.

| | libcosmic + pop-os/iced | Slint |
| --- | --- | --- |
| Owner | System76 (COSMIC desktop, Pop!_OS) | SixtyFPS GmbH, which sells Slint licences |
| Releases | **None.** libcosmic isn't on crates.io; last tag `v0.12` (2024-10-16). Apps track git `master`. COSMIC Epoch releases tag apps, not a libcosmic API (D-007 §1.2) | **Versioned releases**: 1.13.0 (2025-09-03), 1.14.0 (2025-10-21), 1.15.0 (2026-02-04), 1.16.0 (2026-04-16), 1.17.0 (2026-06-24), 1.18.0 (2026-09-16), each followed by a patch release ([releases][slint-releases]). Six minor releases in 13 months, gaps of 1.5 to 3.5 months |
| Activity | libcosmic: 109 commits in 90 days, last commit 2026-11-05. pop-os/iced: 31 in 90 days | 100+ commits in 90 days (API page limit) |
| Maintainers, last 52 weeks | libcosmic: wash2 149, hojjatabdollahi 86, mmstick 59, git-f0x 47. pop-os/iced: hecrj 142 (merged upstream work), wash2 74, hojjatabdollahi 42 | tronical (Simon Hausmann) 1,479, ogoffart (Olivier Goffart) 1,399, LeonMatthes 386, dfaure-kdab 332, NigelBreslaw 252, 0x6e 227 |
| Bus factor | About 2–3 active developers per repository, employed by one company. The iced fork depends on one System76 developer (wash2) for rebases on upstream iced, which itself depends on one author (hecrj: 638 of the top-6 contributors' 700 upstream commits in 52 weeks) | Two founders write most of the code; a wider group of 4+ contribute steadily. Company-funded. If SixtyFPS stopped, the GPL-3.0 code stays forkable, but nobody else maintains it |
| API stability | None (git `master`) | Semver within 1.x. Some APIs are marked unstable (`unstable-wgpu-*`, the testing crate pins `=x.y.z`) |
| Upstream policy for us | Moot (we don't contribute). COSMIC bans LLM content (D-007 §1.3) | Moot. Contributions are licensed as MIT-0, with no CLA ([CONTRIBUTING.md][slint-contributing]) |

### 3.7 Fit with D-007

D-007 forks **only cosmic-comp**. C3–C5 are our own code.

- **With Slint:** libcosmic stays only inside the cosmic-comp fork, for its few internal visuals (stack tabs, indicators), which we restyle or redraw anyway (D-007 §6). The C3–C5 code and the compositor's UI use different toolkits. That's acceptable because the compositor's UI is small and not part of C4. Licence: C2 is GPL-3.0-only and Slint would be GPL-3.0-only, so one licence for the whole graphical stack.
- **With libcosmic:** C3–C5 and the compositor's UI share one toolkit, which is a real but small saving. But it brings back the libcosmic and pop-os/iced forks that D-007 chose not to take for C3–C5. The cost D-007 §2b called "the most expensive per benefit" comes back through D-006, together with the accessibility patch.

Slint fits D-007's narrow fork better: one forked upstream (cosmic-comp) instead of three.

## 4. Recommendation

**Flag for the owner: this is a recommendation, not a decision.**

**Choose Slint as the D-006 toolkit, with its binaries under GPL-3.0-only, if the GPU run ([3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it)) passes the gates below.**

### 4.1 The GPU gates (exact)

These apply to every toolkit variant in the GPU run, and only to a run whose renderer lines show the Intel driver ([3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it)). Each variant gets 5 runs, as in the brief.

| Gate | Pass when | Why this rule |
| --- | --- | --- |
| G1 cold start | **Every one** of the 5 M1 launches ≤ 300 ms, including the first launch after the compositor starts | The first launch after login is a real user case. A median hides exactly the breach we saw |
| G2 10k first paint | **Every one** of the 5 M2 launches ≤ 500 ms | Same |
| G3 idle CPU | Median M4 ≤ 1 % | As in the brief |
| G4 scrolling | Dropped frames (interval > 25 ms at 60 Hz): **median 0 per run, and no run above 1** | §7 says "no dropped frames". One isolated interval in one of five 10 s runs is treated as noise to investigate, not a fail. Slint's software run already had 0 (0–1). Two or more in any run is a fail |
| G5 shell memory | **N × M3 ≤ 300 MB**, where M3 is the median idle RSS of one process of that variant, and N is the number of toolkit processes the shell runs at idle | §7's 800 MB is the idle desktop after login: compositor, shell and system services, with no apps open. Every shell process is a client of this toolkit. 300 MB is a **proposed** share for the shell, leaving 500 MB for the compositor, the system and headroom. The owner confirms or changes it ([section 7](#7-open-questions)) |

**N for G5.** With N = 1 (the dock-taskbar, top bar, launcher, control centre and notifications as surfaces of one shell process), Slint passes if one process idles at ≤ 300 MB. Its software-rendered 154 MB already does. With N = 5 separate processes, Slint needs ≤ 60 MB each, which only its software renderer or a much smaller GPU footprint could reach. **The recommendation therefore assumes a single-process shell for C3** (a design consequence, [section 5](#5-consequences)), unless the GPU run shows Slint at ≤ 60 MB.

### 4.2 Outcomes

- **Slint passes G1–G5:** recommend Slint, as below.
- **Slint fails any gate, and libcosmic `wgpu` (or default) passes G1–G5:** recommend libcosmic. Priority 1 decides, and the accessibility patch is then the price.
- **Both pass, and libcosmic keeps a large lead on M1 and M3:** **Slint still stands.** Once both pass the §7 gates, priority 1 is met by both, and M1 and M3 are comparison rows, not gates. What then separates them is the accessibility release blocker and its fix risk ([3.4](#34-our-patches-the-gaps-as-patches-we-carry)). The totals are similar, but libcosmic's largest item (A1) is a problem upstream iced hasn't solved since 2020, inside a fork of a fork. Slint's (the layer-shell backend and its accessibility port) is new code of ours. **Exception:** if the owner sets G5's share below what Slint reaches with N = 1, libcosmic wins on G5 and the recommendation flips.
- **Both fail a gate:** no recommendation. D-006 stays open. The next steps are a profile of the failing gate for each toolkit, the Slint software-renderer variant's result, and the owner's choice whether to add a third candidate (brief §1).

### 4.3 Why Slint, in the §2 order

1. **Performance and stability.** Slint is the only candidate whose scrolling passes on the NUC today (0 dropped frames, p99 20.5 ms). libcosmic starts faster and uses less memory. Slint's first-launch breach and its memory are the open risks; G1 and G5 settle them. libcosmic's scrolling depends on an unmeasured `wgpu` build. No crashes in either.
2. **Design.** Our design system needs our own components with either toolkit. Slint's markup and globals make tokens straightforward. libcosmic's `cosmic-theme` must be reworked.
3. **Accessibility (release blocker) and AI integration (priority 4).** The accessibility tree is the assistants' fallback (C12).
   - **Slint** publishes a tree for app windows today. Its AccessKit layer already sets `author_id`, selected state and row positions (AT-SPI exposure of `author_id` unverified). Missing are five roles, their use in widgets, and a tree for our future shell surfaces.
   - **libcosmic** publishes nothing. Fixing it means writing the AccessKit integration that upstream iced hasn't finished in six years, inside a fork of a fork.
   - **Agents** did fine with Slint: 3 of 3 runs completed against 0 of 3.
4. **Integration and maintenance.** Slint has versioned releases from a funded company. libcosmic has none, so following it means rebasing large patches against daily upstream changes. Slint keeps D-007's fork count at one. libcosmic's real advantage here is a proven layer-shell path for the shell.

What it costs (accept these knowingly):

- **GPL-3.0-only for the C3–C5 and SDK binaries.** Whether proprietary third-party apps are possible then depends on our own source licence ([3.5](#35-licence)).
- **A layer-shell backend of our own, with an accessibility port on internal Slint API,** before any shell work. About 6–12 cards, high uncertainty, rechecked on every Slint release.
- **Our own Slint patch set** for roles, widget accessibility, keyboard and clipboard (about 8–12 cards), rebased on each Slint release.
- **A single-process shell** (G5 with N = 1), unless the GPU run shows a much smaller footprint.

If the owner doesn't accept GPL-3.0 for these binaries, the recommendation flips ([section 6](#6-what-would-change-the-recommendation)).

## 5. Consequences

If the owner accepts the recommendation:

- **D-006** becomes "Slint (GPL-3.0-only) as the C4 toolkit; accessibility, clipboard and layer-shell gaps carried as our patches". The owner edits the log; this card doesn't.
- **Before the decision is final:** the planner files the GPU-run card ([3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it), "Work for a builder card first"). After it merges, the owner runs option A and undoes it after the run. The same run can measure A8 (the tree on during M1–M5, D-011 §9).
- **Project licence:** the owner decides whether GPL-3.0-only is acceptable for the C3–C5 and SDK binaries, and which licence our own source files carry. The second decides whether proprietary third-party apps are possible ([3.5](#35-licence)).
- **Shell architecture:** C3 is planned as one shell process with several layer surfaces (G5 with N = 1). The spec doesn't say this; it's for the owner to confirm.
- **New cards for the planner (Phase 1, not created here):**
  - the Slint fork set-up: pinned release, patch queue, and a rebase routine whose first run records its effort;
  - accessibility roles and widget fixes (A2–A7);
  - a clipboard API;
  - a layer-shell backend spike for the dock-taskbar, **including its AccessKit port**, measured against G5 and the C3 popover budget;
  - a token → `.slint` globals generator;
  - a token → GTK/Qt theme generator;
  - a C4 headless test harness on Slint's testing backend;
  - a CI check that the `mcp` introspection feature is never in release builds.
- **Docs:** `docs/components/c4-toolkit/` records the Slint version, licence choice and every downstream patch.
- **Spikes:** `spikes/d006-iced/` and `spikes/d006-slint/` stay as throwaway code (brief §4).

If the owner picks libcosmic instead, the first cards are:

- the `wgpu` measurement;
- the A1 tree publication patch in pop-os/iced, covering app windows and layer surfaces, with a spike first given the uncertainty;
- a decision whether to follow upstream or freeze the fork.

libcosmic's shell path itself is proven by COSMIC's panel and applets.

## 6. What would change the recommendation

| If… | Then |
| --- | --- |
| Slint fails any of G1–G5 in the GPU run ([4.1](#41-the-gpu-gates-exact)) and libcosmic (`wgpu` or default) passes them all | **libcosmic** |
| Both fail a gate | No recommendation; D-006 stays open ([4.2](#42-outcomes)) |
| Both pass G1–G5, and libcosmic leads on M1 and M3 | **No flip**: priority 1 is met by both, and the accessibility fix risk decides ([4.2](#42-outcomes)). A flip only if the owner sets G5's shell share below what Slint reaches |
| The owner doesn't want a single-process shell, and the GPU run shows Slint above 300 MB ÷ N per process | **libcosmic** on G5 |
| The owner doesn't accept GPL-3.0-only for C3–C5 and the SDK, and SixtyFPS offers no licence that allows an SDK | **libcosmic** (MPL-2.0), or plain iced with our own AccessKit integration if the libcosmic fork cost is judged too high |
| A layer-shell spike on Slint (with its AccessKit port) takes far beyond 12 cards, can't publish a complete tree for shell surfaces, or can't meet the C3 popover budget (≤ 100 ms) | Reopen: one toolkit for shell and apps, with a complete tree, is a C4 requirement |
| Upstream iced releases AccessKit integration ([#3111][iced-3111] or the author's own) | Plain iced (MIT, releases, no COSMIC fork) becomes a third candidate worth a prototype |
| Slint adds the missing roles or layer-shell upstream | Slint's patch set shrinks; no change in direction |
| SixtyFPS changes Slint's licence or stops development | GPL-3.0 releases stay usable and forkable, but we'd own the toolkit. Reassess |
| A8 shows the tree costs either toolkit its budgets when assistants are on | Reopen for that toolkit |
| The owner wants different weights than §2's order (for example memory over scrolling) | libcosmic's start-up and RSS lead counts more |

## 7. Open questions

For the owner (also posted on #14):

1. **GPU run first?** Will the owner run option A in [3.3](#33-software-rendering-how-much-the-recommendation-depends-on-it) (a driver package and a group membership, both undone after the run) before deciding? This write-up recommends it.
2. **Binary licence.** Is GPL-3.0-only acceptable for the shipped C3, C4 and C5 binaries and the SDK, which is what Slint requires for an OS that exposes its API? If not, should we ask SixtyFPS about a custom licence (a vendor contact, not an upstream contribution), or go with libcosmic?
3. **Our own source licence, which decides whether proprietary apps are possible.** If C4's own source is MIT or Apache-2.0, third parties can ship proprietary native apps under Slint's Royalty-free or commercial licence. If it's GPL, only GPL-compatible native apps are possible. Which does the owner want for the Phase 4 public SDK?
4. **Shell memory and architecture.** Is 300 MB the right share of the 800 MB idle budget for the shell (G5)? And is a single-process shell (one process, several layer surfaces) acceptable as a C3 design rule?

## Sources

All opened 2026-11-05.

- Slint: [releases][slint-releases] (1.18.1 newest; dates above) · [LICENSE.md][slint-license] · [Royalty-free 2.0][slint-rf] · [Software 3.0][slint-sw] · [GPL-3.0-only][slint-gpl] · [pricing][slint-pricing] · [`AccessibleRole` at v1.18.1][slint-enums] and [at master `d7fbf113`][slint-enums-master] · [`accesskit.rs` at v1.18.1][slint-accesskit] · [testing backend][slint-testing] · [`mcp_server.rs`][slint-mcp] · [clipboard API issue #2570][slint-2570] · [layer-shell discussion #1765][slint-1765] · [`layer-shika`][layer-shika] · [CHANGELOG at v1.18.1][slint-changelog] · [`window.rs` at v1.18.1][slint-window] (`WindowAdapterInternal`, `#[doc(hidden)]`) · [winit backend `Cargo.toml` at v1.18.1](https://github.com/slint-ui/slint/blob/v1.18.1/internal/backends/winit/Cargo.toml) (`accesskit` 0.24, `accesskit_winit` 0.33, only in this backend) · [CONTRIBUTING.md][slint-contributing] (MIT-0) · contributors: GitHub API `repos/slint-ui/slint/stats/contributors`
- libcosmic and iced: [libcosmic `Cargo.toml`][libcosmic-cargo] (`wgpu`, `wayland`, `a11y` features) · [libcosmic LICENSE][libcosmic-license] · [pop-os/iced tree at `d5d638c3`][pop-iced-tree] (`test/`, `accessibility/`) · [iced LICENSE][iced-license] · [iced releases][iced-releases] (0.14.0 on 2025-12-07, 0.13.0 on 2024-09-18) · [iced#552][iced-552] · [iced#3111][iced-3111] · [iced#3281][iced-3281] · [libcosmic#1429][lc-1429] · [cosmic-panel][cosmic-panel] and [cosmic-applets][cosmic-applets] (layer-shell in production) · contributors: GitHub API `repos/{pop-os/libcosmic,pop-os/iced,iced-rs/iced}/stats/contributors`; commit counts: `commits?since=2026-08-05`
- Project inputs: #9, #10, #11, #12, #13, #3, #31 (files linked at the top)

[slint-releases]: https://github.com/slint-ui/slint/releases
[slint-license]: https://github.com/slint-ui/slint/blob/master/LICENSE.md
[slint-rf]: https://github.com/slint-ui/slint/blob/master/LICENSES/LicenseRef-Slint-Royalty-free-2.0.md
[slint-sw]: https://github.com/slint-ui/slint/blob/master/LICENSES/LicenseRef-Slint-Software-3.0.md
[slint-gpl]: https://github.com/slint-ui/slint/blob/master/LICENSES/GPL-3.0-only.txt
[slint-pricing]: https://slint.dev/pricing
[slint-enums]: https://github.com/slint-ui/slint/blob/v1.18.1/internal/common/enums.rs
[slint-enums-master]: https://github.com/slint-ui/slint/blob/d7fbf113/internal/common/enums.rs
[slint-accesskit]: https://github.com/slint-ui/slint/blob/v1.18.1/internal/backends/winit/accesskit.rs
[slint-testing]: https://github.com/slint-ui/slint/tree/v1.18.1/internal/backends/testing
[slint-mcp]: https://github.com/slint-ui/slint/blob/v1.18.1/internal/backends/testing/mcp_server.rs
[slint-2570]: https://github.com/slint-ui/slint/issues/2570
[slint-1765]: https://github.com/slint-ui/slint/discussions/1765
[slint-changelog]: https://github.com/slint-ui/slint/blob/v1.18.1/CHANGELOG.md
[slint-window]: https://github.com/slint-ui/slint/blob/v1.18.1/internal/core/window.rs
[slint-contributing]: https://github.com/slint-ui/slint/blob/master/CONTRIBUTING.md
[cosmic-panel]: https://github.com/pop-os/cosmic-panel
[cosmic-applets]: https://github.com/pop-os/cosmic-applets
[layer-shika]: https://lib.rs/crates/layer-shika
[libcosmic-cargo]: https://github.com/pop-os/libcosmic/blob/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f/Cargo.toml
[libcosmic-license]: https://github.com/pop-os/libcosmic/blob/master/LICENSE
[pop-iced-tree]: https://github.com/pop-os/iced/tree/d5d638c3a3022396fcf5b9b588b3446820dc11ad
[iced-license]: https://github.com/iced-rs/iced/blob/master/LICENSE
[iced-releases]: https://github.com/iced-rs/iced/releases
[iced-552]: https://github.com/iced-rs/iced/issues/552
[iced-3111]: https://github.com/iced-rs/iced/pull/3111
[iced-3281]: https://github.com/iced-rs/iced/pull/3281
[lc-1429]: https://github.com/pop-os/libcosmic/issues/1429
