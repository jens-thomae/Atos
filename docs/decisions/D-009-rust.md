# D-009: Rust as the implementation language for system components

Status: **Decided** by the owner on 2026-11-03 (see `docs/spec.md` §5 and "Owner decision" below).
Card: #1 · Facts checked: 2026-11-03

## Context

Spec §2 ranks performance and stability first, and §7 makes "0 known crashers" a release blocker. The OS integrates proven Linux pieces and writes only what defines the experience (§3), so most of our own code will be the compositor (C2), shell (C3), toolkit (C4), native apps (C5) and the daemons and tools behind them. D-006 (toolkit) is open between iced/libcosmic and Slint, both written in Rust. D-007 (COSMIC) is open, and COSMIC is written in Rust [3][10]. `CLAUDE.md` already treats Rust as the convention; this document records why, and where the boundary sits.

**What "system component" means here (recommended scope).** Any code we write that ships in the image or is the product: compositor, shell, toolkit, native apps, background services (search and indexer, connectivity, privacy), the `os` command-line tool, Settings, Software and the installer (C1–C11).

**Where other languages stay allowed (recommended).**

- Shell scripts and CI workflows in `tools/` and `.github/`.
- Build and packaging files: `Cargo.toml`, image definitions for C1 (format depends on D-008), Flatpak manifests.
- Data and markup: config files (TOML or KDL per D-010), design tokens, and the `.slint` markup language if D-006 picks Slint.
- GPU shaders (GLSL/WGSL).
- Existing C system libraries (libwayland, libinput, Mesa, PipeWire, systemd) used through bindings. We call them; we do not write new C.
- Third-party code: Flatpak apps and extensions (out of process or WASM per §6 C8) may use any language.

Anything else needs a new decision entry.

## Options

| Criterion | Rust | C | C++ |
| --- | --- | --- | --- |
| Memory safety | Safe by default; `unsafe` is opt-in and greppable. Android reports memory-safety bugs fell below 20% of new vulnerabilities and a 1000× reduction in memory-safety vulnerability density compared with its C/C++ code [1] | None by the language; relies on review, sanitizers, fuzzing | Better tools (RAII, smart pointers) but no compile-time guarantee |
| Wayland libraries | [wayland-rs] 0.31.15 (Jul 2026) [2]; [Smithay] compositor library, v0.7.0 (Jun 2025), used by [cosmic-comp] and [niri], both of which track Smithay git revisions ahead of the last release [3][4] | Reference [libwayland] is C [5]; [wlroots] is C, v0.20.2 (Jul 2026), still 0.x with breaking releases [6]; [Mutter] is C [7] | [KWin] is C++ [8], but is a full compositor tied to Plasma and Qt, not a reusable library |
| Toolkit fit (D-006) | [iced] 0.14 (Dec 2025) [9], [libcosmic] [10] and [Slint] 1.18 (Sep 2026) [11] are Rust-native | GTK is C [16], but GTK is not a D-006 candidate | Qt is C++ [17], not a D-006 candidate; Slint has C++ bindings [18] |
| Agent productivity | The compiler rejects whole classes of mistakes (lifetimes, data races, unhandled enum cases) before review, which suits agents that cannot remember earlier sessions. Android measured ~4× lower rollback rate and ~25% less review time for Rust changes vs C++ [1] | Bugs surface at runtime or under sanitizers; a reviewer agent must catch them | Very large language surface; many idioms per task, harder for agents to stay consistent |

A fourth option, **Rust plus wlroots through bindings**, would keep a C compositor core. It loses most of the safety argument in the most crash-sensitive component and adds an FFI layer; it is only worth revisiting if Smithay blocks a §6 C2 requirement.

Wider signal: the Linux kernel declared Rust no longer experimental at the 2025 Maintainers Summit [12].

## Recommendation

**Decide D-009 as Rust for all system components** as scoped above.

**Minimum supported Rust version (MSRV) policy — recommendation, not a decision:**

- Pin one toolchain for the whole workspace in `rust-toolchain.toml`, and set the same version as `rust-version` in the workspace `Cargo.toml` [13].
- Track the latest stable release, upgrading in a dedicated card within one release cycle (Rust ships every six weeks; current stable is 1.99.1 [14]). We ship binaries in an image, not libraries, so there are no downstream users to keep on older toolchains.
- Use `edition = "2024"`, whose default resolver `"3"` prefers dependency versions compatible with `rust-version` (Rust 1.84+) [15].
- Exception for crates we publish for third-party developers (the SDK, §8 Phase 4): support the latest stable minus two (N-2), one of the policies Cargo's docs suggest [13].

Today's candidate dependencies already require Rust 1.80.1 to 1.92 in their latest releases (Smithay 0.7.0: 1.80.1, iced 0.14.0: 1.88, Slint 1.18.1: 1.92) [19], and 1.87 to 1.95 on their default branches (Smithay 1.87, niri 1.87, iced 1.93, libcosmic 1.93, Slint 1.95, cosmic-comp 1.95) [3][4][9][10][11]. The default-branch numbers are what applies if we pin git revisions (see Consequences). Either way, an older MSRV would bring no benefit.

