# D-006: measurements of the two Files prototypes

Card: #12 · Method: [`D-006-prototype-brief.md`](D-006-prototype-brief.md) §6–7 · Measured: 2026-11-05 · No recommendation here; that is #14.

Both prototypes (`spikes/d006-iced/`, libcosmic rev `daca62bb`; `spikes/d006-slint/`, Slint 1.18.1) were measured in the same environment in the same run with the scripts in [`tools/d006/`](../../tools/d006/). Raw data is in [`d006-data/`](d006-data/).

## Status: reference hardware not yet measured

**No number below comes from the Intel NUC 11 (Celeron N5105).** The `nuc` runner needs packages (sway, wtype, an AT-SPI stack) that only the owner can install; they are listed in [`reference-runner.md`](../reference-runner.md) step 7. Until then the §9 performance gates are **provisional** (brief §9). Numbers come from two environments:

| | Dev VM (`atos-t12`) | GitHub-hosted CI |
| --- | --- | --- |
| Machine | Lima/Apple Virtualization VM on an Apple M1 Max, 4 vCPU, aarch64, 8 GiB | `ubuntu-24.04` runner, 2 vCPU, x86_64 (AMD EPYC 9V74), kernel 7.0.0-1017-azure |
| Compositor | sway 1.9, headless backend, 1920 × 1080 @ 60 Hz, scale 1 | same |
| Renderer | sway: pixman. libcosmic: `iced_tiny_skia` (CPU, no GL). Slint: femtovg on OpenGL ES through Mesa 25.2.8, **llvmpipe** (CI log: `eglinfo` → `llvmpipe (LLVM 20.1.2, 256 bits)`; VM: 128 bits; zink/Vulkan probing fails harmlessly) | same |
| Runs per number | 5 | 7 (so Slint keeps ≥ 5 readings even if a first launch times out) |
| Idle-CPU window (M4) | full 5 minutes (§7) | 30 s, to keep the job short |
| Page cache | warm | warm |
| Fixture digest (brief §5) | `184f3d8e…23022c` | `184f3d8e…23022c` (identical) |
| Raw data | [`d006-data/vm/`](d006-data/vm/) | [`d006-data/hosted/`](d006-data/hosted/) (workflow run 42064288468, 7 runs; the earlier 5-run run is kept in [`d006-data/hosted-run1/`](d006-data/hosted-run1/)) |

