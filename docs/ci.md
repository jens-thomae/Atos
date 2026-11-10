# CI: which workflow runs when

The repository is public, so standard GitHub-hosted runners cost nothing (GitHub's Actions billing docs, checked 2026-11-10). The aim is no longer to save minutes but to make a pull request wait only for the checks its change can break, while the nightly runs guard everything else.

## Two lanes

- **Pull request lane (fast).** Each workflow decides from the changed paths whether it can be affected. A shell or toolkit change waits for `CI`, `C3 shell` and `Slint fork` (about 1–15 minutes), not for the image build. The image is built per pull request only when the image recipe itself changes.
- **Nightly lane (complete).** Every night `main` is built and checked in full: the base image from scratch with its boot check (`c1-base.yml`), the workspace with the full 5-minute idle-CPU window (`ci.yml`), and the budgets on the reference NUC (`perf.yml`). A broken image build on `main` shows up the next morning as an open issue (below), not on the next unrelated pull request.

Merges to `main` publish the image for every change that ends up in it, so `:latest` always matches `main`.

## Which workflow runs when

Durations are the median (10th–90th percentile) of the last 500 successful runs on 2026-11-10, rounded. A run that skips all its jobs takes under a minute.

| Workflow | Pull request | Push to `main` | Scheduled / manual | Typical duration |
| --- | --- | --- | --- | --- |
| `ci.yml` (lint, build, tests, budgets) | Always; the `rust` job is skipped for docs-only changes (`tools/ci/is-docs-only.sh`) | Always | Nightly 03:00 UTC, idle CPU over the full window | about 1 min (PR), 6 min (nightly) |
| `c1-base.yml` `build` (image build, checks, boot check) | Only for image changes (`is-image-change.sh pr`, below) or with the label `full-ci` | Never | Never | 9–21 min |
| `c1-base.yml` `publish` (build, push, sign, `:latest`) | Never | Only for changes that end up in the image (`is-image-change.sh publish`, below) | Never | 24 min (up to 45) |
| `c1-base.yml` `nightly` (`main` from scratch, checks, boot check, no push) | Never | Never | Nightly 02:00 UTC, or `gh workflow run c1-base.yml` | 38 min (first run, from scratch, on #210) |
| `c2-compositor.yml` | C2, the toolchain pin or the workflow changed (`paths`) | Same | Never | about 5 min |
| `c3-shell.yml` | C3, C4, `third_party/slint` or the workflow changed (`paths`); NUC job only with the label `c3-nuc` | Same | Manual | 8–16 min |
| `slint-fork.yml` | Slint, the fork tooling, C4 UI or the workflow changed (`paths`) | Same | Manual (dry-run rebase) | 3–9 min |
| `c11-installer.yml` | C11 or the workflow changed (`paths`) | Same | Manual | 11–16 min |
| `audit.yml` (cargo audit, cargo deny) | A manifest, lockfile, policy or the workflow changed (`paths`) | Same | Mondays 05:00 UTC | under 1 min |
| `base-mirror.yml` | Push to any branch of this repository that changes a base pin | Same | Manual | under 1 min |
| `perf.yml` (NUC) | Only with the label `perf` (`docs/budgets.md`) | Never | Nightly 01:30 UTC | 6 min (nightly) |
| `upstream-watch.yml` | Never | Never | Mondays 06:00 UTC | under 1 min |
| `d006-measure.yml`, `t59-layer-shell.yml` (spikes) | Only with their labels | Never | Manual | varies |

## The image paths (`tools/ci/is-image-change.sh`)

The `changes` job in `c1-base.yml` lists the changed paths with `tools/ci/changed-paths.sh` and asks the script once per lane. A pull request is diffed against its base. A push is diffed over the whole pushed range (`github.event.before..HEAD`), so every commit of a rebase merge or multi-commit push counts. If there is no usable range (a new branch, or a force push), every lane runs. The diff uses `--no-renames` (a rename counts both its old and new path) and `-z` (names with non-ASCII characters are not quoted, so they still match). Both scripts are tested by `tools/ci/test-is-image-change.sh`, which the same job runs first. Docs (`*.md`, `LICENSE*`) never count, except under `.github/` and `tools/`.

| Changed path | PR `build` | `publish` |
| --- | --- | --- |
| `components/c1-base/**`, `third_party/bootc/**`, `rust-toolchain.toml`, `.github/workflows/c1-base.yml` | yes | yes |
| `tools/ci/**` | yes | no (not in the image) |
| `components/c2-compositor/**`, `components/c3-shell/**`, `components/c4-toolkit/**`, `third_party/**`, `tools/slint-fork/**` | no (own workflows, nightly) | yes |
| Anything else (docs, C5 to C11, other tools, other workflows) | no | no |

The `publish` list is what the Containerfile copies from the repository (`COPY --from=repo`). A change to that list in the Containerfile needs the same change in the script. `publish` also runs when the workflow changes, so a change to how the image is published is exercised once it is merged.

**Label `full-ci`.** Forces the PR `build` for a branch of this repository (not for forks), for example for a C2 or C3 change that should be boot-checked before merging. Adding the label starts the build at once; it stays in force for later pushes until the label is removed. Adding any other label starts a `c1-base.yml` run that skips every job and cancels nothing.

**Why `if`, not `paths:`.** A workflow skipped by path filtering leaves its checks Pending, which blocks merging if they are ever required. A job skipped by `if` reports Success. The same holds for the docs-only skip in `ci.yml`.

## Nightly failures

`c1-base.yml` `nightly-report` runs after `nightly` (success or failure, not when cancelled) and calls `tools/ci/nightly-issue.sh` (tested by `tools/ci/test-nightly-issue.sh`):

- failure: comments the run link on the open issue titled **"Nightly image build failed"** that `github-actions[bot]` opened, or opens one. The repository is public, so an issue with the same title opened by anyone else is ignored;
- success: closes that issue with the run link.

It is the only job in the workflow with `issues: write`, and it runs no build. On a manual run from a branch other than `main` it only prints what it would do. The `nightly` job itself has only `contents: read`: it pushes nothing, and the base mirror is public.

## Other rules

- **Cancel superseded runs.** A new push to a pull request cancels its older run (`ci.yml`, `c1-base.yml`). Runs on `main` and scheduled runs are never cancelled; `publish` runs one at a time. The NUC workflows keep their own concurrency.
- **Artifacts.** Public visibility makes minutes free, not storage: artifacts still count against the account's storage allowance (GitHub's billing docs, checked 2026-11-10). Every `upload-artifact` step therefore sets `retention-days` (7 or 14), and the installer ISO (about 2 GB) is not uploaded.
- **Source bundle (`publish`, #85).** Adds about 1 minute to a publish run and about 10 MB per image in the registry (`git archive | gzip` of the tree was 9.5 MB on 2026-11-06).
