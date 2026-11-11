# OS Project Specification

Last updated: 2026-11-10 · Owner: Jens Thomae

The single source of truth for what we are building, why, and how agents work on it. If code, a task or a conversation disagrees with this spec, the spec wins until it is changed.

## 1. Read this first

Every agent reads sections 1–3 and 9 at the start of every session, plus the sections for the component it is working on. Agents remember nothing between sessions, so this spec, the task board and the repository are the only memory the project has.

Reading order for a new session:

1. This section, then Mission (2) and Scope (3).
2. Agent operating model (9) and Project management (10).
3. Your task card on the board, including its linked spec sections and the last handoff note.
4. The component specification (6) and quality budgets (7) for your area.
5. The decisions log (5) for anything your task touches.

Non-negotiable rules:

- **Work only on your assigned task.** Anything else you notice becomes a new card on the board, not an unasked change.
- **Never contradict a decided entry in the decisions log.** If you think it is wrong, write a proposal and stop.
- **Never invent requirements.** If the spec is silent or ambiguous, ask the owner or record an open question.
- **Leave a handoff note** on the card before ending a session, using the template in section 9.
- **The spec changes only through the owner.** Agents may propose edits as comments; the owner accepts or rejects them.

## 2. Mission and product priorities

We are building a Linux-based desktop OS that looks as considered as macOS, feels instant, and is fully owned by its user. Linux has a small user base and a large app gap, so the OS must win on feel, trust and integration rather than app count.

The six priorities guide every decision. They are not strictly ranked, but when two conflict in practice, prefer them in this order:

1. **Performance and stability.** A beautiful design that lags or glitches destroys trust. Nothing ships that misses the budgets in section 7.
2. **Beautiful design that feels good.** Design follows the design system. Legibility beats spectacle.
3. **Familiar, with something new.** Windows, macOS and mobile users are productive in minutes. New ideas are added alongside familiar ones, never in place of them.
4. **AI integration, with the user in control.** Users can build their own apps with an assistant, and assistants can operate every system feature and app through standard interfaces (C12). This should make the computer easier for everyone, disabled or not. Safety and privacy come first: assistants cannot easily do harm, and nothing leaves the machine without the user knowing.
5. **Integration.** Shell and native apps form one product, built on one toolkit and one design system.
6. **Ownership and customisation.** Users can change anything. The OS warns but does not block, and warnings can be turned off.

Positioning in one line: your computer — no account, no ads, no telemetry, nothing that breaks on update.

The design system's token values live in `docs/design/tokens.json`, versioned in this repository; only the owner approves changes to it, and it will keep changing while the owner uses the system. Mockups and the design canvas stay with the owner. Agents doing UI work use only token values and ask if one is missing.

## 3. Scope

Version 1 is a daily-drivable desktop for laptops and desktops with broad hardware support. It is an integrator: it reuses proven Linux components and builds only what defines the experience.

**In scope for v1**

- Wayland compositor and shell: dock-taskbar, top bar, launcher, command palette, control centre, notifications, overview, workspaces.
- Window modes per workspace: floating (default), tree tiling (i3-style), scroll tiling.
- Image-based, signed OS with atomic updates and rollback.
- Native app suite: Files, Text Editor, Image Viewer, Media Player, Terminal, Settings, Software, Screenshot and Recorder, PDF Viewer, Archive Manager, Calculator, System Monitor.
- One Software app covering Flatpak apps, web apps and Windows apps through Proton/Wine.
- Declarative configuration, design-token theming and a versioned extension API.
- Phone integration via the KDE Connect protocol.
- A first-run flow with layout presets and no account requirement.
- Agent integration (C12): system features and native apps expose their actions through MCP, with a permission broker, action log, stop switch and warnings for cloud models.

**Out of scope for v1 (non-goals)**

