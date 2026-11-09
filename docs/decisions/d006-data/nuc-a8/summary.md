### Environment

```text
date: 2026-11-08T17:21:07Z
host: nuc
cpu: Intel(R) Celeron(R) N5105 @ 2.00GHz
cores: 4
kernel: Linux 6.8.0-147-generic x86_64
governor: powersave
os: Ubuntu 24.04.5 LTS
sway: sway version 1.9
wtype: 0.4-3
mesa: 25.2.8-0ubuntu0.24.04.4
runs: 5  cpu_window: full
compositor: own  sway_renderer: gles2
d006-iced: 451e97f78eeaba63
d006-iced-wgpu: b058eaff9190f610
d006-slint: 85f7fe54c92f0db7
d006-slint-fork: 63041f50c8cc3dad
output: HEADLESS-1 1920x1080@60Hz scale 1.0
egl: Mesa Intel(R) UHD Graphics (JSL)
fixture digest: 184f3d8ea40f1ef1a3ec2434cfaffa66d1b1d6e03f95226b0cadf742e723022c  -
renderer iced: iced tiny-skia CPU
renderer iced-wgpu: iced Vulkan Intel(R) UHD Graphics (JSL)
renderer slint: slint gl Mesa Intel(R) UHD Graphics (JSL)
renderer slint-sw: slint software (CPU)
renderer slint-fork: slint gl Mesa Intel(R) UHD Graphics (JSL)
renderer slint-fork-a11y: slint gl Mesa Intel(R) UHD Graphics (JSL)
```

### M1–M4: harness (`tools/budgets`)

Median (min–max, n runs). Page cache is warm. M3 and M4 use only the runs that gave a reading.

| Metric | Budget | libcosmic default (tiny-skia) | libcosmic `wgpu` | Slint default (femtovg, GL) | Slint software renderer | Slint fork (GL), tree off | Slint fork (GL), tree on |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M1 cold start, `small` | ≤ 300 ms | **53.0** ms (50.6–58.5, n=5) | **128.5** ms (124.5–250.4, n=5) | **124.8** ms (108.8–307.1, n=5) | **37.1** ms (25.3–45.5, n=5) | **109.1** ms (107.9–117.1, n=5) | **120.8** ms (109.4–125.5, n=5) |
| M2 10,000-item first paint, `10k` | ≤ 500 ms | **87.3** ms (85.8–87.7, n=5) | **157.8** ms (152.8–158.3, n=5) | **150.2** ms (147.8–159.5, n=5) | **89.6** ms (74.2–94.1, n=5) | **160.4** ms (156.6–163.0, n=5) | **159.4** ms (146.5–163.1, n=5) |
| M3 idle RSS, `small`, 5 s after first frame | 800 MB (desktop) | **33.8** MB (33.6–33.9, n=5) | **119.0** MB (118.8–124.7, n=5) | **102.3** MB (101.9–110.2, n=5) | **28.1** MB (27.6–28.1, n=5) | **101.9** MB (101.9–102.1, n=5) | **102.8** MB (102.7–102.9, n=5) |
| M4 idle CPU, `small` | ≤ 1 % | **0.00** % (0.00–0.00, n=5) | **0.00** % (0.00–0.01, n=5) | **0.01** % (0.01–0.02, n=5) | **0.01** % (0.01–0.02, n=5) | **0.01** % (0.01–0.02, n=5) | **0.01** % (0.01–0.02, n=5) |

