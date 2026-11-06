### Environment

```text
date: 2026-11-06T09:49:08Z
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
d006-iced: cce13ba3d961d850
d006-iced-wgpu: c4dda1fe4dac69dd
d006-slint: 85f7fe54c92f0db7
output: HEADLESS-1 1920x1080@60Hz scale 1.0
egl: Mesa Intel(R) UHD Graphics (JSL)
fixture digest: 184f3d8ea40f1ef1a3ec2434cfaffa66d1b1d6e03f95226b0cadf742e723022c  -
renderer iced: iced tiny-skia CPU
renderer iced-wgpu: iced Vulkan Intel(R) UHD Graphics (JSL)
renderer slint: slint gl Mesa Intel(R) UHD Graphics (JSL)
renderer slint-sw: slint software (CPU)
```

### M1–M4: harness (`tools/budgets`)

Median (min–max, n runs). Page cache is warm. M3 and M4 use only the runs that gave a reading.

| Metric | Budget | libcosmic default (tiny-skia) | libcosmic `wgpu` | Slint default (femtovg, GL) | Slint software renderer |
| --- | --- | --- | --- | --- | --- |
| M1 cold start, `small` | ≤ 300 ms | **52.6** ms (51.0–56.9, n=5) | **131.1** ms (127.8–232.3, n=5) | **109.4** ms (108.2–312.9, n=5) | **27.1** ms (26.1–32.1, n=5) |
| M2 10,000-item first paint, `10k` | ≤ 500 ms | **87.4** ms (85.6–90.3, n=5) | **157.5** ms (156.8–160.3, n=5) | **156.8** ms (153.8–158.9, n=5) | **85.4** ms (71.3–87.9, n=5) |
| M3 idle RSS, `small`, 5 s after first frame | 800 MB (desktop) | **34.0** MB (33.9–34.2, n=5) | **119.4** MB (119.1–124.9, n=5) | **102.7** MB (102.6–110.7, n=5) | **28.5** MB (28.4–28.7, n=5) |
| M4 idle CPU, `small` | ≤ 1 % | **0.00** % (0.00–0.01, n=5) | **0.00** % (0.00–0.01, n=5) | **0.01** % (0.01–0.02, n=5) | **0.01** % (0.01–0.01, n=5) |

- libcosmic default (tiny-skia) `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- libcosmic default (tiny-skia) `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- libcosmic `wgpu` `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- libcosmic `wgpu` `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint default (femtovg, GL) `small`: harness exit codes [1, 0, 0, 0, 0], CPU window [300] s
- Slint default (femtovg, GL) `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint software renderer `small`: harness exit codes [0, 0, 0, 0, 0], CPU window [300] s
- Slint software renderer `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s

### M5: frame interval while scrolling the 10,000-item list

Median over runs of each run's value (min–max). Dropped = intervals > 1.5 × refresh period.

| | libcosmic default (tiny-skia) | libcosmic `wgpu` | Slint default (femtovg, GL) | Slint software renderer |
| --- | --- | --- | --- | --- |
| p50 | **75.3** ms (70.6–77.2, n=5) | **16.6** ms (16.6–16.6, n=5) | **16.6** ms (16.5–16.6, n=5) | **16.3** ms (16.3–16.3, n=5) |
| p95 | **244.7** ms (239.3–254.2, n=5) | **17.0** ms (16.9–17.1, n=5) | **18.0** ms (17.9–18.0, n=5) | **17.8** ms (17.8–17.9, n=5) |
| p99 | **255.1** ms (252.9–259.5, n=5) | **20.6** ms (20.1–20.7, n=5) | **18.6** ms (18.5–19.2, n=5) | **18.3** ms (18.1–18.3, n=5) |
| max | **259.9** ms (253.5–260.1, n=5) | **30.3** ms (28.5–30.9, n=5) | **25.9** ms (19.2–27.7, n=5) | **20.3** ms (18.7–21.0, n=5) |
| commits per run | **111** (106–120, n=5) | **598** (598–598, n=5) | **604** (604–605, n=5) | **608** (607–608, n=5) |
| dropped frames per run | **66** (60–74, n=5) | **2** (1–2, n=5) | **1** (0–2, n=5) | **0** (0–0, n=5) |

### G1–G5: GPU gates (`docs/decisions/D-006-toolkit.md` §4.1)

A variant is evaluated only if its run is proven to use the GPU: the compositor's Wayland `egl:` line and the app's own renderer line must match `Intel` (CPU renderers by design need only the `egl:` line). Otherwise **not measured**, never a GPU number. G5 uses N = 1 and a 300 MB shell share. Every run must be present: 5+ runs, none missing or crashed.

| Variant | Renderer proof | G1 | G2 | G3 | G4 | G5 | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| libcosmic default (tiny-skia) | ✅ `iced tiny-skia CPU` | ✅ | ✅ | ✅ | ❌ | ✅ | **FAIL** |
| libcosmic `wgpu` | ✅ `iced Vulkan Intel(R) UHD Graphics (JSL)` | ✅ | ✅ | ✅ | ❌ | ✅ | **FAIL** |
| Slint default (femtovg, GL) | ✅ `slint gl Mesa Intel(R) UHD Graphics (JSL)` | ❌ | ✅ | ✅ | ❌ | ✅ | **FAIL** |
| Slint software renderer | ✅ `slint software (CPU)` | ✅ | ✅ | ✅ | ✅ | ✅ | **PASS** |

