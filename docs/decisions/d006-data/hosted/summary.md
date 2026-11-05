### Environment

```text
date: 2026-11-05T15:28:10Z
host: GitHub Actions 1000000574
cpu: Intel(R) Xeon(R) 6975P-C
cores: 2
kernel: Linux 7.0.0-1014-aws x86_64
governor: unknown
os: Ubuntu 24.04.5 LTS
sway: sway version 1.9
wtype: 0.4-3
mesa: 25.2.8-0ubuntu0.24.04.4
runs: 5  cpu_window: 30
iced: ca3b387934eab914  slint: 4d4066337f568481
output: HEADLESS-1 1920x1080@60Hz scale 1.0
fixture digest: 184f3d8ea40f1ef1a3ec2434cfaffa66d1b1d6e03f95226b0cadf742e723022c  -
```

### M1–M4: harness (`tools/budgets`)

Median (min–max, n runs). Cold start is with a warm page cache.

| Metric | Budget | libcosmic (iced) | Slint |
| --- | --- | --- | --- |
| M1 cold start, `small` | ≤ 300 ms | **44.6** ms (43.9–2796.8, n=5) | **115.4** ms (99.7–2596.1, n=3); **2 of 5 runs: > 3000 ms (timeout)** |
| M2 10,000-item first paint, `10k` | ≤ 500 ms | **55.1** ms (54.5–56.3, n=5) | **142.5** ms (126.6–302.6, n=5) |
| M3 idle RSS, `small`, 5 s after first frame | 800 MB (desktop) | **33.8** MB (33.7–33.8, n=5) | **150.6** MB (150.5–161.1, n=3); **2 of 5 runs: > 3000 ms (timeout)** |
| M4 idle CPU, `small` | ≤ 1 % | **0.00** % (0.00–0.00, n=5) | **0.00** % (0.00–0.03, n=3); **2 of 5 runs: > 3000 ms (timeout)** |

- libcosmic (iced) `small`: harness exit codes [1, 0, 0, 0, 0], CPU window [30] s
- libcosmic (iced) `10k`: harness exit codes [0, 0, 0, 0, 0], CPU window [10] s
- Slint `small`: harness exit codes [2, 2, 1, 0, 0], CPU window [30] s
- Slint `10k`: harness exit codes [1, 0, 0, 0, 0], CPU window [10] s

### M5: frame interval while scrolling the 10,000-item list

Median over runs of each run's value (min–max). Dropped = intervals > 1.5 × refresh period.

| | libcosmic (iced) | Slint |
| --- | --- | --- |
| p50 | **38.9** ms (38.0–39.1, n=5) | **16.5** ms (16.5–16.5, n=5) |
| p95 | **122.8** ms (120.5–125.1, n=5) | **17.1** ms (17.0–17.2, n=5) |
| p99 | **126.8** ms (126.0–162.0, n=5) | **17.6** ms (17.4–18.0, n=5) |
| max | **198.2** ms (197.4–198.5, n=5) | **18.4** ms (18.2–23.7, n=5) |
| commits per run | **178** (175–182, n=5) | **606** (606–607, n=5) |
| dropped frames per run | **131** (128–135, n=5) | **0** (0–0, n=5) |

### M6: accessibility tree

**libcosmic (iced)**: 26 of 26 checked controls missing or wrong. Nodes in the tree: {'initial': 2, 'menu': 2, 'dialog': 2}. Focused node(s): {'initial': [], 'menu': [], 'dialog': []}

| Control | Expected role | Expected name | Result |
| --- | --- | --- | --- |
| Window | frame or window | Files | missing |
| Sidebar | list | Places | missing |
| Place Home | list item | Home | missing |
| Place File system | list item | File system | missing |
| Place Start folder | list item | Start folder | missing |
| Up button | push button | Up | missing |
| Path label | label | /tmp/tmp.Zds0zvUvPS/fx/small | missing |
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

**Slint**: 17 of 26 checked controls missing or wrong. Nodes in the tree: {'initial': 40, 'menu': 47, 'dialog': 48}. Focused node(s): {'initial': [['table', 'Files']], 'menu': [['frame', 'd006-slint']], 'dialog': [['push button', 'Close']]}

