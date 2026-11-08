# C4 toolkit: our Slint fork

Decision: D-006 (Slint). Card: #52. Licence rule: D-013. Spec: [§6 C4](../../spec.md#c4-ui-toolkit-and-sdk).

## Version

| | |
| --- | --- |
| Upstream | [slint-ui/slint](https://github.com/slint-ui/slint), tag `v1.18.1`, commit `372cf0ee5577c3dfec309a45e7b778ba4e81b734` |
| Pin | [`third_party/slint/UPSTREAM`](../../../third_party/slint/UPSTREAM). The script checks the commit, not the tag name |
| Patch queue | [`third_party/slint/patches/`](../../../third_party/slint/patches/) |
| Tool | [`tools/slint-fork/slint-fork.sh`](../../../tools/slint-fork/slint-fork.sh) |
| CI | [`.github/workflows/slint-fork.yml`](../../../.github/workflows/slint-fork.yml) |

## Why a pinned commit plus a patch queue (not vendored, not a GitHub fork)

- **Not vendored.** A shallow Slint checkout is 61 MB and 5,334 files. Committing it would bury our patches in every diff and bloat every clone, and a rebase would be a 60 MB commit.
- **Not a GitHub fork.** It needs a second repository, outside the card/PR/review flow and the CI of this one. Patches there are invisible to a reviewer of this repo.
- **Patch queue.** Each change is one `git format-patch` file in this repo, so a PR shows exactly what we changed in Slint, one reviewable file per change. A rebase is "apply the queue onto a new pin" (`git am --3way`) and tells us at once which patch conflicts. Cost: the source is fetched at build time (one `git fetch --depth 1` of 61 MB from GitHub, about 4 s) and a patch needs a checkout to author (see below). The pinned commit SHA is checked, so a moved tag cannot change what we build.
- D-007 (no upstream contributions) means the queue is permanent; this layout is built for that.

## Use

```sh
tools/slint-fork/slint-fork.sh setup     # fetch the pinned commit into third_party/slint/src, apply the queue, write patch.toml
cd spikes/d006-slint
cargo build --release --config ../../third_party/slint/patch.toml
```

`third_party/slint/src/` and `patch.toml` are generated and git-ignored. `patch.toml` is a `[patch.crates-io]` table with one path entry per Slint crate, so every Slint crate in the dependency graph (`slint`, `slint-build`, `i-slint-*`) comes from the checkout. A crate that uses Slint needs only `slint = "=1.18.1"` in its manifest and the `--config` flag. Nothing in a manifest names the checkout, so a crate still resolves from crates.io when the flag is missing. Root workspace crates that start using Slint (C3, C5) pass the same flag. Cargo rewrites that crate's `Cargo.lock` with path sources when it builds with the flag; do not commit that rewrite.

**CI time** (Free plan minutes, [docs/ci.md](../../ci.md)): the `Slint fork` job took 7 min 58 s on a cold cache (7 min 15 s of it the spike's release build). It runs only when `third_party/slint/`, `tools/slint-fork/`, `spikes/d006-slint/` or its workflow change, so it costs about 8 minutes per such PR push, nothing otherwise.

Check that the fork is in use: `cargo tree -p slint --config .../patch.toml | head -1` must print a path under `third_party/slint/src`. CI checks it.

## Add a patch

1. `slint-fork.sh setup`, then edit `third_party/slint/src` and commit **one change per commit** with a message that says what and why (and which card).
2. `slint-fork.sh export` rewrites `third_party/slint/patches/NNNN-*.patch` from the commits since the pin.
3. Add a row to the table below in the same PR. Run `slint-fork.sh rebase master` to see whether it still applies to upstream's head.

## Renderers (D-006)

Slint's default features already give what D-006 asks, so the fork changes no feature flags:

- `renderer-femtovg` (OpenGL ES through EGL) is the default renderer of the winit backend.
- `renderer-software` is built in as well. Slint falls back to it on its own when no GPU renderer can be created (`try_create_window_with_fallback_renderer` in `internal/backends/winit/lib.rs`), and `SLINT_BACKEND=winit-software` forces it (used by the software-renderer measurements, #36).
- Skia and wgpu features stay off (D-006 §3.3; they would add native build dependencies).

## Licence (D-013)

Slint is used under **GPL-3.0-only**, one of its three options. We do not use the Royalty-free or Software licences (D-006 §3.5: both forbid distributing an application that exposes Slint's API, which our SDK does). So every binary we ship that links Slint (C3 shell, C5 apps, SDK examples) is conveyed under GPL-3.0-only, with its source. Our own source files stay under MIT OR Apache-2.0 (D-013). The patches are changes to Slint's files, so they are under the licence option we use for Slint, GPL-3.0-only.

## Patch list

| # | Patch | Files | Card | Why |
| --- | --- | --- | --- | --- |
| – | (none yet) | | | The queue is created by this card; patches follow in #62 (accessibility roles) and the clipboard card. The layer-shell spike (#59) needed none: see [layer-shell-spike.md](layer-shell-spike.md) |

See [rebase.md](rebase.md) for the routine and the first dry-run record.

## Testing

Headless screenshot and accessibility-tree tests: [screenshot-tests.md](screenshot-tests.md).

## Patch queue

| Patch | Card | What |
| --- | --- | --- |
| `0001-a11y-add-Row-…` | #62 | New `AccessibleRole` values `row`, `column-header`, `menu`, `menu-item`, `dialog`, mapped in the AccessKit, Qt and testing backends. The AccessKit mapping is a plain match, so it moves unchanged into a backend-neutral adapter (#59 decision) |
| `0002-a11y-use-the-new-roles-…` | #62 | `StandardTableView` (fluent, cosmic, cupertino, material; not the native qt style): column headers named by title; rows with label (first cell), selected, index and default action. Menus (all styles, via `menu-base.slint`): `menu` frame, `menu-item` with title, enabled, checked, expandable and default action |
| `0003-a11y-report-size-of-set-…` | #94 | A5: `StandardListView` items and `StandardTableView` rows carry the model length as size of set (with their index as position), and the table's list carries it too, so rows that are not instantiated stay addressable. Slint instantiates only visible rows; the total plus each live row's index lets an assistant scroll to any row. Pure `.slint`, no backend code |
| `0004-a11y-name-popups-…` | #95 | AccessKit: popup roots become `Menu`, `Dialog` or `Tooltip` nodes named by `accessible-label` or title; `Dialog` windows get the dialog role (compiler default). See [popups-and-dialogs.md](popups-and-dialogs.md) |

Checkable is set on menu items that are checked, because `MenuEntry` has no separate checkable flag.