- libcosmic default (tiny-skia): G1 cold start: every launch ≤ 300 ms: ✅ max 57 ms of 5
- libcosmic default (tiny-skia): G2 10k first paint: every launch ≤ 500 ms: ✅ max 90 ms of 5
- libcosmic default (tiny-skia): G3 idle CPU: median ≤ 1 %: ✅ median 0.00 %
- libcosmic default (tiny-skia): G4 scrolling: median 0 dropped, no run above 1: ❌ median 66, max 74 of 5 runs
- libcosmic default (tiny-skia): G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 34 MB
- libcosmic `wgpu`: G1 cold start: every launch ≤ 300 ms: ✅ max 232 ms of 5
- libcosmic `wgpu`: G2 10k first paint: every launch ≤ 500 ms: ✅ max 160 ms of 5
- libcosmic `wgpu`: G3 idle CPU: median ≤ 1 %: ✅ median 0.00 %
- libcosmic `wgpu`: G4 scrolling: median 0 dropped, no run above 1: ❌ median 2, max 2 of 5 runs
- libcosmic `wgpu`: G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 119 MB
- Slint default (femtovg, GL): G1 cold start: every launch ≤ 300 ms: ❌ max 313 ms of 5
- Slint default (femtovg, GL): G2 10k first paint: every launch ≤ 500 ms: ✅ max 159 ms of 5
- Slint default (femtovg, GL): G3 idle CPU: median ≤ 1 %: ✅ median 0.01 %
- Slint default (femtovg, GL): G4 scrolling: median 0 dropped, no run above 1: ❌ median 1, max 2 of 5 runs
- Slint default (femtovg, GL): G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 103 MB
- Slint software renderer: G1 cold start: every launch ≤ 300 ms: ✅ max 32 ms of 5
- Slint software renderer: G2 10k first paint: every launch ≤ 500 ms: ✅ max 88 ms of 5
- Slint software renderer: G3 idle CPU: median ≤ 1 %: ✅ median 0.01 %
- Slint software renderer: G4 scrolling: median 0 dropped, no run above 1: ✅ median 0, max 0 of 5 runs
- Slint software renderer: G5 shell memory: 1 × M3 ≤ 300 MB: ✅ 1 × 29 MB

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
| Path label | label | /tmp/tmp.1vYrxEeH9v/fx/small | missing |
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
| Path label | label | /tmp/tmp.1vYrxEeH9v/fx/small | ok |
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
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.1vYrxEeH9v/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | unverifiable | None |
| 8 | Shift+F10 opens a menu with Open | unverifiable | None |
| 8 | Properties dialog open | unverifiable | None |
| 8 | dialog closed | unverifiable | None |
| 8 | focus returns to list | unverifiable | None |
| 9 | wl-paste | fail | /tmp/tmp.1vYrxEeH9v/fx/small/notes-2.txt |
| 10 | menu was open | unverifiable | None |
| 10 | menu closed | unverifiable | None |
| 10 | no dialog opened | unverifiable | None |
| 10 | focus on list | unverifiable | None |
| 11 | stdout | fail | SPIKE_OPEN /tmp/tmp.1vYrxEeH9v/fx/small/notes-2.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.1vYrxEeH9v/fx/10k/item-09999.md |

**Slint default (femtovg, GL)**

| Step | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | focus on list at start | pass | ['table', 'Files'] |
| 1 | no row selected at start | unverifiable | rows or selection not exposed |
| 1 | Down selects docs | unverifiable | None |
| 2 | path label | pass | /tmp/tmp.1vYrxEeH9v/fx/small/docs |
| 3 | path label after 2026 | pass | /tmp/tmp.1vYrxEeH9v/fx/small/docs/2026 |
| 3 | path label after november | pass | /tmp/tmp.1vYrxEeH9v/fx/small/docs/2026/november |
| 3 | no row selected | unverifiable | rows or selection not exposed |
| 4 | after Backspace | pass | /tmp/tmp.1vYrxEeH9v/fx/small/docs/2026 |
| 4 | after Alt+Up | pass | /tmp/tmp.1vYrxEeH9v/fx/small/docs |
| 5 | Shift+Tab focuses Up | pass | ['push button', 'Up'] |
| 5 | Shift+Tab focuses Home | pass | ['list item', 'Home'] |
| 5 | Down focuses File system | pass | ['list item', 'File system'] |
| 5 | Enter opens / | pass | / |
| 6 | Down focuses Start folder | pass | ['list item', 'Start folder'] |
| 6 | Enter returns to small | pass | /tmp/tmp.1vYrxEeH9v/fx/small |
| 6 | Tab twice focuses the list | pass | ['table', 'Files'] |
| 7 | End selects Ünïcödé.txt (AT-SPI) | unverifiable | None |
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.1vYrxEeH9v/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | unverifiable | None |
| 8 | Shift+F10 opens a menu with Open | pass | True |
| 8 | Properties dialog open | pass | True |
| 8 | dialog closed | pass | False |
| 8 | focus returns to list | pass | ['table', 'Files'] |
| 9 | wl-paste | pass | /tmp/tmp.1vYrxEeH9v/fx/small/notes-1.txt |
| 10 | menu was open | pass | True |
| 10 | menu closed | pass | False |
| 10 | no dialog opened | pass | False |
| 10 | focus on list | pass | ['table', 'Files'] |
| 11 | stdout | pass | SPIKE_OPEN /tmp/tmp.1vYrxEeH9v/fx/small/notes-1.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.1vYrxEeH9v/fx/10k/item-09999.md |