| Control | Expected role | Expected name | Result |
| --- | --- | --- | --- |
| Window | frame or window | Files | ok |
| Sidebar | list | Places | ok |
| Place Home | list item | Home | ok |
| Place File system | list item | File system | ok |
| Place Start folder | list item | Start folder | ok |
| Up button | push button | Up | ok |
| Path label | label | /tmp/tmp.Zds0zvUvPS/fx/small | ok |
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

**libcosmic (iced)**

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
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.Zds0zvUvPS/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | unverifiable | None |
| 8 | Shift+F10 opens a menu with Open | unverifiable | None |
| 8 | Properties dialog open | unverifiable | None |
| 8 | dialog closed | unverifiable | None |
| 8 | focus returns to list | unverifiable | None |
| 9 | wl-paste | pass | /tmp/tmp.Zds0zvUvPS/fx/small/notes-1.txt |
| 10 | menu was open | unverifiable | None |
| 10 | menu closed | unverifiable | None |
| 10 | no dialog opened | unverifiable | None |
| 10 | focus on list | unverifiable | None |
| 11 | stdout | pass | SPIKE_OPEN /tmp/tmp.Zds0zvUvPS/fx/small/notes-1.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.Zds0zvUvPS/fx/10k/item-09999.md |

**Slint**

| Step | Check | Result | Observed |
| --- | --- | --- | --- |
| 1 | focus on list at start | pass | ['table', 'Files'] |
| 1 | no row selected at start | unverifiable | rows or selection not exposed |
| 1 | Down selects docs | unverifiable | None |
| 2 | path label | pass | /tmp/tmp.Zds0zvUvPS/fx/small/docs |
| 3 | path label after 2026 | pass | /tmp/tmp.Zds0zvUvPS/fx/small/docs/2026 |
| 3 | path label after november | pass | /tmp/tmp.Zds0zvUvPS/fx/small/docs/2026/november |
| 3 | no row selected | unverifiable | rows or selection not exposed |
| 4 | after Backspace | pass | /tmp/tmp.Zds0zvUvPS/fx/small/docs/2026 |
| 4 | after Alt+Up | pass | /tmp/tmp.Zds0zvUvPS/fx/small/docs |
| 5 | Shift+Tab focuses Up | pass | ['push button', 'Up'] |
| 5 | Shift+Tab focuses Home | pass | ['list item', 'Home'] |
| 5 | Down focuses File system | pass | ['list item', 'File system'] |
| 5 | Enter opens / | pass | / |
| 6 | Down focuses Start folder | pass | ['list item', 'Start folder'] |
| 6 | Enter returns to small | pass | /tmp/tmp.Zds0zvUvPS/fx/small |
| 6 | Tab twice focuses the list | pass | ['table', 'Files'] |
| 7 | End selects Ünïcödé.txt (AT-SPI) | unverifiable | None |
| 7 | End selects Ünïcödé.txt (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.Zds0zvUvPS/fx/small/Ünïcödé.txt |
| 7 | Home selects docs (AT-SPI) | unverifiable | None |
| 8 | Shift+F10 opens a menu with Open | pass | True |
| 8 | Properties dialog open | pass | True |
| 8 | dialog closed | pass | False |
| 8 | focus returns to list | pass | ['table', 'Files'] |
| 9 | wl-paste | pass | /tmp/tmp.Zds0zvUvPS/fx/small/notes-1.txt |
| 10 | menu was open | pass | True |
| 10 | menu closed | pass | False |
| 10 | no dialog opened | pass | False |
| 10 | focus on list | pass | ['table', 'Files'] |
| 11 | stdout | pass | SPIKE_OPEN /tmp/tmp.Zds0zvUvPS/fx/small/notes-1.txt |
| 12 | End selects item-09999.md (Enter prints SPIKE_OPEN) | pass | SPIKE_OPEN /tmp/tmp.Zds0zvUvPS/fx/10k/item-09999.md |

