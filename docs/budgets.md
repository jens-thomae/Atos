# Budget checks

How the quality budgets in [`spec.md` §7](spec.md#7-quality-budgets) are measured. The limits live in one table, `limits` in [`tools/budgets/src/lib.rs`](../tools/budgets/src/lib.rs); change it together with §7.

## The harness

`tools/budgets` is a Rust binary (standard library only) that launches an app and measures it. It reads `/proc`, so it runs on Linux only.

```sh
cargo build --release -p budgets
target/release/budgets <app> [--cpu-window <seconds>]   # default window: 10 s
```

It prints a Markdown table (metric, budget, measured, result) and exits with 1 if a budget is breached, 2 if it could not measure.

1. **Cold start:** time from spawning the app to the line `BUDGET_FIRST_FRAME` on its stdout. An app prints that line when its first usable frame is presented.
2. **Idle RSS:** `VmRSS` from `/proc/<pid>/status`, 5 s after the first frame.
3. **Idle CPU:** user plus system time from `/proc/<pid>/stat` over the CPU window that starts right after, in percent of one core.

`budget-test-app` (in the same crate) is a stand-in app: it prints the marker, holds 4 MB and sleeps.

## In CI

The `Budgets` step of the `rust` job in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs the harness on `budget-test-app` and appends the table to the job summary. A breach fails the job. Pull requests and pushes use a 10 s CPU window; a nightly scheduled run uses the full 5 minutes.

Runs happen on GitHub-hosted `ubuntu-24.04` runners, not the reference hardware (Intel NUC 11, Celeron N5105), so absolute numbers are indicative until the self-hosted runner exists (#17).

## Budget coverage

| §7 budget | Measured in Phase 0 | How | Rest comes in |
| --- | --- | --- | --- |
| Input: pointer and keystroke to pixel ≤ 30 ms | No | Needs a compositor and hardware | Phase 1 |
| Input: visual feedback on the next frame | No | Needs a compositor and hardware | Phase 1 |
| Shell: menu, popover or palette visible ≤ 100 ms | No | Needs a shell | Phase 1 (minimal shell), Phase 2 (palette) |
| Shell: no dropped frames | No | Needs a compositor and hardware | Phase 1 |
| Apps: cold start ≤ 300 ms | Yes | Harness, `BUDGET_FIRST_FRAME` marker; test app now, D-006 prototypes in #12 | Real apps from Phase 2; true cold cache on the reference runner (#17) |
| Apps: Files opens 10,000 items ≤ 500 ms to first paint | Not yet | Same marker convention, on the D-006 Files prototypes (#12) | Phase 0 (#12), then Files in Phase 2 |
| System: idle desktop RAM ≤ 800 MB | Partly | Harness, one app's RSS against the desktop limit | Whole desktop after login in Phase 1 |
| System: idle desktop CPU ≤ 1 % over 5 min | Partly | Harness, one app, percent of one core; 10 s on PRs, 5 min nightly | Whole desktop in Phase 1 |
| System: boot to usable desktop ≤ 10 s | No | Needs an image and hardware | Phase 1 |
| Stability: 0 known crashers | No | Needs apps and crash reporting | Phase 3 gate |
| Stability: automatic rollback on failed update | No | Needs an image | Phase 1 |
| Accessibility: keyboard and screen reader | No | Needs apps | Phase 2 onwards |
| Accessibility: contrast ≥ 4.5:1 body, ≥ 3:1 large | Partly | `contrast_ratio` and `contrast_passes` (WCAG 2.x), unit-tested; no theme tokens to check yet | When the design-system tokens land in the repo |
