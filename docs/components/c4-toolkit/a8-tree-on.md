# Accessibility tree on: budgets and M6 on AT-SPI (A8)

Card: #97 · PR: #164 · Requirement: A8 in D-011 §5.2 · Method: [`D-006-measurements.md`](../../decisions/D-006-measurements.md) M1–M7, unchanged.

## How it is measured

`d006-measure.yml` builds the D-006 Files spike (`spikes/d006-slint`) twice: against Slint 1.18.1 from crates.io, and against our fork (`third_party/slint`, patches 0001–0006). `tools/d006/measure.sh` runs the fork binary as two variants:

- `slint-fork`: femtovg on GL, tree off (as all earlier measurements, deviation 5).
- `slint-fork-a11y`: same binary. Before each launch the script sets `org.a11y.Status` `IsEnabled` and `ScreenReaderEnabled` to true, so AccessKit builds and publishes the tree for M1–M5. `accesskit_unix` 0.22.1 follows `IsEnabled`.

M6 and M7 always run with the tree on, for upstream Slint and the fork in the same run. The M6 dump also writes `m6-details-*.txt`: each node's AccessibleId and AT-SPI action names, recorded but not checked.

Limitation: no AT-SPI client reads the tree during M1–M5. An assistant that walks the tree adds work on top, which is not measured here.

## Reference NUC, GPU path

Run [42504135193](https://github.com/jens-thomae/Atos/actions/runs/42504135193): Celeron N5105, kernel 6.8.0-147, Mesa 25.2.8, sway 1.9 headless on gles2. The `egl:` line and the app's renderer line both report `Mesa Intel(R) UHD Graphics (JSL)`. 5 runs, full 300 s idle window, warm page cache. Raw data: [`d006-data/nuc-a8/`](../../decisions/d006-data/nuc-a8/) (`summary.md` is the job summary).

### M1–M5, Slint fork on GL (median, min–max, n = 5)

| Metric | §7 budget | tree off | tree on |
| --- | --- | --- | --- |
| M1 cold start | ≤ 300 ms | 109.1 ms (107.9–117.1) | 120.8 ms (109.4–125.5) |
| M2 10k first paint | ≤ 500 ms | 160.4 ms (156.6–163.0) | 159.4 ms (146.5–163.1) |
| M3 idle RSS | ≤ 800 MB desktop; shell share 300 MB | 101.9 MB | 102.8 MB |
| M4 idle CPU, 300 s | ≤ 1 % | 0.01 % | 0.01 % |
| M5 p50 / p95 / p99 / max | no dropped frames | 16.8 / 17.4 / 18.5 / 24.6 ms | 16.4 / 18.0 / 18.8 / 26.0 ms |
| M5 dropped frames per run (> 25 ms) | 0 | 0, 0, 0, 1, 0 | **1, 0, 1, 0, 2** |
| G1–G5 (D-006 §4.1) | | PASS | **FAIL: G4** (median 1, max 2) |

With the tree on, M1–M4 hold with a wide margin. The tree costs about 12 ms of cold start and 1 MB. **Scrolling misses:** three of five runs have intervals of 26–27 ms, just over the 25 ms threshold, against one 25.4 ms interval with the tree off. Follow-up: #181. Upstream Slint GL in the same run: G1 fails (first launch 307 ms), M5 dropped frames 1, 0, 1, 0, 0.

### M6 over AT-SPI (26 checks)

| | Slint 1.18.1 | Slint fork |
| --- | --- | --- |
| Missing or wrong | 17 | **1** |
| Nodes (initial / menu / dialog) | 40 / 47 / 48 | 52 / 63 / 60 |
| Focus with the menu open | `frame d006-slint` | `menu d006-slint-fork` |

The fork exposes column headers, `table row` nodes with `selected` (and `click`), a `menu` with three `menu item`s, and a `dialog`. The one miss is the *Properties* dialog's name: the spike's `PopupWindow` has no `accessible-label`, so the dialog node is unnamed, as [popups-and-dialogs.md](popups-and-dialogs.md) describes. That is app code in the frozen D-006 spike, not a toolkit gap. The duplicate `menu` inside `menu` from that page shows on the live bus too.

M7: the fork now verifies row selection through AT-SPI (step 1 *Down selects docs*, step 7 *End* and *Home*). Every other check passes as before. Step 3's "no row selected" stays unverifiable: the opened folder has no rows.

**Not verified here:** every AccessibleId is empty because the spike sets no `accessible-id`. AT-SPI's `Action` interface lists only `click`. So A7 and the non-click A4 actions still need a live AT-SPI check: #167.

Hosted run (indicative, llvmpipe): [42497446452](https://github.com/jens-thomae/Atos/actions/runs/42497446452). With the tree on, M1 is +2 ms, M3 +0.5 MB, and there are no extra dropped frames.