## Consequences

- The Cargo workspace (#5) can be set up with the toolchain pin and MSRV above.
- Smithay is pre-1.0, and its users depend on git revisions [3][4]. We should expect to do the same, pin revisions in `Cargo.lock`, and budget for upstream API changes.
- Every `unsafe` block needs a `// SAFETY:` comment; a lint in CI (#5 or a follow-up) should enforce this.
- Building from source needs a current Rust toolchain in CI and on developer machines; the image itself carries no toolchain.
- Hiring and outside contributors: Rust narrows the pool compared with C/C++, but matches COSMIC, iced and Slint contributors.

## Open questions

1. Do native apps (C5) count as "system components", or should apps be allowed another language? This write-up assumes they count.
2. Does the owner accept "latest stable" as the MSRV for the product workspace, with N-2 only for published SDK crates?
3. If D-006 picks Slint, is its `.slint` markup accepted as data rather than as a second language?
4. Should C bindings to existing system libraries be limited to well-known crates (for example `input`, `pipewire`, `zbus`), or decided case by case?

## Owner decision (2026-11-03)

D-009 is **Decided**: Rust is the implementation language for system components. Answers to the open questions:

1. Native apps (C5) count as system components and are written in Rust.
2. MSRV is the latest stable Rust for the product workspace; published SDK crates support N-2.
3. If D-006 picks Slint, `.slint` markup counts as data, not as a second language.
4. Third-party crates, including bindings to system libraries, are approved case by case. Add one only when it is clearly trustworthy, maintained and stable, and when it is worth its size; justify it in the pull request. Prefer fewer dependencies over convenience.

## Sources

1. Google Security Blog, "Rust in Android: move fast and fix things", 2025-11-13: <https://blog.google/security/rust-in-android-move-fast-fix-things/>
2. wayland-client on crates.io: <https://crates.io/crates/wayland-client> · repository: <https://github.com/Smithay/wayland-rs>
3. Smithay release v0.7.0: <https://github.com/Smithay/smithay/releases/tag/v0.7.0> · `rust-version`: <https://github.com/Smithay/smithay/blob/master/Cargo.toml> · cosmic-comp `Cargo.toml` (`[patch]` to Smithay git): <https://github.com/pop-os/cosmic-comp/blob/master/Cargo.toml>
4. niri `Cargo.toml` (Smithay from git): <https://github.com/YaLTeR/niri/blob/main/Cargo.toml>
5. libwayland: <https://gitlab.freedesktop.org/wayland/wayland>
6. wlroots releases: <https://gitlab.freedesktop.org/wlroots/wlroots/-/releases>
7. Mutter: <https://gitlab.gnome.org/GNOME/mutter>
8. KWin: <https://invent.kde.org/plasma/kwin>
9. iced 0.14.0: <https://github.com/iced-rs/iced/releases/tag/0.14.0> · `Cargo.toml`: <https://github.com/iced-rs/iced/blob/master/Cargo.toml>
10. libcosmic `Cargo.toml` (`a11y` feature, `rust-version`): <https://github.com/pop-os/libcosmic/blob/master/Cargo.toml>
11. Slint v1.18.1: <https://github.com/slint-ui/slint/releases/tag/v1.18.1> · `Cargo.toml`: <https://github.com/slint-ui/slint/blob/master/Cargo.toml>
12. DevClass, "Rust boosted by permanent adoption for Linux kernel code", 2025-12-15: <https://devclass.com/2025/12/15/rust-boosted-by-permanent-adoption-for-linux-kernel-code/>
13. Cargo Book, "Rust version": <https://doc.rust-lang.org/cargo/reference/rust-version.html>
14. Rust blog, releases: <https://blog.rust-lang.org/releases/>
15. Cargo Book, "Dependency resolution", resolver versions: <https://doc.rust-lang.org/cargo/reference/resolver.html>
16. GTK repository: <https://gitlab.gnome.org/GNOME/gtk>
17. Qt Base repository: <https://code.qt.io/cgit/qt/qtbase.git/> (mirror: <https://github.com/qt/qtbase>)
18. Slint C++ API documentation: <https://docs.slint.dev/latest/docs/cpp/>
19. crates.io `rust-version` of the cited releases: <https://crates.io/api/v1/crates/smithay/0.7.0>, <https://crates.io/api/v1/crates/iced/0.14.0>, <https://crates.io/api/v1/crates/slint/1.18.1>

[wayland-rs]: https://github.com/Smithay/wayland-rs
[Smithay]: https://github.com/Smithay/smithay
[cosmic-comp]: https://github.com/pop-os/cosmic-comp
[niri]: https://github.com/YaLTeR/niri
[libwayland]: https://gitlab.freedesktop.org/wayland/wayland
[wlroots]: https://gitlab.freedesktop.org/wlroots/wlroots
[Mutter]: https://gitlab.gnome.org/GNOME/mutter
[KWin]: https://invent.kde.org/plasma/kwin
[iced]: https://github.com/iced-rs/iced
[libcosmic]: https://github.com/pop-os/libcosmic
[Slint]: https://github.com/slint-ui/slint
