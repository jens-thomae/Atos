# Screenshot and accessibility tests

Card: #60. Crate: [`components/c4-toolkit/test-harness`](../../../components/c4-toolkit/test-harness) (`atos-ui-test`).

Render a Slint component headless, compare it with a stored PNG and assert on the accessibility tree.
It uses the testing backend of our Slint fork with the software renderer, so it needs no display or GPU.

## Write a test

See the example: [`tests/greeting.rs`](../../../components/c4-toolkit/test-harness/tests/greeting.rs) and [`tests/ui/greeting.slint`](../../../components/c4-toolkit/test-harness/tests/ui/greeting.slint).

1. In `build.rs`, compile the `.slint` file with `with_debug_info(true)`. The accessibility queries need it.
2. In the `.slint` file, `import` the bundled `fonts/NotoSans-Regular.ttf` and set `default-font-family: "Noto Sans"`. Without it, text depends on the fonts installed on the machine.
3. In the test, call `init()` first, create the component, then use:
   - `assert_screenshot(&ui, env!("CARGO_MANIFEST_DIR"), "name")` compares with `tests/screenshots/name.png`.
   - `assert_accessible(&ui, AccessibleRole::Button, "Save")` checks that an element with this role and accessible label exists. On failure it prints the whole tree.
   - `accessibility_tree(&ui)` returns all (role, label) pairs; `find_by_label` returns the element to click or read.

`init()` sets a per-thread platform, so run tests with `cargo nextest` (one process per test) or one `#[test]` per file.

## Tolerance

A pixel differs when any channel (RGBA, 0–255) differs by more than 2 (`CHANNEL_TOLERANCE`). The test fails when more than 0.1% of all pixels differ (`MAX_DIFFERING_PIXELS`) or the size differs.
Both constants are in `src/lib.rs`; change them there, for all tests, only with a reason on the card.

## Run and update

```sh
tools/slint-fork/slint-fork.sh setup     # once
cd components/c4-toolkit/test-harness
cargo nextest run --config ../../../third_party/slint/patch.toml
UPDATE_SCREENSHOTS=1 cargo nextest run --config ../../../third_party/slint/patch.toml   # rewrite references
```

Review changed PNGs in the PR like code. The reference was made on macOS and is checked on Linux in CI; if CI shows a diff only there, regenerate the reference from the CI `actual.png`.

## On failure

The test writes `<name>.actual.png` and `<name>.diff.png` (differing pixels red) to `$SCREENSHOT_DIFF_DIR`, default `target/screenshot-diffs`.

## CI

Job `Slint fork` in [`slint-fork.yml`](../../../.github/workflows/slint-fork.yml) runs fmt, clippy and `cargo nextest run` for this crate, and uploads `screenshot-diffs` on failure (retention 7 days).
It runs only when `third_party/slint/`, `tools/slint-fork/`, `spikes/d006-slint/` or `components/c4-toolkit/test-harness/` change, so main CI minutes are unchanged. Slint is built from source there (see [README](README.md)); the cache covers repeat runs.
Component crates that start using the harness (C3, C5) need their own tests added to a workflow with the same steps.

## Limits

- Software renderer only. The GPU renderer is not compared pixel for pixel (D-006).
- The crate lives outside the root workspace because it builds Slint through the fork; `cargo nextest run` at the root does not run it.
