# CI: hosted runner minutes

Free plan: 2,000 hosted minutes per month. `ci.yml` saves minutes as follows.

- **Docs-only skip.** A cheap `changes` job diffs the PR. If every changed file is under `docs/`, a `*.md` or a `LICENSE*` file (and none is under `.github/` or `tools/`), the `rust` job is skipped. Pushes to `main` and the nightly run always build.
- **Why not `paths-ignore`.** A workflow skipped by path filtering leaves its required checks Pending, which blocks merging. A job skipped by `if` reports Success, so a required `rust` check (if branch protection is added) still passes on docs-only PRs. The check name `rust` is unchanged.
- **Cancel superseded runs.** `ci.yml` cancels the older run for a PR on a new push. The nightly and `main` runs are never cancelled. The NUC workflows keep their own concurrency.
- **Artifacts.** Every `upload-artifact` step sets `retention-days` (7 or 14).

Docs-only commit used to demonstrate the skip: this file is documentation.

Demo: docs-only change against the T-40 branch.
