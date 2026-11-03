# D-006: Files prototype brief and evaluation method

Status: method for the D-006 spike (`docs/spec.md` §5). The choices in [section 10](#10-decisions-made-in-this-document) are confirmed by the owner; the document is accepted when its pull request is merged.
Card: #9 · Facts checked: 2026-11-03

D-006 is resolved by building the same small Files app in each candidate toolkit and measuring all of them the same way. This document is the contract for that. It is written before any prototype code exists and does not change while the spike runs; a change needs the owner and applies to every candidate.

| Card | Uses this document for |
| --- | --- |
| #10, #11 | [The prototype](#3-the-prototype), [Exclusions](#4-exclusions), [Fixture](#5-fixture) |
| #12 | [Environments](#6-environments), [Metrics](#7-metrics) |
| #13 | [Agent extensibility test](#8-agent-extensibility-test) |
| #14 | [Scoring table](#9-scoring-table) |

## 1. Adding a candidate

The method names no toolkit outside section 2. To add a candidate, the owner:

1. Adds a row to [Candidates](#2-candidates-and-versions) with an exact version and release link.
2. Creates a prototype card copied from #10, with the directory `spikes/d006-<name>/`.
3. Reruns #12 and #13 for the new candidate (or all candidates, if the environment changed) and adds a column to the scoring table in #14.

## 2. Candidates and versions

| Candidate | Version to use | Release | Rust MSRV | Licence | AccessKit |
| --- | --- | --- | --- | --- | --- |
| libcosmic | git rev [`daca62bb701bdc2cefbf44d6e87dc5d0c2f1835f`][libcosmic-rev] (master, 2026-11-03); bundles the pop-os/iced fork at [`229186b5`][pop-iced-rev] (iced 0.14.0 based) | No release: no crates.io crate, and the newest tag, `v0.12`, is far behind the `1.0.0` in its `Cargo.toml`; COSMIC's own apps use git [1] | 1.93 | MPL-2.0 | `a11y` feature, on by default |
| Slint | [1.18.1][slint-release] (2026-09-21), crate `slint = "=1.18.1"` | GitHub release and crates.io [2] | 1.92 | GPL-3.0-only, Royalty-free 2.0 or Software 3.0 (choice) | `accessibility` feature, on by default |

Both build with the workspace toolchain, Rust 1.99.1 (D-009). Use the toolkit's default features unless a feature in section 3 needs another one; list any change in the prototype README.

**libcosmic rather than plain iced.** The latest iced release, [0.14.0][iced-release] (2025-12-07), has no AccessKit integration: neither its `Cargo.toml` nor the current `master` (0.15.0-dev) depends on `accesskit` [3]. Spec §6 C4 requires accessibility through AccessKit, and §7 makes keyboard and screen reader access a release blocker, so a candidate without it would fail a gate before any measurement. libcosmic carries AccessKit support in its iced fork and enables it by default [1]. It is also the toolkit of the COSMIC desktop and of COSMIC Files, so the result feeds D-007 directly. The costs, which #14 must weigh: no versioned release (we pin a git revision, as D-009 already expects for Smithay), more dependencies than plain iced, and COSMIC Files itself currently builds libcosmic with the `a11y` feature off, with the comment `#TODO: a11y feature crashes` [4]. If `a11y` crashes the prototype, #10 records it, keeps the rest working without it, and states it in the README; it is not worked around.

**Slint licence for the spike.** Spike code is not distributed, so any of Slint's options works for #11; #11 names the one in its README. Which option the product would use is a #14 question.

## 3. The prototype

One window, one process, written in Rust against the toolkit's public API. Every candidate implements exactly this list.

### Launch contract

- `<binary> [start-folder]`. Without an argument the start folder is `$HOME`.
- The window title is `Files`. The initial window is 1280 × 800 logical pixels at scale 1.
- Release build with Cargo's default `release` profile: no custom `opt-level`, LTO or codegen settings.
- Accessible roles and names are exactly those in [M6](#m6-accessibility-tree).
- Dependencies: the toolkit, and only the crates the toolkit itself requires. The file system is read with `std::fs` (`read_dir`, `symlink_metadata`). Anything else needs a justified line in the README.

### Features

1. **Sidebar with places.** A vertical list on the left with three entries, in this order: *Home* (`$HOME`), *File system* (`/`), *Start folder* (the start folder). Activating one navigates the list to it.
2. **Path label and Up button.** Above the list: a read-only label with the current absolute path, and a button named *Up* that goes to the parent folder (disabled at `/`).
3. **List view of a folder.** One row per entry with three columns: *Name*, *Size*, *Modified*.
   - Folders first, then files; each group sorted by name in byte order (Rust `str` ordering).
   - Hidden entries (name starts with `.`) are shown like any other.
   - Size: bytes in decimal units with one decimal (`345.7 kB`, `1.0 MB`, `120 B`); folders show `Folder`.
   - Modified: `YYYY-MM-DD HH:MM` in local time.
   - Text only. No icons.
   - At most one row is selected; a single click selects it.
   - On start and after every navigation (into a folder, up, or to a place) no row is selected and the list is scrolled to the top.
   - If the toolkit has a virtualised list widget, use it. If it has none, the prototype may build one from public API; the README states how many lines that took.
4. **Navigate into and up folders.** Double-click or Enter on a folder row opens it. *Up*, Backspace and Alt+Up go to the parent. On a file row, double-click and Enter print `SPIKE_OPEN <absolute path>` on stdout and do nothing else. A folder that cannot be read shows its error message in the list area instead of rows; the app does not crash.
5. **Keyboard navigation of the list.** Up and Down move the selection by one row, Page Up and Page Down by one visible page, Home and End to the first and last row; with no row selected, Down or Home selects the first row and End the last. The selected row is always scrolled into view. On start, keyboard focus is on the list. Tab and Shift+Tab move focus in the order sidebar → Up button → list. When focus enters the sidebar it lands on *Home*. In the sidebar, Up and Down move between places and Enter activates one; focus stays in the sidebar. Focus is visible.
6. **Context menu with 3 actions.** Right-click on a row selects it and opens a menu at the pointer; the Menu key or Shift+F10 opens it for the selected row. The menu opens with *Open* focused; Up and Down move between items, Enter activates, Escape closes. The actions:
   - *Open*: the same as double-click on that row.
   - *Copy Path*: puts the row's absolute path as text on the system clipboard.
   - *Properties*: opens a modal dialog titled *Properties* with the entry's name, absolute path, size in bytes (`Folder` for folders), and modified time, and one *Close* button (Escape also closes).
7. **Opening a 10,000-item folder.** The `10k` folder of the [fixture](#5-fixture) opens through any of the above (start folder, place, navigation) and stays usable: selection, keyboard navigation and scrolling work across all rows.

### Measurement hooks

These are the only additions beyond the features. They are part of the brief so every candidate measures the same thing.

- **`BUDGET_FIRST_FRAME`.** Print this line on stdout and flush it when the first frame that shows the start folder's rows is presented (#8 convention, `docs/budgets.md`). A frame that shows an empty or loading list does not count. The README names the toolkit hook used to detect presentation.
- **Autoscroll.** With the environment variable `D006_AUTOSCROLL=1`, after the first frame the list scrolls itself down from the top at a constant 2,000 logical pixels per second, driven by the toolkit's per-frame callback (or a timer at the output refresh rate if it has none; the README says which), for 10 s or until the end of the list. It then prints `D006_AUTOSCROLL_DONE` and exits with status 0.

## 4. Exclusions

The prototypes must not include anything else, so that differences come from the toolkits and not from the work put in. In particular:

- No design tokens, theming, custom styles, fonts or colours: toolkit defaults only.
- No icons, thumbnails or file previews.
- No other file operations: no copy, move, rename, delete, trash, create, drag and drop.
- No tabs, split view, search, tags, sorting by column, column resizing, multiple selection or a path bar you can type in. (Tabs and rename are the [agent test](#8-agent-extensibility-test).)
- No file watching (inotify), mounts, MIME types or opening files in other apps.
- No custom renderer, shaders or bypassing of the toolkit's layout and widgets for speed. Virtualising the list from public API when the toolkit lacks it is the one allowed exception.
- No platform code outside the toolkit: no direct Wayland, D-Bus or AT-SPI calls.
- No caching across runs and no work before the first frame that a normal Files app would not do.

## 5. Fixture

`make-fixture.sh <new-dir>` creates the test tree. It is plain POSIX `sh`, so it runs the same in the dev VM (#16), on CI runners and on the reference hardware. The first of #10 and #11 that needs it commits it unchanged to `spikes/d006-fixture/make-fixture.sh` (if both do, the identical file merges cleanly). It refuses to overwrite an existing directory. It takes about a minute, mostly in `touch` and `dd` processes; files are sparse, so the tree uses almost no disk.

```sh
#!/bin/sh
# D-006 fixture: same names, sizes and mtimes on every run (POSIX sh, no GNU extensions).
set -eu
root=${1:?usage: make-fixture.sh <new-dir>}
[ ! -e "$root" ] || { echo "make-fixture.sh: $root already exists" >&2; exit 1; }
export TZ=UTC LC_ALL=C

# file <path> <size in bytes>: sparse file of that size
file() { dd if=/dev/zero of="$1" bs=1 count=0 seek="$2" 2>/dev/null; }
# stamp <path> <minutes after 2026-01-01 00:00 UTC> (< 31 days)
stamp() { touch -t "$(printf '202601%02d%02d%02d' $(($2 / 1440 + 1)) $(($2 % 1440 / 60)) $(($2 % 60)))" "$1"; }

mkdir -p "$root/small/docs/2026/november" "$root/small/empty" "$root/10k"
for f in notes-1.txt:120 notes-2.txt:2048 notes-3.txt:0 photo.png:345678 report.pdf:1048576 \
    'with space.md':64 'Ünïcödé.txt':10; do
    file "$root/small/${f%:*}" "${f##*:}"
done
i=1
while [ "$i" -le 10000 ]; do
    p=$(printf '%s/10k/item-%05d' "$root" "$i")
    if [ $((i % 100)) -eq 0 ]; then
        mkdir "$p"
    else
        case $((i % 5)) in 0) e=txt ;; 1) e=png ;; 2) e=pdf ;; 3) e=rs ;; *) e=md ;; esac
        p=$p.$e
        file "$p" $((i * 7919 % 1048576))
    fi
    stamp "$p" "$i"
    i=$((i + 1))
done
# Children first, so creating entries does not move a folder's mtime afterwards.
find "$root/small" -depth -exec touch -t 202601010000 {} +
stamp "$root/10k" 0
stamp "$root" 0
```

The result:

- `small/`: folders `docs/` (with `2026/november/` inside, for navigating three levels down and back up) and `empty/`; files `notes-1.txt`, `notes-2.txt`, `notes-3.txt`, `photo.png`, `report.pdf`, `with space.md`, `Ünïcödé.txt` with fixed sizes from 0 B to 1 MB. All modified 2026-01-01 00:00 UTC.
- `10k/`: exactly 10,000 entries, `item-00001` to `item-10000`. Every 100th is an empty folder (100 folders); the rest are files with extensions cycling through `png`, `pdf`, `rs`, `md`, `txt`, sizes `i × 7919 mod 1,048,576` bytes and modified times one minute apart.

To check that two machines made the same tree, compare this digest (Linux, GNU `find`); #12 records it with its results. It prints times in UTC and sizes for files only, because a folder's size depends on the file system:

```sh
(cd <dir> && TZ=UTC find . \( -type f -printf '%p f %s %TY%Tm%Td%TH%TM\n' \) -o \( -type d -printf '%p d %TY%Tm%Td%TH%TM\n' \) | LC_ALL=C sort | sha256sum)
```

## 6. Environments

| Environment | What it is | Counts toward §7 budgets |
| --- | --- | --- |
| Dev VM (#16) | aarch64 Linux VM on the owner's Mac, headless Wayland compositor, software rendering | No. For building, functional checks, accessibility and the agent test |
| CI | GitHub-hosted `ubuntu-24.04` (x86_64), headless compositor, software rendering | Indicative only (`docs/budgets.md`) |
| Reference hardware (#17) | Intel NUC 11, Celeron N5105, x86_64, its integrated GPU | Yes |

All candidates are measured in the same environment in the same run, and results always name the environment: machine, CPU, renderer (GPU or software, and which backend the toolkit picked), compositor and version. Comparisons between candidates are valid within one environment; absolute numbers count against §7 only from the reference hardware.

**Compositor for measurements.** Key injection for the keyboard walkthrough needs the `virtual-keyboard-unstable-v1` protocol. The named default is sway with the headless backend and the pixman (software) renderer, with `wtype` for keys:

```sh
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c d006-sway.conf
```

where `d006-sway.conf` is:

```text
output HEADLESS-1 mode 1920x1080@60Hz scale 1
for_window [title="^Files$"] floating enable
```

so there is one output at 1920 × 1080, 60 Hz, scale 1, and the prototype floats at its own 1280 × 800 size instead of being tiled to fill the output. If the dev VM from #16 has only another headless compositor, #12 installs sway there and says so. On the reference hardware #12 uses sway on the real display (DRM backend) at its native refresh rate.

## 7. Metrics

Every number is the median of at least 5 runs, with the minimum and maximum reported and the raw data committed (#12). Release builds only.

| # | Metric | How | Tool |
| --- | --- | --- | --- |
| M1 | Cold start | `budgets ./d006-small`, where `d006-small` is the wrapper below for `<fixture>/small`: time from spawn to `BUDGET_FIRST_FRAME`. Budget §7: ≤ 300 ms | `tools/budgets` (#8) |
| M2 | 10,000-item first paint | `budgets ./d006-10k` (wrapper for `<fixture>/10k`): the same marker, with the 10k folder as start folder. Budget §7: ≤ 500 ms. This includes app start-up, so it is stricter than the budget | `tools/budgets` |
| M3 | Idle RSS | From the M1 runs: `VmRSS` 5 s after the first frame, decimal MB. Reported against the 800 MB desktop budget and compared between candidates | `tools/budgets` |
| M4 | Idle CPU | From the M1 runs with `--cpu-window full` (5 minutes), percent of one core. Budget §7: ≤ 1 % | `tools/budgets` |
| M5 | Frame time while scrolling | See below. Report p50, p95, p99 frame interval and dropped frames | `WAYLAND_DEBUG=client` |
| M6 | Accessibility tree | See below. Controls missing a correct role or name | AT-SPI dump script |
| M7 | Keyboard walkthrough | See below. Pass or fail per step | `wtype` |
| M8 | Agent extensibility | [Section 8](#8-agent-extensibility-test) | #13 procedure |
| M9 | Build | Clean release build time (`cargo clean` then `cargo build --release`, wall time), binary size (stripped), number of crates in `Cargo.lock`, lines of Rust and markup in the prototype (blank and comment lines excluded) | `cargo`, `strip`, `wc` |

M1 to M4 use the harness as it is. It passes no arguments to the app, so each start folder gets a two-line wrapper script:

```sh
#!/bin/sh
exec <binary> <folder>
```

`exec` keeps the PID, so the harness measures the app and not the shell. Call the wrapper with a path that contains a `/` (such as `./d006-small`), because the harness otherwise looks the name up in `PATH`.

If a run hits the harness's 3 s marker timeout (exit status 2, no reading), #12 records M1 or M2 for that run as `> 3000 ms (timeout)` and counts it as a gate fail. M3 and M4 are then taken from the `small` runs only. On CI and in the VM the page cache is warm; a true cold cache comes with #17.

### M5: frame time while scrolling

Run `D006_AUTOSCROLL=1 WAYLAND_DEBUG=client <binary> <fixture>/10k > run.log 2>&1`. The Wayland client library logs every request with a millisecond timestamp on stderr; the markers go to stdout, flushed, and stderr is unbuffered, so one file keeps them in order. Take the timestamps of `wl_surface.commit` on the window's main surface (the surface with the most commits) between the first commit after `BUDGET_FIRST_FRAME` and `D006_AUTOSCROLL_DONE`. Frame interval = difference between consecutive commits.

- Report p50, p95 and p99 of the interval in ms, and the count of dropped frames: intervals longer than 1.5 × the output's refresh period (25 ms at 60 Hz).
- This measures how fast the app produces frames, which is what the toolkit controls. Presentation latency and compositor pacing belong to C2 and Phase 1.
- Before relying on it, #12 checks that each candidate's Wayland client library prints timestamps under `WAYLAND_DEBUG=client`. If one does not, #12 asks on its card and moves it to Blocked instead of choosing another method for one candidate only.

### M6: accessibility tree

With the app running on the `small` fixture and the context menu and Properties dialog each opened once, dump the AT-SPI tree with a Python script using `gi.repository.Atspi` (packages `python3-gi`, `gir1.2-atspi-2.0`): for every node, its role, name and states. #12 commits the script and the dumps.

Every control below must be present with the role shown (or the AT-SPI role the candidate's AccessKit mapping produces for it, if equivalent, with the mapping stated) and the exact name:

| Control | Role | Name |
| --- | --- | --- |
| Window | frame or window | `Files` |
| Sidebar | list | `Places` |
| Each place | list item | `Home`, `File system`, `Start folder` |
| Up button | push button | `Up` |
| Path label | label | the current absolute path |
| File list | table or list | `Files` |
| Column headers (if a table) | column header | `Name`, `Size`, `Modified` |
| Each visible row | table row or list item | the entry's name |
| Context menu | menu or popup menu | none required |
| Each menu item | menu item | `Open`, `Copy Path`, `Properties` |
| Properties dialog | dialog | `Properties` |
| Close button | push button | `Close` |

The focused control must carry the `focused` state. Result: a table of controls that are missing, have a wrong role, or have a wrong or empty name.

### M7: keyboard walkthrough

Start `<binary> <fixture>/small`, inject keys with `wtype`, and after each step check the expected result through the AT-SPI tree (selected or focused node), not through screenshots. Each step is pass or fail; a failed step does not stop the walkthrough (reset by restarting the app at that step's start state if needed).

1. Focus is on the list at start and no row is selected. Down selects `docs`.
2. Enter opens `docs`; path label is `<fixture>/small/docs`.
3. Down selects `2026`, Enter opens it; Down selects `november`, Enter opens it: path ends in `docs/2026/november`, no row selected.
4. Backspace goes to `docs/2026`; Alt+Up goes to `docs`.
5. Shift+Tab focuses the Up button; Shift+Tab again focuses *Home* in the sidebar; Down focuses *File system*; Enter opens `/`.
6. Down focuses *Start folder*; Enter returns to `small`; Tab twice focuses the list.
7. In the list, End selects `Ünïcödé.txt` (byte order puts it last); Home selects `docs`.
8. Shift+F10 opens the context menu; Down twice and Enter opens *Properties*; Escape closes the dialog and focus returns to the list.
9. Down twice selects `notes-1.txt`; Menu key, Down once (*Copy Path*), Enter: the clipboard holds the file's absolute path (check with `wl-paste`).
10. Escape closes an open context menu without action.
11. Enter on `notes-1.txt` prints `SPIKE_OPEN <fixture>/small/notes-1.txt`.
12. With `<fixture>/10k` open: End selects `item-09999.md` (the last file; folders sort first), Home selects `item-00100`, and Page Down and Page Up move by one page; each step shows its result in under one second.

## 8. Agent extensibility test

Measures how well an agent with no project memory extends a prototype using only the toolkit's own documentation. #13 runs it exactly as written.

### Setup

- One fresh subagent per run, the same model and settings for every candidate (record the model ID). It has no conversation history and no access to this repository beyond the copy below.
- Its working directory is a fresh copy of `spikes/d006-<name>/` without git history and without the README's notes (keep only the build command), plus a fixture made with [the script](#5-fixture). The copy lives outside the repository and outside any mount of it (for example a directory on the dev VM's own disk), so the subagent cannot read this brief or another candidate's prototype; it is given only that path.
- Before the run, #13 runs `cargo fetch` in the copy. The subagent builds offline (`CARGO_NET_OFFLINE=true`, and `{BUILD_COMMAND}` includes `--offline`), so cargo needs no network during the run.
- Allowed web sources: the toolkit's official documentation site, its API docs (docs.rs; for libcosmic, which is not on crates.io, the hosted rustdoc at <https://pop-os.github.io/libcosmic/cosmic/>), its repository (source and examples) and its `llms.txt` if one exists. #13 lists the exact URLs per candidate in the results. Nothing else: no search engines, forums or other projects' code.
- It can build and run the app in the dev VM (#16) and use the `wtype` and AT-SPI tools from section 7.
- Limit: 90 minutes of wall time per run. The run stops there and counts as not completed.
- 3 runs per candidate, alternating candidates (A, B, A, B, A, B).

### Prompt

Identical for every candidate except the placeholders:

```text
You are extending a small Files app written in Rust with {TOOLKIT} {VERSION}.
The source is in {DIR}. Build and run it with: {BUILD_COMMAND}
A test folder is in {FIXTURE}/small.

You may read only these sources on the web: {DOCS_URLS}
Do not use any other website. Do not add crates other than what {TOOLKIT} already pulls in.

Add both features below, following the existing code's style.

1. Tabs. A tab bar named "Tabs" above the file list. Ctrl+T opens a new tab showing the current
   folder. Ctrl+W closes the current tab (not the last one). Ctrl+Tab and
   Ctrl+Shift+Tab switch to the next and previous tab. Clicking a tab switches to it.
   Each tab has its own folder and selection. A tab's label is its folder's name
   ("/" for the root).

2. Batch rename. A context-menu action "Rename…" opens a modal dialog titled
   "Batch Rename" for all files (not folders) in the current folder. It has two text
   fields, "Find" and "Replace with", and a live preview list of "old name → new name"
   for every file whose name contains the Find text (plain text, case-sensitive, all
   occurrences). The "Rename" button is disabled while Find is empty or while any new
   name would be empty, contain "/", or equal an existing entry or another new name;
   the dialog then says which name conflicts. "Rename" renames the files on disk,
   closes the dialog and refreshes the list. "Cancel" and Escape close it without changes.
   Every new control has an accessible name equal to its visible label.

Work until both features work, then reply DONE with a short list of what you changed.
If you cannot finish, reply STUCK with what blocks you.
```

### Acceptance checks

After the run, #13 (not the subagent) checks the result on a new fixture copy. The run is *completed* only if every check passes.

1. Builds in release mode without errors; the original features still pass M7 steps 1 to 11.
2. Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+Shift+Tab and clicking a tab behave as described; two tabs keep separate folders and selections; Ctrl+W on the last tab does nothing.
3. In `small`, Find `notes` and Replace with `memo` previews and then renames exactly `notes-1.txt`, `notes-2.txt`, `notes-3.txt` to `memo-1.txt`, `memo-2.txt`, `memo-3.txt`; nothing else on disk changes.
4. Find `notes-1` and Replace with `notes-2` disables *Rename* and names the conflict.
5. Find `notes` and Replace with `a/b` disables *Rename*.
6. Cancel and Escape change nothing on disk.
7. The tab bar (named `Tabs`), each tab, the dialog, both text fields and both buttons appear in the AT-SPI tree with names equal to their labels.

### What #13 records per run

| Field | Definition |
| --- | --- |
| Completed | Yes if all 7 checks pass |
| Checks passed | Count out of 7 |
| Wall time | From sending the prompt to DONE, STUCK or the 90-minute limit |
| Compile-error iterations | Builds or `cargo check` runs that ended with at least one compiler error |
| Wrong-API attempts | Compiler errors caused by a toolkit item that does not exist or is used with the wrong signature (for example E0425, E0433, E0599, E0061, E0308 pointing at toolkit API), counted once per distinct attempt |
| Doc lookups | Pages fetched, grouped by source |
| Diff size | Lines added and removed |
| Agent-ready docs | Per candidate, once: whether an `llms.txt` and Markdown API docs exist (§6 C4) |

A transcript summary per run goes into `docs/decisions/D-006-agent-test.md`; the extended code stays on #13's branch and is not merged.

## 9. Scoring table

#14 fills in one column per candidate, citing #12 and #13 for every number. Rows are grouped by the §2 priorities, in their tie-break order. Each row is either a **gate** (a candidate that fails it cannot be recommended unless #14 shows a credible fix path, for example an upstream fix in progress) or **compare** (better is better; no fixed threshold).

| Priority (§2) | Row | Kind | Source |
| --- | --- | --- | --- |
| 1 Performance and stability | M1 cold start, reference hardware ≤ 300 ms | Gate | #12 |
| | M2 10,000-item first paint, reference hardware ≤ 500 ms | Gate | #12 |
| | M3 idle RSS | Compare | #12 |
| | M4 idle CPU ≤ 1 % | Gate | #12 |
| | M5 frame interval p50 / p95 / p99, dropped frames | Compare (dropped frames on the reference hardware: gate, §7 "no dropped frames") | #12 |
| | Crashes or hangs seen in any run | Gate (0) | #10–#13 |
| 2 Design | Effort to implement design-system tokens (theming model) | Compare | #14, from docs |
| 3 Familiar | Default widgets and behaviour match platform conventions (menus, dialogs, focus) | Compare | #10, #11, M7 |
| 4 Integration | Fit for shell components (layer-shell, popups) as well as apps; fit with D-007 | Compare | #14, #3 |
| Accessibility (§7, release blocker) | M6 controls with missing or wrong role or name | Gate (0 with a fix path) | #12 |
| | M7 keyboard walkthrough steps passed, of 12 | Gate (12) | #12 |
| Agent productivity (D-006) | M8 runs completed, of 3; median wall time; compile-error iterations; wrong-API attempts | Compare | #13 |
| | Agent-ready docs: `llms.txt`, Markdown API docs | Compare | #13 |
| | Headless screenshot testing available (§6 C4) | Compare | #14, from docs |
| Cost and risk | M9 build time, binary size, crate count, prototype lines | Compare | #10, #11, #12 |
| | Licence | Compare | #14 |
| | Project health: release cadence, maintainers, versioned releases | Compare | #14 |

Until the reference hardware (#17) is available, gate rows for performance are filled from CI and marked *provisional*. A provisional gate fail is reported but does not by itself rule out a candidate before #17 numbers exist.

## 10. Decisions made in this document

For the owner to confirm, since the spec does not settle them:

1. libcosmic instead of plain iced, for the AccessKit reason in section 2.
2. The exact feature list, menu actions (*Open*, *Copy Path*, *Properties*) and keyboard map in section 3.
3. M2 is measured as start-up with the 10k folder, using the existing harness unchanged, instead of timing navigation inside a running app.
4. sway headless with `wtype` as the measurement compositor, and `WAYLAND_DEBUG` commit timestamps for frame time.
5. The agent test: tabs plus batch rename, 3 runs per candidate, 90-minute limit.
6. The scoring table has gates and comparisons but no numeric weights; #14 argues the trade-offs in prose.

### Owner decision (2026-11-03)

The owner accepted all six as written, with these details:

- Item 4: the dev VM from #16 ships weston only, which lacks `virtual-keyboard-unstable-v1`. #12 may add `sway` and `wtype` to the package list in `tools/dev-vm/atos.yaml`. #12 reuses the AT-SPI dump from `tools/dev-vm/smoke.sh` as the base for the M6 script. Both `tools/dev-vm/` paths come from #16 (PR #23), which #10 to #12 depend on.
- Item 5: the agent-test subagents use the same model as the project's builder agents; #13 records its model ID.
- Harness timeout (from review of PR #22): a run that hits the harness's 3 s marker timeout is recorded as `> 3000 ms (timeout)` and counts as a gate fail; M3 and M4 are then taken from the `small` runs only.

## Sources

1. libcosmic: [`Cargo.toml`][libcosmic-cargo] (version 1.0.0, `rust-version = "1.93"`, default features include `a11y`), [tags][libcosmic-tags], [licence][libcosmic-licence] (MPL-2.0).
2. Slint 1.18.1: [release][slint-release], [`slint` features][slint-cargo] (`accessibility` in `default`), [crates.io][slint-crate] (`rust-version` 1.92, licence expression).
3. iced: [0.14.0 release][iced-release], [`Cargo.toml` at 0.14.0][iced-cargo] (no `accesskit`), [`master`][iced-master] (0.15.0-dev, no `accesskit`).
4. COSMIC Files [`Cargo.toml`][cosmic-files-cargo] (libcosmic with `default-features = false` and `#TODO: a11y feature crashes`).

[libcosmic-rev]: https://github.com/pop-os/libcosmic/commit/daca62bb701bdc2cefbf44d6e87dc5d0c2f1835f
[pop-iced-rev]: https://github.com/pop-os/iced/commit/229186b5180b6217d93866c912e6373ac378b231
[libcosmic-cargo]: https://github.com/pop-os/libcosmic/blob/daca62bb701bdc2cefbf44d6e87dc5d0c2f1835f/Cargo.toml
[libcosmic-tags]: https://github.com/pop-os/libcosmic/tags
[libcosmic-licence]: https://github.com/pop-os/libcosmic/blob/master/LICENSE
[slint-release]: https://github.com/slint-ui/slint/releases/tag/v1.18.1
[slint-cargo]: https://github.com/slint-ui/slint/blob/v1.18.1/api/rs/slint/Cargo.toml
[slint-crate]: https://crates.io/crates/slint/1.18.1
[iced-release]: https://github.com/iced-rs/iced/releases/tag/0.14.0
[iced-cargo]: https://github.com/iced-rs/iced/blob/0.14.0/Cargo.toml
[iced-master]: https://github.com/iced-rs/iced/blob/master/Cargo.toml
[cosmic-files-cargo]: https://github.com/pop-os/cosmic-files/blob/master/Cargo.toml
