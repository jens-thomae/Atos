# D-007: relationship with COSMIC

Card: #3 · Written: 2026-11-05 · Status of D-007: **Open**. This write-up ends in a recommendation for the owner ([section 6](#6-recommendation-for-the-owner-to-decide)); it decides nothing and does not decide D-006.

Every statement about COSMIC, iced, Smithay or their policies links to the repository, file, issue or pull request it comes from. All links were opened on 2026-11-05. Where a link points at a branch head, the commit checked is named.

## 1. Context

### 1.1 What D-007 decides

D-007 (spec §5) decides how much compositor (C2), shell (C3), toolkit (C4) and app (C5) code we take from COSMIC, and on what terms. It is one of the three Phase 0 gate decisions (§8) with D-006 (toolkit) and D-008 (base image). The card asks for three options: (a) build on COSMIC and contribute upstream, (b) fork selected repositories (cosmic-comp, libcosmic, cosmic-files), (c) use only the lower layers (Smithay, iced) and own everything above.

Since the card was written, the spec gained three things that weigh on this decision:

- **§2 priority 4, "AI integration, with the user in control"**: assistants operate every system feature and app through standard interfaces.
- **§6 C12 Agent integration**: system features and native apps expose their actions as MCP servers (D-011, Decided); apps without MCP are operated through their accessibility tree; a permission broker, action log, indicator and stop switch (D-012, Open).
- **§6 C4**: the accessibility tree must be complete (every control has a role and name), because assistants use it as the fallback.

### 1.2 The COSMIC repositories in scope