- Our own display protocol, kernel work or package format. We use Wayland, Linux and Flatpak.
- A phone or tablet OS, or convergence between phone and desktop.
- A global app menu bar.
- An X11 session. Legacy X11 apps run through Xwayland.
- First-class Android apps. Waydroid may be offered later as experimental.
- Our own browser, office suite, mail client or cloud service.
- A production voice assistant. A local voice assistant follows once local models are reliable enough; an experimental version may ship earlier.

## 4. Architecture

The OS is five layers. Everything a user sees is built on one UI toolkit, and everything runs on a signed, read-only base image. Component IDs (C1–C12) match section 6 and are used on every task card.

| Layer (top to bottom) | Components |
| --- | --- |
| Apps | C5 Native apps (Files, Editor, Terminal…) · C7 Software (Flatpak, web, Windows tiers) · Third-party apps (GTK, Qt, Electron, Wine) |
| Experience | C3 Shell (dock, palette, overview) · C6 Search and indexer (apps, files, settings) · C8 Settings (config, tokens, plugins) |
| Toolkit | C4 UI toolkit and SDK: one design system for shell and native apps, accessibility, agent-ready docs |
| System | C2 Compositor (Wayland, 3 window modes) · C10 Privacy (portals and permissions) · C9 Connectivity (Wi-Fi, Bluetooth, phone) · C12 Agent integration (MCP, permission broker) |
| Base | C1 Base OS image and updates: signed read-only image, atomic updates, rollback; Linux, systemd, PipeWire, Flatpak |

Third-party apps are not built on our toolkit; they run through Flatpak and are themed to look close to native. The installer and first run (C11) sit outside these layers.

## 5. Decisions log

This log records every architectural decision and its status. **Decided** entries are binding for agents. **Proposed** entries need the owner's approval. **Open** entries must be resolved before work in that area starts. New entries get the next ID; entries are never deleted, only superseded. Detailed write-ups live in `docs/decisions/`.

