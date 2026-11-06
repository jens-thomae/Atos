# Rebasing the Slint patch queue

Run for every Slint release we decide to follow (minor and patch releases alike: the accessibility internals we patch are `#[doc(hidden)]` and change without semver notice, D-006 §3.4). Budget from the dry run below.

## Routine

1. **Dry run.** `tools/slint-fork/slint-fork.sh rebase <new tag>` fetches the tag in a scratch clone and applies the queue with `git am --3way`. It prints the first patch that fails. Takes seconds.
2. **Move the pin.** Edit `third_party/slint/UPSTREAM` (`tag`, `commit`; take the commit from `git ls-remote https://github.com/slint-ui/slint <tag>^{}`). Run `slint-fork.sh setup`.
3. **Fix conflicts.** `setup` stops at the failing patch inside `third_party/slint/src` (a `git am` in progress). Resolve, `git am --continue`, repeat. Change the patch only as far as upstream changed.
4. **Re-export.** `slint-fork.sh export` rewrites `patches/`. Review `git diff third_party/slint/patches` (a patch whose diff changed more than its context is a patch to re-read).
5. **Update dependants.** Raise the `=x.y.z` pin of `slint` and `slint-build` in every crate that uses it. Build everything with the fork (`cargo build --config .../patch.toml`), fix API drift. Run the C4 and app tests and the accessibility checks once they exist.
6. **Record.** Update the version table and patch list in [README.md](README.md), and append a row to the log below: the date, versions, conflicts, build or API fixes, and hours spent. The log is the evidence for how often following upstream is affordable.
7. **Check licence.** Read the new release's `LICENSE.md` and changelog: the GPL-3.0-only option must still be there, and no new mandatory dependency under another licence (D-013).

## Log

### 2026-11-06: first dry run, v1.18.1 onto upstream `master` (1.19.0, unreleased)

There was no release after v1.18.1 (published 2026-09-21), so the dry run went onto upstream `master` at `fb4aef8`, which is 1.19.0 in development. It is the closest available proxy for the next release.

The queue was empty, so the run used three **probe patches**, made to touch the places the real patches will (D-006 §3.4: A2 roles). They were not committed:

1. add `AccessibleRole::Row` in `internal/common/enums.rs`;
2. map it to `Role::Row` in `internal/backends/winit/accesskit.rs`;
3. touch `internal/compiler/widgets/fluent/tableview.slint` (the file the table patch will change).

| Step | Result | Time |
| --- | --- | --- |
| `slint-fork.sh rebase master` | all three apply with `--3way`, no conflict | 7 s |
| Same onto `v1.17.1` (one release back) | all three apply | 4 s |
| Build the `d006-slint` spike against master with the probes (only change in the spike: `=1.18.1` to `=1.19.0` in `Cargo.toml`) | builds, no source change in the spike | 1 min 19 s (release, 10-core Apple M1 Max, cold target dir, dependencies downloaded) |
| Fix-ups needed | none | 0 |

**Effort: 0 conflicts, 0 code fixes; about 2 minutes of machine time (apply plus build).** Caveats, so nobody reads this as a forecast: three one-line probes are much smaller than the real patches (~1–1.5k lines for the shell-surface accessibility port, D-006 §3.4), and the layer-shell and accessibility-port patches use `#[doc(hidden)]` items that the probes do not touch. D-006 §3.4 expected "a few hours to a day" per minor release for those. **That estimate stays unmeasured until a real patch exists:** repeat this log entry at the first real rebase.

Findings:

- `--3way` needs the blobs the patches were made against; `rebase` therefore also fetches the pinned commit into the scratch clone (without that, git reports "sha1 information is lacking").
- Slint master needs rustc 1.95; we pin 1.99.1 (D-009), so no conflict.
- The spike's committed `Cargo.lock` cannot be used with the fork (path sources replace the crates.io entries), so cargo rewrites it; CI discards that.