| Repository | What it is | Our component | Licence | Version, release | Activity |
| --- | --- | --- | --- | --- | --- |
| [pop-os/cosmic-comp](https://github.com/pop-os/cosmic-comp) | Wayland compositor on Smithay | C2 | **GPL-3.0-only** ([`Cargo.toml`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/Cargo.toml), [`LICENSE`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/LICENSE)) | 1.0.0 in `Cargo.toml`; released only as `epoch-*` tags | 138 commits in the last 90 days; 2.68 MB of Rust (GitHub language stats) |
| [pop-os/libcosmic](https://github.com/pop-os/libcosmic) | Toolkit on a fork of iced | C4 | **MPL-2.0** ([`LICENSE`](https://github.com/pop-os/libcosmic/blob/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f/LICENSE)) | 1.0.0 in `Cargo.toml`, git-only: [not on crates.io](https://crates.io/crates/libcosmic) (crates.io answers "does not exist"); last tag `v0.12` (2024-10-16) | 109 commits in 90 days; 1.87 MB of Rust |
| [pop-os/iced](https://github.com/pop-os/iced) | libcosmic's iced fork, a git submodule ([`.gitmodules`](https://github.com/pop-os/libcosmic/blob/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f/.gitmodules)) | C4 | MIT | 0.14.0; **285 commits ahead of and 685 behind** [iced-rs/iced](https://github.com/iced-rs/iced) `master` (GitHub compare, 2026-11-05) | 31 commits in 90 days |
| [pop-os/cosmic-files](https://github.com/pop-os/cosmic-files) | File manager | C5 Files | **GPL-3.0-only** ([`Cargo.toml`](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/Cargo.toml)) | 1.11.0; `epoch-*` tags | 72 commits in 90 days; 1.07 MB of Rust |
| [cosmic-panel](https://github.com/pop-os/cosmic-panel), [cosmic-applets](https://github.com/pop-os/cosmic-applets), [cosmic-launcher](https://github.com/pop-os/cosmic-launcher), [cosmic-workspaces-epoch](https://github.com/pop-os/cosmic-workspaces-epoch), [cosmic-settings](https://github.com/pop-os/cosmic-settings) | Shell pieces and Settings | C3, C8 | GPL-3.0 (GitHub licence detection) | `epoch-*` tags | active |
| [pop-os/cosmic-protocols](https://github.com/pop-os/cosmic-protocols) | COSMIC's private Wayland protocols | C2, C3 | `license = "MIT"` in [`Cargo.toml`](https://github.com/pop-os/cosmic-protocols/blob/main/Cargo.toml), but the repository has no licence file | 0.2.0 | |
| [pop-os/cosmic-text](https://github.com/pop-os/cosmic-text) | Text shaping and layout | C4 (used by both D-006 candidates' ecosystems) | MIT OR Apache-2.0 | 0.19.0 on crates.io | |
| [Smithay/smithay](https://github.com/Smithay/smithay) | Compositor library (lower layer) | C2 | MIT | v0.7.0 (2025-06-24); cosmic-comp pins a git revision through `[patch.crates-io]` ([`Cargo.toml`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/Cargo.toml)) | |
| [iced-rs/iced](https://github.com/iced-rs/iced) | Toolkit (lower layer) | C4 | MIT | 0.14.0 (2025-12-07); `master` is 0.15.0-dev | |

**Release cadence.** COSMIC ships as "Epoch" releases tagged across all repositories: Epoch 1.0.0 on 2025-12-10, then a release every one to two weeks ([cosmic-epoch releases](https://github.com/pop-os/cosmic-epoch/releases): 1.0.3 on 2026-01-20 … 1.10.0 on 2026-10-08, 1.11.0 on 2026-10-20). The README says Pop!_OS "typically receives updates to individual submodules before they're tagged" ([README](https://github.com/pop-os/cosmic-epoch/blob/e98f8289a22f9e612feee7d4c6ba197782db154b/README.md)). libcosmic has no API releases at all; apps track its git `master` (cosmic-files and cosmic-comp depend on `git = "https://github.com/pop-os/libcosmic"` without a revision). **There is no stable libcosmic API to pin to.**

**Trademark.** The [COSMIC trademark policy](https://github.com/pop-os/cosmic-epoch/blob/e98f8289a22f9e612feee7d4c6ba197782db154b/TRADEMARK.md) (effective 2024-06-03) reserves the `cosmic-` package namespace and `com.system76.` app IDs for official software and asks third parties to use `cosmic-ext-`. A fork must be renamed and must not imply endorsement. This is a naming cost, not a blocker.

### 1.3 Upstream contribution policy (decisive for option a)

Atos is built by agents (spec §9). COSMIC does not accept their work:

- The Pop!_OS [contributor guide](https://github.com/pop-os/pop/blob/b863879b23d5de073f0fdd349c290b7e340e84a7/CONTRIBUTING.md), section "AI Contributions": LLM-generated content "may not be contributed in issues or PRs to Pop!_OS projects including code, comments, and descriptions".
- The pull request templates of [cosmic-comp](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/.github/PULL_REQUEST_TEMPLATE.md), [libcosmic](https://github.com/pop-os/libcosmic/blob/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f/.github/PULL_REQUEST_TEMPLATE.md) and [cosmic-epoch](https://github.com/pop-os/cosmic-epoch/blob/e98f8289a22f9e612feee7d4c6ba197782db154b/.github/PULL_REQUEST_TEMPLATE.md) (all last changed 2026-09-30) require the box "I have not included any LLM (also known as AI) generated content in this PR"; PRs without it are closed.
- It is enforced: cosmic-comp [PR #2920](https://github.com/pop-os/cosmic-comp/pull/2920) was closed on 2026-10-05 by a maintainer with "LLM-generated pull requests are not permitted by policy."

The lower layers are less strict but not welcoming either: Smithay's [`AI.md`](https://github.com/Smithay/smithay/blob/master/AI.md) allows AI-generated code only if marked in commit messages, "strongly advise[s] against" it and asks for no generated text on its tracker. iced's [`CONTRIBUTING.md`](https://github.com/iced-rs/iced/blob/master/CONTRIBUTING.md) asks contributors to discuss ideas on Zulip first and warns that waiting for the core team "can take a long time (maybe months!)"; on accessibility specifically, the iced author closed an outside accessibility PR on 2026-03-14 with "I'll work on this myself" ([iced-rs/iced#3281](https://github.com/iced-rs/iced/pull/3281)). AccessKit ([`CONTRIBUTING.md`](https://github.com/AccessKit/accesskit/blob/main/CONTRIBUTING.md)) has no AI rule.

### 1.4 Our own evidence (D-006)

From [`D-006-measurements.md`](D-006-measurements.md) (#12), [`D-006-agent-test.md`](D-006-agent-test.md) (#13) and [`spikes/d006-iced/README.md`](../../spikes/d006-iced/README.md) (#10), libcosmic at rev `daca62bb`, default features:

- **Accessibility tree empty.** AT-SPI shows one unnamed `frame` with no children; M6 found 26 of 26 controls missing; M7 had 0 of 12 steps verifiable; agent-test check 7 failed in all three runs. Cause: the iced fork's winit layer creates the AccessKit adapter with an empty window node and never sends a `TreeUpdate` built from `UserInterface::a11y_nodes()`. Three independent agents found the same cause and could not fix it from app code.
- **Missing roles even if the tree were sent**: only buttons have a role; no list, row, table, header, menu, menu item or dialog roles; the `list` widget has no `a11y_nodes`; the list cannot take focus.
- **Choppy scrolling on the reference NUC**: 69 dropped frames per 10 s scroll run, p95 240 ms, with the default CPU renderer (`iced_tiny_skia`; default features do not include `wgpu`).
- **Fast start, small footprint on the NUC**: 49 ms cold start (warm cache), 77 ms 10k first paint, 34 MB RSS, 0.00 % idle CPU.
- **Agents worked well with it otherwise**: checks 1–6 passed in every run, with 0–1 compile-error iterations, mostly by reading libcosmic source.

### 1.5 Upstream status of those gaps (checked 2026-11-05)

**Accessibility.**

- Our evidence still holds at today's heads. libcosmic `master` ([`7cd76ae3`](https://github.com/pop-os/libcosmic/commit/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f), 2026-11-05) is 6 commits past our `daca62bb`, all dependency and CI chores. Its iced submodule points at [`d5d638c3`](https://github.com/pop-os/iced/commit/d5d638c3a3022396fcf5b9b588b3446820dc11ad). In that revision's [`winit/src/lib.rs`](https://github.com/pop-os/iced/blob/d5d638c3a3022396fcf5b9b588b3446820dc11ad/winit/src/lib.rs#L640-L681) the adapter is still created with an empty title, the `a11y_enabled` flag set at [L1654–1657](https://github.com/pop-os/iced/blob/d5d638c3a3022396fcf5b9b588b3446820dc11ad/winit/src/lib.rs#L1654-L1657) is never read, and nothing in `winit/` (including the Wayland `platform_specific` path) calls [`UserInterface::a11y_nodes`](https://github.com/pop-os/iced/blob/d5d638c3a3022396fcf5b9b588b3446820dc11ad/runtime/src/user_interface.rs#L607). I checked the iced revisions libcosmic pinned on 2026-01-15, 04-01, 07-01, 09-01 and 10-15: none of them calls it from `winit/` either.
- A maintainer stated on 2026-01-21 that "libcosmic applications built with a11y feature have screen reader support" and that some widgets lack focus or a11y ([libcosmic#1098](https://github.com/pop-os/libcosmic/issues/1098)). I could not reconcile that with the code above or with our AT-SPI dumps; it may describe a code path or revision I did not find. **Treat upstream's accessibility as unproven, our measurement as the evidence.**
- COSMIC's own Files app turns `a11y` off: cosmic-files sets `default-features = false` for libcosmic with the comment `#TODO: a11y feature crashes` ([`Cargo.toml` L75–87](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/Cargo.toml#L75-L87)). (Our prototype did not crash with it on.)
- Open upstream work: `text_input` emits no accessibility nodes ([libcosmic#1429](https://github.com/pop-os/libcosmic/issues/1429), open since 2026-09-10); a screen-reader tracking issue lists "Complete controls labeling in apps" as to do ([libcosmic#1400](https://github.com/pop-os/libcosmic/issues/1400), open since 2026-08-23); button names were added in [libcosmic#1087](https://github.com/pop-os/libcosmic/pull/1087) (merged 2026-01-09). No issue or PR tracks list, table, row, menu or dialog roles.
- Upstream iced has no AccessKit integration on `master` (no `accesskit` in its [`Cargo.toml`](https://github.com/iced-rs/iced/blob/master/Cargo.toml)); [#552 "Implement accessibility support"](https://github.com/iced-rs/iced/issues/552) is open since 2020; [draft PR #3111](https://github.com/iced-rs/iced/pull/3111) is open; the author intends to do it himself (#3281 above). No date.

**Renderer and GPU.**

- libcosmic has a GPU renderer: the `wgpu` feature ([`Cargo.toml`](https://github.com/pop-os/libcosmic/blob/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f/Cargo.toml)), not in `default`. COSMIC's Files app enables it by default (`wgpu = ["libcosmic/wgpu"]` in cosmic-files' [`default` features](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/Cargo.toml#L117-L137)). So the choppy scrolling we measured is libcosmic's *default* path, not necessarily COSMIC's shipping path. **libcosmic with `wgpu` has not been measured on the NUC**; our D-006 measurement note that "a GPU would not change" libcosmic's numbers holds only for the default build.
- cosmic-comp renders through Smithay's GLES (`renderer_glow`), multi-GPU (`renderer_multi`) and pixman renderers ([`Cargo.toml`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/Cargo.toml)); a Vulkan renderer is a request ([cosmic-comp#2055](https://github.com/pop-os/cosmic-comp/issues/2055), open). HDR is not upstream ([cosmic-comp#1384](https://github.com/pop-os/cosmic-comp/issues/1384), open since 2025-05-01; users point to a third-party fork in the thread). VRR exists and is being reworked ([cosmic-comp#2420](https://github.com/pop-os/cosmic-comp/pull/2420), open).
- cosmic-comp draws its own UI elements (window stack tabs, indicators) with libcosmic and `iced_tiny_skia` (same `Cargo.toml`), so a cosmic-comp fork brings libcosmic with it whatever D-006 decides.

**Window modes.** cosmic-comp has floating and tiling layouts ([`src/shell/layout/floating`](https://github.com/pop-os/cosmic-comp/tree/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/shell/layout/floating), [`tiling`](https://github.com/pop-os/cosmic-comp/tree/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/shell/layout/tiling)), with tiling switchable per workspace. Scroll tiling is not there: [cosmic-epoch#322](https://github.com/pop-os/cosmic-epoch/issues/322) is open since 2024-05-12, and a maintainer wrote on 2026-09-18 that it is "not considered solved". Whether cosmic-comp's tree tiling is what §3 calls "grid tiling" is not defined anywhere in our spec.

**Agent-relevant compositor features (C12).** cosmic-comp already implements an accessibility protocol ([`src/wayland/handlers/a11y.rs`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/wayland/handlers/a11y.rs)), input emulation through libei (`backend_libei`), virtual keyboard, toplevel info and management, image capture and `security_context` ([handlers](https://github.com/pop-os/cosmic-comp/tree/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/wayland/handlers)). These are the hooks a C12 "windows" MCP server and the indicator/stop switch would build on. There is no MCP or agent work upstream; an "AI-first" feature request was closed as not planned on 2026-07-23 ([cosmic-epoch#3734](https://github.com/pop-os/cosmic-epoch/issues/3734)), and the one agent-approval PR (#2920 above) was closed under the AI policy.

## 2. Options

### (a) Build on COSMIC components and contribute upstream

Use cosmic-comp, libcosmic, cosmic-files and the shell pieces as they are, configure and theme them, and fix gaps by contributing upstream.

- **Reuse per component.** C2: cosmic-comp unchanged. C3: cosmic-panel, applets, launcher, workspaces. C4: libcosmic. C5: cosmic-files and the other COSMIC apps.
- **Licence.** We redistribute GPL-3.0-only and MPL-2.0 code unmodified; obligations are source availability and notices. No constraint on our own code beyond linking libcosmic (MPL-2.0 is file-level, so our own files may use any licence).
- **Cadence and API stability.** We follow Epoch releases every one to two weeks and libcosmic `master` with no API versioning. Our code built on libcosmic breaks whenever upstream changes an API.
- **Design system and window modes.** Our design system can only be applied where COSMIC's theme (`cosmic-theme`) has a matching value; layout, components and motion stay COSMIC's. Scroll tiling and HDR depend on upstream priorities (#322 open for 30 months, #1384 for 18).
- **How the gaps get fixed.** They don't, by us. The [AI policy](#13-upstream-contribution-policy-decisive-for-option-a) forbids LLM-generated issues and PRs, so the agents that build Atos cannot file the accessibility, role, scroll-tiling or MCP work upstream. Only the owner, writing by hand, could contribute, and then still at upstream's pace and discretion.
- **C12.** MCP servers for files, windows and settings would have to live inside COSMIC apps and cosmic-comp, which we cannot change upstream; we could only wrap them from outside (D-Bus, Wayland protocols). The accessibility-tree fallback does not work today (empty tree, `a11y` disabled in cosmic-files), so assistants could not operate COSMIC apps at all.
- **Maintenance cost.** Lowest in code, highest in dependence: every requirement upstream does not share waits indefinitely.

**Verdict.** Not workable for this project as long as the AI policy stands. In practice it turns into option (b) the first time we need a fix.

### (b) Fork selected repositories (cosmic-comp, libcosmic, cosmic-files)

Keep our own forks, renamed per the trademark policy, carry our patches, and merge upstream periodically. Without upstream contributions, every patch is ours to carry forever.

- **Reuse per component.**
  - C2: cosmic-comp. A shipping compositor with floating and tiling per workspace, Xwayland, fractional scaling, VRR, libei, a11y protocol, image capture and session lock. We add scroll tiling, HDR, the motion tokens and C12 hooks.
  - C3: the shell pieces can be forked too, but they are built on libcosmic and follow COSMIC's layout; our dock-taskbar, command palette, control centre and three layout presets are different products. Little would survive.
  - C4: libcosmic plus pop-os/iced, only if D-006 picks libcosmic.
  - C5: cosmic-files has tabs ([`src/tab.rs`](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/src/tab.rs)), GVFS network mounts, search and a space preview ([cosmic-files#1566](https://github.com/pop-os/cosmic-files/issues/1566)). It lacks split view ([#260](https://github.com/pop-os/cosmic-files/issues/260), open since 2024-06-20) and full undo ([#306](https://github.com/pop-os/cosmic-files/issues/306), open). I found no tags or batch rename. It is usable only if D-006 picks libcosmic.
- **Licence.** Forked cosmic-comp, cosmic-files and shell pieces stay **GPL-3.0-only**: our modifications are GPL-3.0-only and cannot be relicensed, and code we link into them must be GPL-3.0-compatible. Forked libcosmic files stay MPL-2.0 (modified files published under MPL-2.0); the iced fork is MIT. Atos has no project licence yet ([open question 1](#8-open-questions)), so this is the moment to check it is compatible.
- **Cadence and API stability.** We choose when to merge upstream, so nothing breaks unannounced. The price is merge work. cosmic-comp had 138 commits in 90 days, libcosmic 109 and cosmic-files 72; the iced fork is already 685 commits behind upstream iced, so a libcosmic fork is a fork of a fork.
- **Design system and window modes.** In cosmic-comp, window modes are our code in `src/shell/layout`. Its visuals are few (borders, stack tabs, indicators, drawn with libcosmic), so applying our tokens is a small patch. In libcosmic and cosmic-files, our design system means reworking `cosmic-theme` and every widget's style, which touches most files and makes upstream merges painful.
- **How the gaps get fixed: by fork patches.**
  - Accessibility tree (libcosmic): patch pop-os/iced `winit/` to build and send `TreeUpdate`s from `a11y_nodes()` on every UI change, then add roles and `a11y_nodes` to list, table, row, header, menu, menu item, dialog and text input, and make the list focusable. These are MIT and MPL-2.0 files of a fork that changes daily upstream.
  - Scrolling (libcosmic): turn on the existing `wgpu` feature first (configuration, no patch); measure on the NUC before patching anything.
  - Scroll tiling and HDR (cosmic-comp): own layout and render code in our fork.
- **C12.** The fork can add MCP servers directly in cosmic-comp (window list, focus, move, workspace and mode switch) and in cosmic-files (file operations), with the permission broker in between. The compositor's existing libei, a11y and image-capture paths are the right places for the indicator, input confirmation and stop switch. The accessibility fallback for our libcosmic apps depends on the patch above.
- **Maintenance cost.** High and growing: three to five long-lived forks with daily upstream activity, no way to upstream our fixes, and divergence that only grows. cosmic-comp is the most valuable fork; libcosmic and cosmic-files the most expensive per benefit.

### (c) Use only the lower layers (Smithay, iced) and own everything above

Build the compositor on Smithay and the shell, toolkit layer and apps ourselves. Use iced only if D-006 picks iced/libcosmic; with Slint the toolkit lower layer is Slint itself.

- **Reuse per component.** C2: Smithay (MIT), plus whatever we learn from reading cosmic-comp (reading is fine; copying code makes it a fork under GPL-3.0-only). C3, C5: nothing from COSMIC. C4: iced (MIT) or Slint; libcosmic is not used.
- **Licence.** MIT lower layers impose nothing. We choose our own licence for all of C2–C5. COSMIC libraries we may still use as plain dependencies: cosmic-text (MIT OR Apache-2.0); cosmic-protocols has no licence file, so ask before relying on it.
- **Cadence and API stability.** Smithay releases semver crates (0.5 → 0.7 in 2025), but cosmic-comp itself tracks Smithay git; iced releases are rare (0.13 in 2024-09, 0.14 in 2025-12) and break APIs between them. Fewer, slower upstreams than (b).
- **Design system and window modes.** Designed in from the start: all three modes, motion tokens and every visual are ours.
- **How the gaps get fixed: own code.**
  - Accessibility: with plain iced, AccessKit integration is ours to write (upstream iced has none and does not take outside work on it); with Slint, the missing roles are Slint's (see D-006).
  - Compositor features: everything cosmic-comp already has (Xwayland, VRR, fractional scaling, session lock, a11y protocol, libei, multi-GPU) is rebuilt on Smithay.
- **C12.** Cleanest: MCP servers, permission broker hooks, indicator and stop switch are designed into our compositor, shell and apps from day one, in one design and one codebase.
- **Maintenance cost.** Lowest ongoing cost (no forks to merge), highest up-front cost. A compositor is the largest piece: cosmic-comp is about 2.7 MB of Rust after years of work, and its 1,051 open issues and pull requests ([cosmic-comp issues](https://github.com/pop-os/cosmic-comp/issues)) show how much hardware and protocol detail sits in one. Phase 1 needs a booting compositor (§8), so this option delays Phase 1 most.

## 3. Comparison

| | (a) Upstream | (b) Fork | (c) Lower layers |
| --- | --- | --- | --- |
| Can our agents fix gaps? | **No**: LLM content is banned in issues and PRs | Yes, in our forks | Yes, in our code |
| C2 compositor at start of Phase 1 | Working, COSMIC's behaviour | Working, ours to change | To be built on Smithay |
| Scroll tiling, HDR | Waiting on upstream (#322, #1384) | Our patches | Our code |
| C3 shell | COSMIC's shell, not our layout | Forkable but mostly rewritten | Ours |
| C4 toolkit | libcosmic as is (empty a11y tree) | libcosmic fork with our a11y patch, if D-006 picks it | iced or Slint per D-006 |
| C5 Files | cosmic-files as is (a11y off) | Fork; needs split view, undo, tags, batch rename, a11y | Ours |
| Design system | Only through `cosmic-theme` | Small patch in cosmic-comp, deep rework in libcosmic/apps | Native |
| C12 MCP and a11y fallback | Wrapped from outside; fallback broken | Built in, fallback after our patch | Built in from the start |
| Licence of our C2–C5 code | Any (we only redistribute) | GPL-3.0-only for forked apps and compositor, MPL-2.0 for libcosmic files | Any |
| API stability | None (libcosmic git `master`) | We control merges | Semver lower layers |
| Ongoing maintenance | Low code, full dependence | High, grows with divergence | Moderate, no merges |
| Up-front cost | Lowest | Low to moderate | Highest (compositor) |

## 4. Our §6 requirements against COSMIC today

"Meets" means present upstream on 2026-11-05 per the linked source; it does not mean measured by us.

| Requirement (§6) | COSMIC | Evidence |
| --- | --- | --- |
| C2 Wayland compositor with Xwayland | Meets | cosmic-comp `xwayland` feature, [`xwayland_shell.rs`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/wayland/handlers/xwayland_shell.rs) |
| C2 VRR | Partly: present, being reworked, driver-specific bugs | [#2420](https://github.com/pop-os/cosmic-comp/pull/2420), [#2401](https://github.com/pop-os/cosmic-comp/issues/2401) |
| C2 HDR | Not met | [#1384](https://github.com/pop-os/cosmic-comp/issues/1384) open |
| C2 per-monitor fractional scaling | Meets | [`fractional_scale.rs`](https://github.com/pop-os/cosmic-comp/blob/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/wayland/handlers/fractional_scale.rs) |
| C2 three window modes per workspace | Partly: floating and tiling per workspace; no scroll tiling | [layouts](https://github.com/pop-os/cosmic-comp/tree/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/shell/layout), [#322](https://github.com/pop-os/cosmic-epoch/issues/322) |
| C2 animations use our motion tokens | Conflicts: animation timings are cosmic-comp's own; even a speed setting is still a request ([#376](https://github.com/pop-os/cosmic-comp/issues/376), open) | needs a fork patch |
| C3 dock-taskbar, launcher, workspaces overview | Partly: COSMIC's panel/dock, launcher and workspaces in their own layout | repos in 1.2 |
| C3 command palette, three layout presets, cheat sheet | Not met in COSMIC's form | none found |
| C4 one toolkit for shell and apps | Meets (libcosmic everywhere) | repos in 1.2 |
| C4 implements our design system and tokens | Conflicts: `cosmic-theme` is COSMIC's design | [libcosmic](https://github.com/pop-os/libcosmic) |
| C4 AccessKit, screen reader, keyboard | Partly at best: AccessKit wired in but tree not published; some widgets not focusable | 1.5, [#1098](https://github.com/pop-os/libcosmic/issues/1098) |
| C4 complete accessibility tree (C12 fallback) | Not met | D-006 M6 26/26 missing; [#1429](https://github.com/pop-os/libcosmic/issues/1429) |
| C4 llms.txt, Markdown API docs | Not met | D-006 agent test §5 |
| C4 headless inspection and screenshot harness | Not met upstream | none found |
| C5 Files: tabs, network mounts, search | Meets | [`tab.rs`](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/src/tab.rs), [`mounter/gvfs.rs`](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/src/mounter/gvfs.rs), [`scan/search.rs`](https://github.com/pop-os/cosmic-files/blob/3868a8e3ac65f7572861c4668cee4564ac473974/src/scan/search.rs) |
| C5 Files: spacebar preview, undoable operations | Partly | [#1566](https://github.com/pop-os/cosmic-files/issues/1566), [#306](https://github.com/pop-os/cosmic-files/issues/306) |
| C5 Files: split view, tags, batch rename | Not met | [#260](https://github.com/pop-os/cosmic-files/issues/260); none found for tags or batch rename |
| §7 Files scrolling, no dropped frames | Not met on the default build on the NUC; `wgpu` build unmeasured | D-006 M5 |
| §7 cold start, idle RAM, idle CPU | Meets for libcosmic (49 ms, 34 MB, 0.00 %) | D-006 M1–M4 |
| C10 / C12 screen capture and input go through permissioned paths | Partly: `security_context`, image capture, libei exist; no per-assistant permissions | [handlers](https://github.com/pop-os/cosmic-comp/tree/cb86b9ec6f18ca2d2ad3b39426a57ab850867070/src/wayland/handlers) |
| C12 MCP servers for system features and apps | Not met; not planned upstream | [#3734](https://github.com/pop-os/cosmic-epoch/issues/3734) |
| D-005 no telemetry, no account | Meets as far as checked (no telemetry found in the repos above) | not audited |

## 5. Interaction with D-006

D-006 (toolkit) is open and decided in #14; this section only shows how the two decisions constrain each other.

- **If D-006 picks Slint**, libcosmic and cosmic-files leave the picture. Option (b) shrinks to forking cosmic-comp, which still contains libcosmic for its own small UI (stack tabs, indicators). Those few elements would need to be restyled or redrawn so the shell does not show two design languages. The licence question then is Slint's (GPL-3.0, royalty-free or commercial, see D-006) next to cosmic-comp's GPL-3.0-only.
- **If D-006 picks libcosmic**, the accessibility tree becomes our patch to carry (option b) or our code on plain iced (option c). C4 and C12 require a complete tree, and upstream will not take agent-written fixes. D-006 should count that patch, and the merge cost of a fork of a fork, as part of libcosmic's price. The `wgpu` renderer should be measured on the NUC before scrolling counts against libcosmic.
- **Either way**, option (a) does not help D-006: upstream libcosmic as it is today fails C4's accessibility requirement, and we cannot change it upstream.

## 6. Recommendation (for the owner to decide)

**Flag for the owner: this is a recommendation, not a decision.**

**A narrow fork: fork cosmic-comp for C2; take nothing else from COSMIC above the lower layers (option c for C3, C4 and C5).** Do not try option (a).

Why:

1. **Option (a) is closed to us.** COSMIC bans LLM-generated issues and PRs, and enforces it. An agent-built OS cannot depend on upstream fixing what we need.
2. **cosmic-comp is the one piece worth its fork cost.** A compositor is the most expensive and hardware-sensitive thing to rebuild, Phase 1 needs one that boots on the NUC, and cosmic-comp already has floating and tiling per workspace, Xwayland, fractional scaling, VRR, libei, an a11y protocol and image capture. Its visual surface is small, so our design system costs a small patch. Our additions (scroll tiling, HDR, motion tokens, C12 window and input hooks) mostly sit in its layout and render code.
3. **The shell, apps and toolkit are where Atos differs.** COSMIC's shell has a different layout, cosmic-files has a different feature set and disables accessibility, and libcosmic's design and accessibility are not ours. Forking them buys code we would mostly rewrite and then merge against daily.
4. **C12 favours owning the layers assistants use.** MCP servers, the permission broker hooks, the action log and a complete accessibility tree are easiest to get right in code we own. The compositor is the exception, because its agent hooks (libei, a11y, capture) already exist.

What this costs:

- Our C2 code is **GPL-3.0-only** for good. Fine for a separate compositor process, but the owner should confirm it fits the project licence.
- We carry cosmic-comp merges ourselves (138 upstream commits in 90 days) and rename it per the trademark policy.
- cosmic-comp's internal libcosmic UI must be restyled or replaced, whatever D-006 picks.

If the owner prefers no fork at all, option (c) everywhere is the alternative. It costs a compositor built on Smithay before Phase 1 can pass its gate.

## 7. Consequences

If the recommendation is accepted:

- **D-007** becomes "Fork cosmic-comp (renamed) as the base of C2; C3–C5 own code on the D-006 toolkit; no upstream contributions by agents".
- **New cards** (the planner writes them; not created here): set up the cosmic-comp fork and rename; a merge-from-upstream routine with a fixed rhythm (for example every Epoch release); scroll tiling in the fork; design tokens for the compositor's own UI; C12 window-actions MCP server in the compositor (after D-012).
- **Licence**: the project needs a licence decision that accepts GPL-3.0-only for C2.
- **D-006**: libcosmic's evaluation should add the `wgpu` measurement and the cost of carrying an accessibility patch (section 5). I filed no card for this; the owner or planner may.
- **Docs**: `docs/components/c2-compositor/` should record the fork point (upstream commit) and every downstream patch.

If option (c) is chosen instead, C2 becomes the largest Phase 1 card set, and Phase 1's gate ("boots and updates on the reference hardware") moves out accordingly.

## 8. Open questions

For the owner:

1. **Project licence.** Atos has no licence file and the spec does not name one. Forking cosmic-comp makes C2 GPL-3.0-only; forking cosmic-files or the shell makes those GPL-3.0-only too. Is that acceptable?
2. **Hand-written upstream contributions.** The AI policy does not stop the owner from filing hand-written bug reports or patches. Does the owner want to do that for fixes we carry (for example the libcosmic tree publication), or should we never contribute upstream?
3. **"Grid tiling".** §3 and C2 name grid tiling, floating and scroll tiling, but no spec defines grid tiling. Is cosmic-comp's tree tiling acceptable as grid tiling, or is a regular grid meant?
4. **The maintainer's statement in libcosmic#1098** (screen reader works with `a11y`) conflicts with our measurement and with the code at every revision I checked. Should D-006 re-test with a COSMIC app (for example cosmic-settings) to rule out a code path we missed?
5. **Other Smithay compositors.** The card limits the options to COSMIC. Other Smithay-based compositors exist (for example [niri](https://github.com/niri-wm/niri), GPL-3.0, which is built around scroll tiling). Does the owner want a short comparison before deciding C2's base, or is cosmic-comp the only fork candidate?
6. **cosmic-protocols licence.** `Cargo.toml` says MIT, but the repository has no licence file. Only relevant if we use it outside a cosmic-comp fork.

## Sources

All opened on 2026-11-05. Commit-pinned links refer to: cosmic-comp [`cb86b9ec`](https://github.com/pop-os/cosmic-comp/commit/cb86b9ec6f18ca2d2ad3b39426a57ab850867070), libcosmic [`7cd76ae3`](https://github.com/pop-os/libcosmic/commit/7cd76ae3160cbd26ae89a4c01e64eda21f648c7f), pop-os/iced [`d5d638c3`](https://github.com/pop-os/iced/commit/d5d638c3a3022396fcf5b9b588b3446820dc11ad), cosmic-files [`3868a8e3`](https://github.com/pop-os/cosmic-files/commit/3868a8e3ac65f7572861c4668cee4564ac473974), cosmic-epoch [`e98f8289`](https://github.com/pop-os/cosmic-epoch/commit/e98f8289a22f9e612feee7d4c6ba197782db154b), pop-os/pop [`b863879b`](https://github.com/pop-os/pop/commit/b863879b23d5de073f0fdd349c290b7e340e84a7). Commit counts are from the GitHub commits API on each default branch since 2026-08-05; Rust sizes are GitHub's language statistics in bytes; the fork comparison is GitHub's compare of `iced-rs/iced:master...pop-os/iced:master`.