| ID | Decision | Status | Rationale |
| --- | --- | --- | --- |
| D-001 | Wayland only; legacy X11 apps via Xwayland | Decided | GNOME 50 and Plasma 6.8 dropped X11 sessions; no reason to carry it |
| D-002 | Image-based OS with signed images, atomic updates and rollback | Decided | Proven by SteamOS, ChromeOS and Fedora Atomic; core to stability |
| D-003 | Apps distributed as Flatpak, Flathub as default remote | Decided | The de facto Linux app store; sandboxing and portals for permissions |
| D-004 | Customisation only through config, tokens and defined extension points; no shell monkey-patching | Decided | Prevents the GNOME-extension breakage problem |
| D-005 | No account required, no telemetry by default | Decided | Core positioning against Windows 11 |
| D-006 | Slint as the C4 toolkit for the shell and native apps; GPU renderer by default, software renderer as fallback | Decided | Owner (2026-11-06): judged on the target hardware (normal laptops and desktops, GPU rendering); on the reference NUC the GPU paths of both toolkits miss G4 by 1–2 frames, and improving either means changing its code, so accessibility, agent results and maintainability decide. Accessibility, clipboard and layer-shell gaps are carried as our own patches (D-007: no upstream contributions). Binaries that link Slint are GPL-3.0-only (D-013). Shell share of the idle memory budget: 300 MB, single-process shell. See `docs/decisions/D-006-toolkit.md` and `docs/decisions/D-006-measurements.md` |
| D-007 | Fork cosmic-comp (renamed) as the base of C2; C3–C5 are our own code on the D-006 toolkit; no upstream contributions | Decided | Best starting point for a solid compositor, with freedom to change anything. COSMIC does not accept AI-written contributions, and hand-written ones are not an option. C2 is GPL-3.0-only, which the owner accepts. See `docs/decisions/D-007-cosmic-relationship.md` |
| D-008 | bootc on Fedora: sealed composefs images with UKI and systemd-boot; Fedora as base distribution | Decided | Owner (2026-11-06): stable bootc interface and production use, fresh Mesa and kernels for the GPU path (D-006), layer-sized updates. Automatic rollback (§7) is closed by carrying our own boot-counting patch (systemd-boot `+tries` on bootc's composefs UKI entries) until upstream ships it (D-007: no upstream contributions). Fedora's countme is disabled (D-005). See `docs/decisions/D-008-base-image.md` |
| D-009 | Implementation language for system components, native apps included: Rust | Decided | Memory safety, matches iced, Slint and COSMIC. Third-party crates are approved case by case. See `docs/decisions/D-009-rust.md` |
| D-010 | Configuration format: TOML, written with `toml_edit` (format-preserving) and read with `toml` | Decided | Owner (2026-11-06): human-editable and diff-friendly; both TOML and KDL keep comments and ordering on a one-value round-trip, and TOML has the more mature, maintained Rust crates, which matters with no upstream contributions (D-007). See `docs/decisions/D-010-config-format.md` |
| D-011 | Agent interface standard: Model Context Protocol (MCP) | Decided | The standard most AI apps and models already use, so our assistant and third-party agents can control the system and other apps the same way. How the OS maps onto MCP is written up in Phase 0 |
| D-012 | Assistant safety model: every assistant is a sandboxed Flatpak reaching the system only through a permission broker that runs as the user; per-assistant capabilities in the Flatpak permission store, starting empty; a fixed sandbox allowlist checked on every connection; shell-owned confirmations; append-only local action log (default retention 90 days, "Clear log" logged); compositor stop switch that refuses, cancels and freezes; cloud models only through a model gateway that previews and confirms every request; one carried xdg-desktop-portal patch limiting assistants to FileChooser, Documents and Settings | Decided | Owner (2026-11-06): destructive actions are always confirmed in v1 (strict reading of C12); every cloud request is confirmed; after untrusted content all relaxations are suspended, for third-party assistants until *Reset trust*; every accessibility action in network-capable apps is confirmed; developer mode may allow an unsandboxed assistant behind a warning; apps that don't fit the allowlist are listed with the reason. See `docs/decisions/D-012-assistant-safety.md` |
| D-013 | Licensing: our own source is MIT OR Apache-2.0. Shipped binaries carry the licence their dependencies require: C2 is GPL-3.0-only (D-007); binaries that link Slint are GPL-3.0-only | Decided | Keeps our code free to move to another toolkit and leaves third parties free to ship closed-source apps on our SDK under their own Slint licence |
| D-014 | Secure Boot trust by key enrolment at install: per-machine PK (discarded after enrolment) and KEK, no Microsoft KEK, Atos ships dbx updates; db holds the Atos release cert and the Microsoft Option ROM UEFI CA 2023, plus the Microsoft UEFI CA 2011 only where the TPM event log shows option ROMs; Microsoft UEFI and Windows CAs optional. db certs, including the Microsoft CAs, are also kernel-module trust anchors on Fedora's kernel (#158); closing that set is evaluated separately (IPE spike). No shim-review in v1. Release image and Secure Boot keys live on offline hardware tokens held by the owner, who builds release images locally from a reviewed tag; CI holds only test keys; clients enforce `sigstoreSigned` with pinned keys (legacy signature format) | Decided | Owner (2026-11-06): boots on firmware without UEFI CA 2023; no outside party can change a machine's trust (Atos can, through signed updates); no Microsoft or review dependency. See `docs/decisions/D-014-signing-keys.md` |
| D-015 | Developer mode (C1): turning it on enrols a per-machine developer db key with the per-machine KEK (TPM-resident if the signing tools support it, otherwise a root-only file; it also signs the PCR11 policy for developer UKIs). Locally built images FROM the verified release image are sealed, signed with it and booted with `bootc switch` from one fixed local reference, allowed in the trust policy only while developer mode is on. A rebuild service rebuilds and stages automatically on each release, using only the inputs pinned at the last authenticated build. `bootc usr-overlay` is available for transient changes. Signing, switching and toggling developer mode need admin authentication every time, through a shell-owned prompt that shows the warning for every entry point; turning warnings off shortens the dialog but keeps the password. Making `/usr` writable for the current boot (`bootc usr-overlay`, `dnf install --transient`) also requires admin authentication. Developer-signed boots unlock the disk silently by default, TPM2 + PIN optional. Unsandboxed assistants (D-012) are a separate switch inside developer mode. Turning it off disables unsandboxed assistants, boots the release image in both deployment slots and only then removes the key from db (no dbx entry). The warning and in-session indicator can be hidden; the developer boot-entry label cannot. Turning Secure Boot off is the user's firmware choice and is documented, not offered | Decided | Owner (2026-11-07): the only option that allows persistent own builds while keeping offline protection; reuses D-014's enrolment; one machine, reversible. Accepted cost: while it is on, a runtime root compromise can persist by signing with the developer key. See `docs/components/c1-base/developer-mode.md` |
| D-016 | Secure Boot fallback B2 (amends D-014): on machines where key enrolment in setup mode is impractical, keep the firmware's Microsoft KEK/db, boot a pinned, Microsoft-signed Fedora shim with MokManager, and enrol the Atos release cert as a MOK. The release cert must not be a MOK CA cert (no keyCertSign), `MokListTrusted` is turned off, and the TPM disk binding also covers PCR14. Neither limits kernel module trust: on Fedora's kernel every MOK, db cert and shim's vendor cert verifies kernel modules (#158). B2 machines trust Microsoft and Fedora as well as Atos, an explicit exception to D-014's "no outside party can change a machine's trust" | Decided | Owner (2026-11-07): many ordinary laptops make setup mode impractical; without B2 they would get no Secure Boot. Spike #76 showed it works on x86_64 and aarch64. See `docs/components/c1-base/shim-mok-spike.md` |
| D-017 | NVIDIA graphics: one image for everyone. It ships NVIDIA's open kernel modules (Turing and newer), built from source and signed with the Atos key, and NVIDIA's proprietary userspace and GSP firmware unmodified, with NVIDIA's licence included and shown in the installer and Settings → About. Pre-Turing GPUs use nouveau + NVK as best effort; no prebuilt closed module. NVK is in every image. A kernel update ships only once the NVIDIA modules build against it and pass the smoke test on the owner's machine. The owner accepts NVIDIA's distributor terms, including the clause 2.11 indemnity | Decided | Owner (2026-11-08): a single image for simplicity, after the licence terms were presented. See `docs/decisions/nvidia-graphics.md` |
| D-018 | Performance budgets (§7) gate phase gates and releases, not pull requests. They are measured nightly on `main` on the NUC; a clear regression opens a card and nobody is blocked by it. Security lane and correctness tests are unchanged. Reviewers do not ask for budget measurements on ordinary changes; a card asks for a budget check only when the change is performance work or a phase gate. Three existing automated checks still fail a pull request on a budget breach (the `ci.yml` Budgets step, install time ≤ 600 s in `c11-installer.yml`, `SHELL_GATE` in the C3 e2e check) and stay as they are until the owner decides card #240. | Decided | Owner (2026-11-11): build as much of the system as possible first and tune performance as we go, for a faster development flow while design, features and feel are settled. Card #237 |

## 6. Component specifications

Each component has a short ID used on task cards, a purpose and its hard requirements. Detailed specs per component will be added under `docs/components/` as work starts; until then, these requirements are the contract.

### C1 Base OS and updates

- Read-only, signed system image; user data and apps live outside it.
- Updates download and stage in the background; they apply on the next restart.
- The last known-good image is always bootable from a "Previous version" boot entry, no terminal needed.
- Full-disk encryption on by default at install.
- A developer mode allows a writable overlay or package layering, behind a dismissible warning.
- Atos supports normal laptops and desktops broadly, like Windows does. Intel, AMD and NVIDIA graphics are all supported with GPU rendering; NVIDIA gets particular care because it is often problematic on Linux.

### C2 Compositor

- Wayland compositor with Xwayland for legacy apps.
- Variable refresh rate, HDR, 120 Hz+ frame pacing, per-monitor fractional scaling.
- Three window modes per workspace: floating, tree tiling, scroll tiling. Tree tiling follows i3: manual horizontal and vertical splits, tabbed and stacked containers; it is the primary tiling style. Switch with Super+T or from the dock-taskbar.
- Workspaces per monitor; gestures track the touchpad 1:1.
- All window animations use the shared motion tokens and never block input.

### C3 Shell

- Dock-taskbar, optional top bar, launcher, command palette (Super+Space), control centre, notification centre, overview, shortcut cheat sheet.
- Three layout presets: Balanced (default), Classic Mac, Focused.
- Privacy indicator whenever camera, microphone or screen capture is active.
- Every shell action has a rebindable shortcut and appears in the command palette.
- The command palette evaluates calculations inline and copies the result.

### C4 UI toolkit and SDK

- One toolkit for shell and native apps (decision D-006).
- Implements every component and token in the design system.
- Accessibility through AccessKit: screen reader, keyboard navigation, high contrast. Accessibility gaps block release.
- The accessibility tree is complete (every control has a role and name), because assistants use it as the fallback way to operate apps (C12).
- Documentation written for humans and agents: an llms.txt file, the full API as Markdown, one runnable example per widget.
- A headless inspection and screenshot-test harness so agents can verify UI changes themselves.
- Matching themes for GTK and Qt apps so third-party apps look close to native.

### C5 Native apps

- The v1 app suite listed in section 3, each built on C4 and the shared app skeleton.
- Files: tabs, split view, spacebar preview, tags, instant search, batch rename, network and cloud mounts, undoable file operations.
- Context menus open in one frame; third-party actions load asynchronously in a submenu.

### C6 Search and indexer

- One system index for apps, files, settings and commands, used by the command palette and Files.
- Indexing runs at low priority and pauses on battery below a threshold.

### C7 Software and app distribution

- One Software app with separate tiers: Flatpak apps, web apps, Windows apps via Proton/Wine.
- App permissions shown before install and editable afterwards.
- An `os` command-line tool that mirrors every Settings option; Homebrew-style user packages and Distrobox for developers.

### C8 Settings, configuration and extensions

- One Settings app with a searchable sidebar and a "Show advanced" toggle per page.
- Every setting is stored in a readable config file (decision D-010); Settings and the file never disagree.
- Versioned extension API with defined extension points: shell applets, palette providers, tiling layouts, file actions. Extensions run out of process or in WASM.
- Risky changes show a warning that can be disabled in Settings → Advanced.
- An option to derive the OS colour theme from the wallpaper; derived colours still meet the §7 contrast budgets.

### C9 Connectivity and devices

- Wi-Fi, Bluetooth, audio routing, displays and printers configurable from the control centre and Settings.
- Phone integration via the KDE Connect protocol: notifications, clipboard, file transfer, messages.
- Suspend, resume and battery behaviour validated on every device we test.

### C10 Privacy and security

- No telemetry by default; any future diagnostics are opt-in and anonymous.
- Camera, microphone, screen capture, location and file access go through portals with clear prompts.
- A Privacy page in Settings lists every permission granted to every app.
- Cloud models are opt-in per provider and show a clear warning when turned on. Local models are the default.
- Before data goes to a cloud model, the user sees what will be sent. Sensitive data (passwords, files in protected folders, screen contents) needs confirmation every time.

### C11 Installer and first run

- Installation in under 10 minutes with encryption on by default.
- Dual boot with Windows is supported: install into free space next to an existing Windows; Windows appears in the boot menu and keeps booting with Secure Boot and BitLocker unchanged.
- First run: language, Wi-Fi, layout preset, accent colour, optional import of Windows user folders. No account required.

### C12 Agent integration

- System features (settings, files, windows, notifications, search, connectivity) and native apps expose their actions as MCP servers (D-011). Third-party apps that speak MCP plug in the same way.
- Apps without MCP can be operated through their accessibility tree (C4), under the same permissions.
- A permission broker (D-012) gives each assistant only the capabilities the user granted. Destructive, irreversible or outbound actions need confirmation every time.
- Users may relax confirmations per assistant. There is no global off switch, and data leaving the machine always needs confirmation.
- Assistants run sandboxed, with no root or unrestricted shell access by default.
- An indicator shows while an assistant acts; an action log records everything it did; one stop switch halts all assistants; the Privacy page lists each assistant and its permissions.
- Users can build their own apps with an assistant on the toolkit and SDK; those apps get the same agent interface and permissions as native apps.
- A local voice assistant follows after v1, once local models are reliable enough; an experimental version may ship earlier.

## 7. Quality budgets

The performance budgets (Input, Shell, Apps and System rows) gate phase gates and releases, not individual pull requests (D-018). They are measured automatically on the reference hardware wherever possible: an Intel NUC 11 with a Celeron N5105, deliberately low-end. They are measured nightly on `main`; a clear regression becomes a card, and nobody is blocked by it. A card names a performance budget in its acceptance criteria only when the change is performance work or a phase gate. The Stability and Accessibility rows are unchanged and still checked on pull requests as before. Security lane and correctness tests are unchanged. The numbers are proposed starting targets and can be tightened.

| Area | Metric | Budget |
| --- | --- | --- |
| Input | Pointer and keystroke to pixel on screen | ≤ 30 ms |
| Input | Visual feedback after a click or press | Next frame |
| Shell | Context menu, popover or command palette fully visible | ≤ 100 ms |
| Shell | Frame pacing during animations and gestures | No dropped frames at the display's refresh rate |
| Apps | Cold start of a native app to first usable frame | ≤ 300 ms |
| Apps | Files: open a folder of 10,000 items | ≤ 500 ms to first paint |
| System | Idle desktop RAM after login | ≤ 800 MB |
| System | Idle desktop CPU | ≤ 1% averaged over 5 minutes |
| System | Boot to usable desktop on reference hardware | ≤ 10 s |
| Stability | Crashes of shell or native apps | 0 known crashers at release |
| Stability | Failed update | Automatic rollback to the previous image |
| Accessibility | Every native app | Fully usable by keyboard and screen reader |
| Accessibility | Text contrast in every theme | ≥ 4.5:1 body, ≥ 3:1 large text |

## 8. Roadmap

Work runs in five phases. A phase ends only when its gate is met and the owner signs it off; no cards from the next phase move to Ready before that. Phases have no dates yet; set them after Phase 0, once the toolkit is chosen.

| Phase | Contents | Exit gate |
| --- | --- | --- |
| 0 · Foundations | Decide toolkit, COSMIC relationship, base image (D-006 to D-008). Repo, CI, budget harness, board set up | D-006 to D-008 decided; CI measures budgets |
| 1 · Bootable base | Signed image with updates and rollback, compositor, installer. Minimal shell: dock-taskbar, launcher, control centre. Assistant safety model (D-012) | Boots and updates on the reference hardware |
| 2 · Core experience | Full shell, command palette, three window modes. Files, Settings, Terminal, Text Editor on the toolkit | Owner daily-drives it for two weeks |
| 3 · App suite and software | Remaining v1 apps, Software app, search and indexer. Phone integration, privacy page, first-run flow, agent integration (C12) | Every v1 feature works; zero known crashers |
| 4 · Public beta | Extension API, theming. Public docs and SDK for third-party developers | Release checklist met; public beta ships |

The order follows the main risk: decide the foundations first, then prove a bootable, updatable system before investing in the app suite.

## 9. Agent operating model

The project runs like a small engineering company in which every engineer starts each day with no memory. Alignment therefore comes from written context and small, well-defined tasks, not from conversation. The owner sets direction and approves decisions; agents plan, build, review and document.

### Roles

| Role | Who | Does | Does not |
| --- | --- | --- | --- |
| Owner | Jens | Sets priorities, approves decisions and spec changes, accepts finished work | Write every task by hand; a planner agent drafts them |
| Planner agent | One agent per planning session | Breaks a roadmap phase into task cards, keeps the board tidy, writes weekly status | Write production code |
| Builder agent | One agent per task | Implements one card on its own branch, with tests | Change the spec, pick up unassigned work, touch other components |
| Reviewer agent | A fresh agent that did not build the work | Checks the change against the card and spec; runs a performance budget check only if the card asks for one; approves or requests changes | Fix the code itself |
| Docs agent | As needed | Keeps component specs, the decisions log and the glossary in sync with merged work | Invent decisions |

### Session protocol

Every builder session follows the same steps:

1. Read the files in section 1's reading order, then the card and its last handoff note.
2. Move the card to **In progress** and write a three-line plan on it.
3. Work on a branch named after the card ID, for example `T-142-files-split-view`.
4. Run the tests for the component, and the performance budget checks only if the card asks for them.
5. Open a pull request linked to the card; move the card to **Review**.
6. Write the handoff note and end the session.

### Handoff note template

Every card gets a note at the end of each session:

- **Done:** what was finished, with links to commits or the pull request.
- **Not done:** what remains and why.
- **Decisions made:** anything chosen that is not in the spec, flagged for the owner.
- **Next step:** the first thing the next agent should do.
- **Risks or questions:** anything that blocks or may surprise.

### Definition of done

A card is done only when all of these hold:

- [ ] The acceptance criteria on the card are met.
- [ ] Tests exist and pass in CI.
- [ ] Performance budget checks pass if the card asks for them; otherwise the nightly run on `main` covers them. The accessibility, contrast and stability rows of section 7 still pass.
- [ ] UI changes match the design system and have screenshot tests.
- [ ] A reviewer agent approved the change, and the owner accepted it. The owner delegates acceptance to the planner for cards that decide nothing, change no spec text and touch no security-relevant code. Delegated acceptance means the reviewer's approval is enough to accept the work. The merge itself still needs the owner's OK in the planner session; one OK may cover a batch of fast-lane pull requests.
- [ ] Affected component docs are updated; spec changes are proposed on the card, and the owner accepts them (section 1).
- [ ] User-visible behaviour has a page under `docs/user/`.

### Lanes

Every card is in one lane. The planner names it on the card.

- **Fast lane:** only `components/*/ui/**/*.slint`, `docs/design/tokens.json`, the generated `tokens.slint` and screenshot references change. One polish card may collect the tweaks of one sitting with the owner (one branch, one PR; the handoff note lists the changes). The reviewer checks tokens-only values, screenshot diffs and accessibility tests; it is accepted under the planner delegation.
- **Standard lane:** everything else.
- **Security lane:** permissions, sandboxing, signing, trust policy, network, the C12 broker, CI workflows, and anything in C1 or C11 that changes what boots or what is trusted. As standard, plus Opus for builder and reviewer, and the owner always accepts.

The security lane takes precedence. Security warnings, prompts, confirmations and privacy indicators are never fast lane, wherever their files are. A fast-lane change may alter look and layout, but not remove or rename a callback, a text or an accessibility property.

### Rules for keeping agents aligned

- **Small cards.** One card is about one session of work: a single feature slice with a clear finish line.
- **Context in files, not chat.** Anything an agent needs to know must be in this spec, the repo or the card.
- **Separate building from reviewing.** The agent that wrote the code never approves it.
- **One owner per component at a time.** Two agents never edit the same component in parallel. Spikes in separate directories under `spikes/` may run in parallel.
- **Escalate instead of guessing.** An unclear requirement becomes a question on the card and the card moves to **Blocked**.

## 10. Project management

The board lives next to the code: **GitHub Issues with a GitHub Projects board**. Coding agents already work in the repository and can read and update issues with the `gh` command-line tool, so the board, branches and pull requests stay linked automatically.

What lives where:

| Lives in | Contents | Changed by |
| --- | --- | --- |
| `docs/spec.md` (this file) | Mission, scope, architecture, decisions, budgets, agent rules | Owner, or agents via approved proposals |
| `CLAUDE.md` (and optionally `AGENTS.md`) at the repo root | A one-page summary of section 1 and links into `docs/`, read automatically by coding agents | Owner |
| `docs/planner.md` | The planner's standing rules and lessons | Owner, or planner via the owner |
| `docs/user/` | User documentation for user-visible behaviour | Builder and docs agents through reviewed pull requests |
| Board (GitHub Projects) | Task cards, status, handoff notes | Planner, builder and reviewer agents; owner |
| Repository | Code, tests, component specs, budget checks | Builder agents through reviewed pull requests |

### Board columns

1. **Backlog:** ideas and future work; not yet specified.
2. **Ready:** fully specified cards an agent can start without asking anything.
3. **In progress:** one agent assigned; limit of one card per component, except spike cards working in separate `spikes/` directories.
4. **Blocked:** waiting on a decision or another card; the question is on the card.
5. **Review:** pull request open; a reviewer agent and then the owner check it.
6. **Done:** merged and accepted.

A card moves to **Ready** only when every field of the task template (`.github/ISSUE_TEMPLATE/task.md`) is filled in.

### Task card example

```markdown
Component: C5 Native apps
Phase: 2
Spec links: §6 C5, §7 Apps budgets
Depends on: #120
Goal: One sentence on the user-visible outcome.
Acceptance criteria:
- [ ] F3 toggles a second pane with its own path bar
- [ ] Drag and drop between panes copies by default
- [ ] Opening the split view stays within the 100 ms budget
Out of scope: Anything an agent might be tempted to add.
```

### Cadence

- **Planning:** at the start of each phase, a planner agent drafts cards from the roadmap; the owner approves which move to Ready.
- **Weekly status:** a planner agent summarises Done, In progress and Blocked into a short note for the owner, kept in the pinned "Phase status" issue.
- **Decision review:** the owner clears Blocked cards and Open decisions at least once a week, since blocked agents cannot move on.

## 11. Glossary

Use these terms exactly, in code, docs and cards, so agents don't drift into synonyms.

| Term | Meaning |
| --- | --- |
| Shell | Everything around app windows: dock-taskbar, top bar, launcher, palette, control centre, notifications, overview |
| Dock-taskbar | The floating bottom bar holding pinned and running apps, launcher button, tray and quick settings |
| Command palette | The Super+Space search-and-act field for apps, files, settings, windows and actions |
| Control centre | The quick-settings panel for Wi-Fi, Bluetooth, sound, brightness and similar toggles |
| Window mode | Floating, tree tiling or scroll tiling, set per workspace |
| Tree tiling | i3-style tiling: windows in a tree of horizontal and vertical splits, with tabbed and stacked containers |
| Preset | A shell layout chosen at first run: Balanced, Classic Mac or Focused |
| Token | A named design value (colour, size, radius, motion) shared by shell, apps and themes |
| Extension point | A defined place where third-party code can plug in, such as a palette provider |
| Image | The read-only, signed system snapshot that updates replace atomically |
| Card | One task on the board (a GitHub issue); branches use its number, such as T-142 |
| Budget | A measurable quality limit from section 7 that blocks release if missed. Performance budgets gate phase gates and releases, not pull requests (D-018); the accessibility, contrast and stability budgets are unchanged |
| Owner | The project lead, who approves decisions and accepts work |
| Assistant | An AI agent that acts for the user on the running OS, local or cloud. Not the agents that build this project |
| Agent interface | The MCP servers through which system features and apps expose their actions to assistants (C12) |
| Permission broker | The system service that grants, checks and confirms what each assistant may do (D-012) |
| Action log | The user-visible record of every action an assistant took |
| Stop switch | The single control that halts all assistants at once |