The VM is a dedicated instance (the shared one was busy with the #13 agent test, which skewed a first attempt; that attempt is not used). Neither environment has a GPU in the path: **the N5105's integrated GPU is not exercised anywhere yet.**

## Rerun on the reference hardware

After the owner has installed the step-7 packages:

```sh
gh workflow run d006-measure.yml -f nuc=true      # once the workflow is on main
# or: add the label `d006-nuc` to a pull request of this repository
```

[`.github/workflows/d006-measure.yml`](../../.github/workflows/d006-measure.yml) builds both prototypes and the harness on a hosted runner, uploads them with the scripts, and the `nuc` job only measures: `tools/d006/measure.sh` (M1–M7), `summarize.py` writes the tables below into the job summary, and the raw data is the `d006-results-nuc` artifact (about 1 h 20 min: five 5-minute idle windows per prototype). The same job on a hosted runner is started by the label `d006-measure`. On any Linux machine with the packages: `tools/d006/measure.sh <d006-iced> <d006-slint> <budgets> <out-dir>`. M9 is `tools/d006/m9-build.sh <out.json>`.

## Deviations from the brief

1. **Reference hardware: sway headless, not the DRM backend.** The runner is an unprivileged service user without a seat, so sway cannot take the display. The NUC job will also use sway headless with software rendering; the GPU path stays unmeasured. For the owner to decide whether a DRM or `WLR_RENDER_DRM_DEVICE` run is wanted.
2. **Page cache warm** everywhere (owner decision: no `drop_caches` rule). "Cold start" here is a warm start.
3. **M4 on hosted CI uses a 30 s window**, not 5 minutes. The VM used the full window.
4. **Modifier keys:** `wtype -M` (modifier state) alone is ignored by Slint and `-P` (key event) alone by libcosmic, so the walkthrough sends both. Each key is sent after a 500 ms delay because the first key of a `wtype` call is otherwise lost; a background `wtype` keeps a virtual keyboard alive so the window keeps keyboard focus.
5. **AT-SPI on during M6/M7 only.** M1–M5 run with the screen-reader flag off, which is the default on a desktop without assistive technology; AccessKit then builds no tree.
6. **M7 verdicts for rows and focus rely partly on screenshots** (below), because neither toolkit exposes selected rows through AT-SPI and libcosmic exposes nothing at all. This is the closest documented method; no recommendation depends on it.
7. **Mouse input is untested** in both prototypes (no pointer in headless sway). Click, double-click, right-click and clicking a place or *Up* are not covered by any number here.

## M1–M4: harness

Median, (min–max), 5 runs, harness `tools/budgets` unchanged, per-run files in `d006-data/*/m1-m4/`. M2 includes app start-up with the 10k folder. M3 and M4 come from the `small` runs.

| Metric | Budget | libcosmic, VM | Slint, VM | libcosmic, CI | Slint, CI |
| --- | --- | --- | --- | --- | --- |
| M1 cold start (warm cache) | ≤ 300 ms | **52.5** ms (31.1–76.9) | **85.1** ms (63.3–134.6) | **85.2** ms (84.7–2145.9) ¹ | **123.5** ms (112.7–2033.1) ¹ |
| M2 10k first paint | ≤ 500 ms | **49.0** ms (44.2–67.6) | **96.5** ms (95.0–140.6) | **110.9** ms (105.7–111.8) | **205.2** ms (165.2–488.0) |
| M3 idle RSS, 5 s after first frame | 800 MB | **32.0** MB (32.0–32.1) | **147.9** MB (147.7–149.1) | **33.6** MB (33.5–33.7) | **149.1** MB (145.2–160.8) |
| M4 idle CPU | ≤ 1 % | **0.00** % (0.00–0.01), 300 s | **0.02** % (0.02–0.03), 300 s | **0.00** % (0.00–0.03), 30 s | **0.00** % (0.00–0.03), 30 s |

¹ The first launch after the compositor started took about 2 s for both prototypes on CI (2146 ms, 2033 ms); the other six were 85–125 ms. Under the 3 s limit, so no timeout this time. **In the earlier 5-run CI run (different runner, AMD EPYC 9V45; [`hosted-run1`](d006-data/hosted-run1/)) the first two Slint `small` launches did hit the 3 s marker timeout: `> 3000 ms (timeout)`, a gate fail per the brief**; there Slint's M1 median was 1561 ms and libcosmic's first launch 801 ms. The effect is a one-time start-up cost on a fresh runner (library loading and, for Slint, llvmpipe/shader set-up, see Limitations) and varies between runners; it was not seen in the VM. The NUC run will show whether it occurs on the reference hardware.

Harness exit 1 on a run means a §7 breach in that run (only the slow first launches on CI; the first libcosmic launch also breached in both CI runs). No crash or hang occurred in any final run. A first attempt in the shared VM had one Slint 10k run die with a Wayland `Broken pipe` while another session was using the machine; it did not recur in the final runs (all 10 Slint harness launches and 5 autoscroll runs in the VM exited normally) and is not in the data, but it is the only unexplained abnormal exit seen.

## M5: frame interval while scrolling 10,000 items

`D006_AUTOSCROLL=1 WAYLAND_DEBUG=client`, commits of the main surface between `BUDGET_FIRST_FRAME` and `D006_AUTOSCROLL_DONE` (10 s). Both libraries print timestamps, so the brief's method ran unchanged. Median over 5 runs (VM) or 7 runs (CI) of each run's value (min–max); dropped = interval > 25 ms (1.5 × 16.7 ms). Raw commit logs: `m5/*.log.gz`.

| | libcosmic, VM | Slint, VM | libcosmic, CI | Slint, CI |
| --- | --- | --- | --- | --- |
| p50 | **29.8** ms (29.4–30.0) | **19.0** ms (18.9–19.0) | **54.0** ms (52.2–56.0) | **16.7** ms (16.7–16.8) |
| p95 | **92.9** ms (90.7–94.7) | **20.2** ms (19.8–20.3) | **174.2** ms (165.3–178.5) | **17.4** ms (17.3–18.3) |
| p99 | **95.5** ms (95.1–98.7) | **20.6** ms (20.2–20.8) | **183.2** ms (177.8–247.2) | **17.9** ms (17.7–20.1) |
| max | 202.7 ms | 21.1 ms (20.4–38.6) | 194.9 ms | 23.7 ms (18.9–26.2) |
| commits per run | 221 | 532 | 134 | 600 |
| dropped frames per run | **163** (157–175) | **0** (0–3) | **87** (86–105) | **0** (0–1) |

This is how fast each app produces frames into a CPU-rendered 1920 × 1080 headless compositor. It says nothing yet about a GPU; "no dropped frames" is judged on the NUC. In these environments libcosmic's CPU renderer (tiny-skia, full-window repaint while the list scrolls) produced 87–175 intervals above 25 ms per run; Slint produced none (at most 3). The two CI runners differ in speed, which moves libcosmic's numbers a lot (p50 30 ms in the VM, 39 ms and 54 ms on the two CI runners): absolute M5 numbers are environment-bound.

## M6: accessibility tree

Dump script and trees: `tools/d006/atspi.py`, `d006-data/vm/m6/<toolkit>/m6-tree-{initial,menu,dialog}.txt` (role, name, states of every node), with screenshots of each state. Trees and results are identical on CI. 26 checks: window, sidebar, 3 places, *Up*, path label, file list, 3 column headers, 9 rows of `small`, context menu, 3 menu items, *Properties* dialog, *Close*.

**libcosmic: 26 of 26 missing.** The application is on the bus with one unnamed `frame` and no children in every state (initial, menu open, dialog open). No node ever carries the `focused` state. Cause as in the #10 README (the fork never sends widget nodes to AccessKit); the `a11y` feature did not crash.

**Slint: 17 of 26 missing or wrong; 9 correct.**

| Control | Slint result |
| --- | --- |
| Window `Files`, sidebar `Places`, places `Home` / `File system` / `Start folder`, *Up*, path label, file list `Files`, *Close* | ok (role and exact name) |
| Column headers `Name`, `Size`, `Modified` | wrong role: label (3) |
| Rows (9 entries) | wrong role: label. Each cell is a separate label under an unnamed list box; no row node, no row name, no selected state (9) |
| Context menu | no menu node; the popup is a separate `frame` named `d006-slint` (1) |
| Menu items `Open`, `Copy Path`, `Properties` | wrong role: label (3) |
| *Properties* dialog | wrong role: `panel` (1; the toolkit has no dialog role) |

`focused` works for Slint: list at start (`table Files`), menu (`frame d006-slint`, not an item), *Close* in the dialog. Slint 1.18.1's role enum has no row, header, menu, menu item or dialog, so these cannot be fixed from app code (#11 README).

## M7: keyboard walkthrough

`tools/d006/atspi.py m7`, keys by `wtype` in sway, after each step the state is read from AT-SPI where the toolkit exposes it, plus two non-screenshot probes: *Enter* on a file prints `SPIKE_OPEN <path>` (stdout), and `wl-paste` for the clipboard. A screenshot is saved after each step (`d006-data/vm/m7/<toolkit>/m7-stepNN*.png`) and **I reviewed them by hand** for what AT-SPI cannot show. Results from the VM run; the CI run gave the same automated results.

| # | Step | AT-SPI verdict, libcosmic | AT-SPI verdict, Slint | Behavioural evidence, libcosmic | Behavioural evidence, Slint |
| --- | --- | --- | --- | --- | --- |
| 1 | Focus on list, none selected; Down selects `docs` | not verifiable | pass (list `focused`); selection not verifiable | pass ᵃ | pass ᵇ |
| 2 | Enter opens `docs` | not verifiable | pass (path label) | pass (screenshot) | pass |
| 3 | `2026`, `november`, none selected | not verifiable | pass (path label); none-selected not verifiable | pass (screenshot) | pass ᵇ |
| 4 | Backspace to `2026`; Alt+Up to `docs` | not verifiable | pass (path label) | pass (screenshot of the end state) | pass |
| 5 | Shift+Tab → *Up* → *Home*; Down → *File system*; Enter opens `/` | not verifiable | pass (`focused` at each key, path label) | pass (end state: `/` open, *File system* focused) ᶜ | pass |
| 6 | Down → *Start folder*; Enter → `small`; Tab twice → list | not verifiable | pass (`focused`, path label) | pass (end state) ᵃ ᶜ | pass |
| 7 | End selects `Ünïcödé.txt`; Home selects `docs` | not verifiable | not verifiable (no selected state) | pass (`SPIKE_OPEN` probe; screenshot) | pass (probe; screenshot) |
| 8 | Shift+F10, Down ×2, Enter → *Properties*; Escape closes, focus on list | not verifiable | pass (menu, dialog, closed, list `focused`) | pass (screenshots of menu, dialog, closed) ᵃ | pass |
| 9 | `notes-1.txt`; Menu, Down, Enter: clipboard has the path | not verifiable | not verifiable (clipboard is not in the tree) | pass (`wl-paste`) | pass (`wl-paste`) |
| 10 | Escape closes an open menu without action | not verifiable | pass (menu gone, no dialog, list `focused`) | pass (screenshot) | pass |
| 11 | Enter on `notes-1.txt` prints `SPIKE_OPEN <path>` | not verifiable | not verifiable (stdout, not tree) | pass (stdout) | pass (stdout) |
| 12 | 10k: End → `item-09999.md`; Home → `item-00100`; Page Down / Page Up by one page, each within 1 s | not verifiable | not verifiable (no rows in the tree) | pass: probe; Home; Page Down → `item-02200`, Page Up → `item-00100` (screenshots 1 s after each key) | pass: probe; Home; Page Down → `item-02300`, Page Up → `item-00100` |

ᵃ libcosmic's list cannot take toolkit focus and draws no focus indicator, so "focus is on the list" can only be inferred from the keys working, never seen. ᵇ Slint exposes no row or selected state through AT-SPI, so "selected" was confirmed by screenshot, not AT-SPI (the brief asks for AT-SPI). ᶜ Only the end state was captured for libcosmic, not the focus after the first Shift+Tab.

**M7 verdict as the brief defines it (through AT-SPI): libcosmic 0 of 12 steps verifiable; Slint 6 of 12 fully verified (2, 4, 5, 6, 8, 10), 2 partly (1 and 3: focus and path pass, selection not verifiable), 4 not verifiable (7, 9, 11, 12).** Nothing failed where a check was possible. The behavioural columns (stdout, clipboard and hand-reviewed screenshots) are supporting evidence only: by them 12 of 12 steps behave as specified for both prototypes, but the brief rules that method out for the §9 row, so #14 should read the AT-SPI columns as the gate result and the behavioural ones as context. Mouse paths are not part of this walkthrough.

## M9: build

Clean `cargo build --release --locked` in the VM (4 vCPU M1 Max, aarch64, dependencies already downloaded, nothing else running), `tools/d006/m9-build.sh`; [`d006-data/vm/m9.json`](d006-data/vm/m9.json). Not measured on x86_64 CI or the NUC (building there is outside the "nothing compiles on the NUC" rule).

| | libcosmic | Slint |
| --- | --- | --- |
| Build time | 181.8 s | 129.4 s |
| Stripped binary | 21,203,232 B | 20,731,440 B |
| Crates in `Cargo.lock` | 679 | 561 |
| Lines of Rust and markup (blank and `//` lines excluded) | 560 | 495 |

## Limitations

- No NUC numbers; the CI runner (AMD EPYC, 2 vCPU, shared) and the VM (Apple M1 Max, aarch64) differ from the N5105 in CPU speed, architecture, memory and kernel. Absolute numbers do not count against §7. Comparisons between the two prototypes hold within an environment, and the ordering was the same in both, but both environments are headless sway with software rendering; the ordering may differ on the NUC's GPU path.
- **The software-rendering setup is not neutral between the two prototypes.** libcosmic's default features have no `wgpu`, so its renderer is `iced_tiny_skia` (CPU) everywhere, including on the NUC: its M5 numbers are its real path, a GPU would not change them. Slint renders with femtovg on OpenGL ES, which here runs on Mesa's llvmpipe (see the `egl:` line in each `environment.txt`). Its M1, M3 and first-launch numbers therefore include loading LLVM and JIT-compiling shaders, likely the cause of the CI timeouts (footnote ¹) and part of its ~148 MB RSS; a GPU driver would not pay that cost. This setup favours libcosmic on M1 and M3, and says nothing about Slint on a GPU. If the NUC picks a GPU driver through the render node (`iris`), the `egl:` line will show it and Slint's numbers will change.
- Sway runs headless (pixman) in every environment, not on a real display.
- Runs go all libcosmic first, then all Slint (not alternating), so the one-time first-launch effect falls on different points for each toolkit.
- Warm page cache; a true cold cache is not measured.
- First-launch slowness on CI (footnote ¹) was seen in two runs on two runners, with different outcomes (timeouts for Slint in one, ~2 s for both in the other); it is not a measured distribution.
- Mouse input untested. `wtype` modifier handling differs per toolkit (deviation 4).
- Slint's M5 hook runs from the toolkit's per-frame clock and libcosmic's from `window::frames()`; the two measure "frames the app commits", not frames shown.