- libcosmic default (tiny-skia) `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- libcosmic default (tiny-skia) `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- libcosmic `wgpu` `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- libcosmic `wgpu` `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint default (femtovg, GL) `small`: harness exit codes [1, 0, 0, 0, 0], CPU window [300] s
- Slint default (femtovg, GL) `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint software renderer `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- Slint software renderer `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint fork (GL), tree off `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- Slint fork (GL), tree off `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint fork (GL), tree on `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- Slint fork (GL), tree on `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s

### M5: frame interval while scrolling the 10,000-item list

Median over runs of each run's value (min–max). Dropped = intervals > 1.5 × refresh period.

| | libcosmic default (tiny-skia) | libcosmic `wgpu` | Slint default (femtovg, GL) | Slint software renderer | Slint fork (GL), tree off | Slint fork (GL), tree on |
| --- | --- | --- | --- | --- | --- | --- |
| p50 | **75.4** ms (73.7–77.1, n=5) | **16.6** ms (16.6–16.6, n=5) | **16.8** ms (16.7–16.8, n=5) | **16.5** ms (16.4–16.5, n=5) | **16.8** ms (16.8–16.8, n=5) | **16.4** ms (16.4–16.5, n=5) |
| p95 | **244.4** ms (236.0–247.2, n=5) | **17.0** ms (17.0–17.0, n=5) | **17.4** ms (17.3–17.5, n=5) | **17.9** ms (17.9–18.0, n=5) | **17.4** ms (17.3–17.5, n=5) | **18.0** ms (17.9–18.1, n=5) |
| p99 | **259.2** ms (247.0–259.9, n=5) | **20.7** ms (19.2–20.9, n=5) | **18.3** ms (17.8–18.5, n=5) | **18.7** ms (18.3–21.2, n=5) | **18.5** ms (18.1–18.9, n=5) | **18.8** ms (18.3–19.1, n=5) |
| max | **259.4** ms (253.7–266.5, n=5) | **30.2** ms (29.4–30.8, n=5) | **24.9** ms (24.4–26.2, n=5) | **22.2** ms (21.3–23.9, n=5) | **24.6** ms (21.2–25.4, n=5) | **26.0** ms (21.5–27.1, n=5) |
| commits per run | **111** (103–123, n=5) | **598** (598–598, n=5) | **597** (597–601, n=5) | **605** (605–605, n=5) | **597** (597–598, n=5) | **607** (607–607, n=5) |
| dropped frames per run | **66** (57–77, n=5) | **1** (1–2, n=5) | **0** (0–1, n=5) | **0** (0–0, n=5) | **0** (0–1, n=5) | **1** (0–2, n=5) |

### G1–G5: GPU gates (`docs/decisions/D-006-toolkit.md` §4.1)

A variant is evaluated only if its run is proven to use the GPU: the compositor's Wayland `egl:` line and the app's own renderer line must match `Intel` (CPU renderers by design need only the `egl:` line). Otherwise **not measured**, never a GPU number. G5 uses N = 1 and a 300 MB shell share. Every run must be present: 5+ runs, none missing or crashed.

| Variant | Renderer proof | G1 | G2 | G3 | G4 | G5 | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| libcosmic default (tiny-skia) | ✅ `iced tiny-skia CPU` | ✅ | ✅ | ✅ | ❌ | ✅ | **FAIL** |
| libcosmic `wgpu` | ✅ `iced Vulkan Intel(R) UHD Graphics (JSL)` | ✅ | ✅ | ✅ | ❌ | ✅ | **FAIL** |
| Slint default (femtovg, GL) | ✅ `slint gl Mesa Intel(R) UHD Graphics (JSL)` | ❌ | ✅ | ✅ | ✅ | ✅ | **FAIL** |
| Slint software renderer | ✅ `slint software (CPU)` | ✅ | ✅ | ✅ | ✅ | ✅ | **PASS** |
| Slint fork (GL), tree off | ✅ `slint gl Mesa Intel(R) UHD Graphics (JSL)` | ✅ | ✅ | ✅ | ✅ | ✅ | **PASS** |
| Slint fork (GL), tree on | ✅ `slint gl Mesa Intel(R) UHD Graphics (JSL)` | ✅ | ✅ | ✅ | ❌ | ✅ | **FAIL** |

- libcosmic default (tiny-skia): G1 cold start: every launch ≤ 300 ms: ✅ max 58 ms of 5
- libcosmic default (tiny-skia): G2 10k first paint: every launch ≤ 500 ms: ✅ max 88 ms of 5
- libcosmic default (tiny-skia): G3 idle CPU: median ≤ 1 %: ✅ median 0.00 %
- libcosmic default (tiny-skia): G4 scrolling: median 0 dropped, no run above 1: ❌ median 66, max 77 of 5 runs
- libcosmic default (tiny-skia): G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 34 MB
- libcosmic `wgpu`: G1 cold start: every launch ≤ 300 ms: ✅ max 250 ms of 5
- libcosmic `wgpu`: G2 10k first paint: every launch ≤ 500 ms: ✅ max 158 ms of 5
- libcosmic `wgpu`: G3 idle CPU: median ≤ 1 %: ✅ median 0.00 %
- libcosmic `wgpu`: G4 scrolling: median 0 dropped, no run above 1: ❌ median 1, max 2 of 5 runs
- libcosmic `wgpu`: G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 119 MB
- Slint default (femtovg, GL): G1 cold start: every launch ≤ 300 ms: ❌ max 307 ms of 5
- Slint default (femtovg, GL): G2 10k first paint: every launch ≤ 500 ms: ✅ max 160 ms of 5
- Slint default (femtovg, GL): G3 idle CPU: median ≤ 1 %: ✅ median 0.01 %
- Slint default (femtovg, GL): G4 scrolling: median 0 dropped, no run above 1: ✅ median 0, max 1 of 5 runs
- Slint default (femtovg, GL): G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 102 MB
- Slint software renderer: G1 cold start: every launch ≤ 300 ms: ✅ max 45 ms of 5
- Slint software renderer: G2 10k first paint: every launch ≤ 500 ms: ✅ max 94 ms of 5
- Slint software renderer: G3 idle CPU: median ≤ 1 %: ✅ median 0.01 %
- Slint software renderer: G4 scrolling: median 0 dropped, no run above 1: ✅ median 0, max 0 of 5 runs
- Slint software renderer: G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 28 MB
- Slint fork (GL), tree off: G1 cold start: every launch ≤ 300 ms: ✅ max 117 ms of 5
- Slint fork (GL), tree off: G2 10k first paint: every launch ≤ 500 ms: ✅ max 163 ms of 5
- Slint fork (GL), tree off: G3 idle CPU: median ≤ 1 %: ✅ median 0.01 %
- Slint fork (GL), tree off: G4 scrolling: median 0 dropped, no run above 1: ✅ median 0, max 1 of 5 runs
- Slint fork (GL), tree off: G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 102 MB
- Slint fork (GL), tree on: G1 cold start: every launch ≤ 300 ms: ✅ max 125 ms of 5
- Slint fork (GL), tree on: G2 10k first paint: every launch ≤ 500 ms: ✅ max 163 ms of 5
- Slint fork (GL), tree on: G3 idle CPU: median ≤ 1 %: ✅ median 0.01 %
- Slint fork (GL), tree on: G4 scrolling: median 0 dropped, no run above 1: ❌ median 1, max 2 of 5 runs
- Slint fork (GL), tree on: G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 103 MB

### M6: accessibility tree

**libcosmic default (tiny-skia)**: 26 of 26 checked controls missing or wrong. Nodes in the tree: {'initial': 2, 'menu': 2, 'dialog': 2}. Focused node(s): {'initial': [], 'menu': [], 'dialog': []}

| Control | Expected role | Expected name | Result |
| --- | --- | --- | --- |
| Window | frame or window | Files | missing |
| Sidebar | list | Places | missing |
| Place Home | list item | Home | missing |
| Place File system | list item | File system | missing |
| Place Start folder | list item | Start folder | missing |
| Up button | push button | Up | missing |
| Path label | label | /tmp/tmp.8lhTQ7LzRr/fx/small | missing |
| File list | table or list | Files | missing |
| Column header Name | column header | Name | missing |
| Column header Size | column header | Size | missing |
| Column header Modified | column header | Modified | missing |
| Row docs | table row or list item | docs | missing |
| Row empty | table row or list item | empty | missing |
| Row notes-1.txt | table row or list item | notes-1.txt | missing |
| Row notes-2.txt | table row or list item | notes-2.txt | missing |
| Row notes-3.txt | table row or list item | notes-3.txt | missing |
| Row photo.png | table row or list item | photo.png | missing |
| Row report.pdf | table row or list item | report.pdf | missing |
| Row with space.md | table row or list item | with space.md | missing |
| Row Ünïcödé.txt | table row or list item | Ünïcödé.txt | missing |
| Context menu | menu or popup menu | – | no node with that role |
| Menu item Open | menu item | Open | missing |
| Menu item Copy Path | menu item | Copy Path | missing |
| Menu item Properties | menu item | Properties | missing |
| Properties dialog | dialog | Properties | missing |
| Close button | push button | Close | missing |

**Slint default (femtovg, GL)**: 17 of 26 checked controls missing or wrong. Nodes in the tree: {'initial': 40, 'menu': 47, 'dialog': 48}. Focused node(s): {'initial': [['table', 'Files']], 'menu': [['frame', 'd006-slint']], 'dialog': [['push button', 'Close']]}

| Control | Expected role | Expected name | Result |
| --- | --- | --- | --- |
| Window | frame or window | Files | ok |
| Sidebar | list | Places | ok |
| Place Home | list item | Home | ok |
| Place File system | list item | File system | ok |
| Place Start folder | list item | Start folder | ok |
| Up button | push button | Up | ok |
| Path label | label | /tmp/tmp.8lhTQ7LzRr/fx/small | ok |
| File list | table or list | Files | ok |
| Column header Name | column header | Name | wrong role: label |
| Column header Size | column header | Size | wrong role: label |
| Column header Modified | column header | Modified | wrong role: label |
| Row docs | table row or list item | docs | wrong role: label |
| Row empty | table row or list item | empty | wrong role: label |
| Row notes-1.txt | table row or list item | notes-1.txt | wrong role: label |
| Row notes-2.txt | table row or list item | notes-2.txt | wrong role: label |
| Row notes-3.txt | table row or list item | notes-3.txt | wrong role: label |
| Row photo.png | table row or list item | photo.png | wrong role: label |
| Row report.pdf | table row or list item | report.pdf | wrong role: label |
| Row with space.md | table row or list item | with space.md | wrong role: label |
| Row Ünïcödé.txt | table row or list item | Ünïcödé.txt | wrong role: label |
| Context menu | menu or popup menu | – | no node with that role |
| Menu item Open | menu item | Open | wrong role: label |
| Menu item Copy Path | menu item | Copy Path | wrong role: label |
| Menu item Properties | menu item | Properties | wrong role: label |
| Properties dialog | dialog | Properties | wrong role: label, panel |
| Close button | push button | Close | ok |

**Slint fork (GL)**: 1 of 26 checked controls missing or wrong. Nodes in the tree: {'initial': 52, 'menu': 63, 'dialog': 60}. Focused node(s): {'initial': [['table', 'Files']], 'menu': [['menu', 'd006-slint-fork']], 'dialog': [['push button', 'Close']]}

| Control | Expected role | Expected name | Result |
| --- | --- | --- | --- |
| Window | frame or window | Files | ok |
| Sidebar | list | Places | ok |
| Place Home | list item | Home | ok |
| Place File system | list item | File system | ok |
| Place Start folder | list item | Start folder | ok |
| Up button | push button | Up | ok |
| Path label | label | /tmp/tmp.8lhTQ7LzRr/fx/small | ok |
| File list | table or list | Files | ok |
| Column header Name | column header | Name | ok |
| Column header Size | column header | Size | ok |
| Column header Modified | column header | Modified | ok |
| Row docs | table row or list item | docs | ok |
| Row empty | table row or list item | empty | ok |
| Row notes-1.txt | table row or list item | notes-1.txt | ok |
| Row notes-2.txt | table row or list item | notes-2.txt | ok |
| Row notes-3.txt | table row or list item | notes-3.txt | ok |
| Row photo.png | table row or list item | photo.png | ok |
| Row report.pdf | table row or list item | report.pdf | ok |
| Row with space.md | table row or list item | with space.md | ok |
| Row Ünïcödé.txt | table row or list item | Ünïcödé.txt | ok |
| Context menu | menu or popup menu | – | ok |
| Menu item Open | menu item | Open | ok |
| Menu item Copy Path | menu item | Copy Path | ok |
| Menu item Properties | menu item | Properties | ok |
| Properties dialog | dialog | Properties | wrong role: label, panel |
| Close button | push button | Close | ok |

### M7: keyboard walkthrough (automated checks)

`pass`/`fail` come from AT-SPI, stdout or the clipboard; `unverifiable` means the toolkit exposes nothing to check.

**libcosmic default (tiny-skia)**

| Step | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | focus on list at start | unverifiable | None |
| 1 | no row selected at start | unverifiable | rows or selection not exposed |
| 1 | Down selects docs | unverifiable | None |
| 2 | path label | unverifiable | None |
| 3 | path label after 2026 | unverifiable | None |
| 3 | path label after november | unverifiable | None |
| 3 | no row selected | unverifiable | rows or selection not exposed |
| 4 | after Backspace | unverifiable | None |
| 4 | after Alt+Up | unverifiable | None |
| 5 | Shift+Tab focuses Up | unverifiable | None |
| 5 | Shift+Tab focuses Home | unverifiable | None |
| 5 | Down focuses File system | unverifiable | None |
| 5 | Enter opens / | unverifiable | None |
| 6 | Down focuses Start folder | unverifiable | None |
| 6 | Enter returns to small | unverifiable | None |
| 6 | Tab twice focuses the list | unverifiable | None |
| 7 | End selects Ünïcödé.txt (AT-SPI) | unverifiable | None |
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | unverifiable | None |
| 8 | Shift+F10 opens a menu with Open | unverifiable | None |
| 8 | Properties dialog open | unverifiable | None |
| 8 | dialog closed | unverifiable | None |
| 8 | focus returns to list | unverifiable | None |
| 9 | wl-paste | fail | /tmp/tmp.8lhTQ7LzRr/fx/small/notes-2.txt |
| 10 | menu was open | unverifiable | None |
| 10 | menu closed | unverifiable | None |
| 10 | no dialog opened | unverifiable | None |
| 10 | focus on list | unverifiable | None |
| 11 | stdout | fail | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/small/notes-2.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/10k/item-09999.md |

**Slint default (femtovg, GL)**

| Step | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | focus on list at start | pass | ['table', 'Files'] |
| 1 | no row selected at start | unverifiable | rows or selection not exposed |
| 1 | Down selects docs | unverifiable | None |
| 2 | path label | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs |
| 3 | path label after 2026 | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs/2026 |
| 3 | path label after november | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs/2026/november |
| 3 | no row selected | unverifiable | rows or selection not exposed |
| 4 | after Backspace | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs/2026 |
| 4 | after Alt+Up | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs |
| 5 | Shift+Tab focuses Up | pass | ['push button', 'Up'] |
| 5 | Shift+Tab focuses Home | pass | ['list item', 'Home'] |
| 5 | Down focuses File system | pass | ['list item', 'File system'] |
| 5 | Enter opens / | pass | / |
| 6 | Down focuses Start folder | pass | ['list item', 'Start folder'] |
| 6 | Enter returns to small | pass | /tmp/tmp.8lhTQ7LzRr/fx/small |
| 6 | Tab twice focuses the list | pass | ['table', 'Files'] |
| 7 | End selects Ünïcödé.txt (AT-SPI) | unverifiable | None |
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | unverifiable | None |
| 8 | Shift+F10 opens a menu with Open | pass | True |
| 8 | Properties dialog open | pass | True |
| 8 | dialog closed | pass | False |
| 8 | focus returns to list | pass | ['table', 'Files'] |
| 9 | wl-paste | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/notes-1.txt |
| 10 | menu was open | pass | True |
| 10 | menu closed | pass | False |
| 10 | no dialog opened | pass | False |
| 10 | focus on list | pass | ['table', 'Files'] |
| 11 | stdout | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/small/notes-1.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/10k/item-09999.md |

**Slint fork (GL)**

| Step | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | focus on list at start | pass | ['table', 'Files'] |
| 1 | no row selected at start | pass | none |
| 1 | Down selects docs | pass | docs |
| 2 | path label | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs |
| 3 | path label after 2026 | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs/2026 |
| 3 | path label after november | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs/2026/november |
| 3 | no row selected | unverifiable | rows or selection not exposed |
| 4 | after Backspace | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs/2026 |
| 4 | after Alt+Up | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/docs |
| 5 | Shift+Tab focuses Up | pass | ['push button', 'Up'] |
| 5 | Shift+Tab focuses Home | pass | ['list item', 'Home'] |
| 5 | Down focuses File system | pass | ['list item', 'File system'] |
| 5 | Enter opens / | pass | / |
| 6 | Down focuses Start folder | pass | ['list item', 'Start folder'] |
| 6 | Enter returns to small | pass | /tmp/tmp.8lhTQ7LzRr/fx/small |
| 6 | Tab twice focuses the list | pass | ['table', 'Files'] |
| 7 | End selects Ünïcödé.txt (AT-SPI) | pass | Ünïcödé.txt |
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | pass | docs |
| 8 | Shift+F10 opens a menu with Open | pass | True |
| 8 | Properties dialog open | pass | True |
| 8 | dialog closed | pass | False |
| 8 | focus returns to list | pass | ['table', 'Files'] |
| 9 | wl-paste | pass | /tmp/tmp.8lhTQ7LzRr/fx/small/notes-1.txt |
| 10 | menu was open | pass | True |
| 10 | menu closed | pass | False |
| 10 | no dialog opened | pass | False |
| 10 | focus on list | pass | ['table', 'Files'] |
| 11 | stdout | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/small/notes-1.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.8lhTQ7LzRr/fx/10k/item-09999.md |

