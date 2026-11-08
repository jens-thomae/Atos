# CI: hosted runner minutes

Free plan: 2,000 hosted minutes per month. `ci.yml` saves minutes as follows.

- **Docs-only skip.** A cheap `changes` job diffs the PR (logic in `tools/ci/is-docs-only.sh`, tested by `tools/ci/test-is-docs-only.sh`; a rename counts both its old and new path). If every changed file is under `docs/`, a `*.md` or a `LICENSE*` file (and none is under `.github/` or `tools/`), the `rust` job is skipped. Pushes to `main` and the nightly run always build.
- **Why not `paths-ignore`.** A workflow skipped by path filtering leaves its required checks Pending, which blocks merging. A job skipped by `if` reports Success, so a required `rust` check (if branch protection is added) still passes on docs-only PRs. The check name `rust` is unchanged.
- **Cancel superseded runs.** `ci.yml` cancels the older run for a PR on a new push. The nightly and `main` runs are never cancelled. The NUC workflows keep their own concurrency.
- **`c1-base.yml`** (base image, `docs/components/c1-base/`) uses the same docs-only check, but also on pushes to `main`: a docs-only merge builds no image.
- **Artifacts.** Every `upload-artifact` step sets `retention-days` (7 or 14).

Docs-only commit used to demonstrate the skip: this file is documentation.
- **`audit.yml`** (cargo audit and cargo deny, both workspaces, `docs/components/c2-compositor/upstream.md`): no compile, about 1–2 minutes. Runs only when a manifest, lockfile or the policy changes, plus once a week.
- **Source bundle (`c1-base.yml` publish, #85).** Adds about 1 minute to a publish run (`git archive`, `rpm -qa`, a one-layer build, push, sign). Package size: about 10 MB per image (`git archive | gzip` of the tree on 2026-11-06 was 9.5 MB; the tarball differs per commit, so layers are not shared). Measured numbers are to be recorded from the first run on `main`.
- **`upstream-watch.yml`** (weekly upstream tag and security-keyword check, opens issues, `docs/components/c2-compositor/upstream.md`): hosted runner, one job, checkout + a `git clone --filter=blob:none` of upstream + a few `gh` calls, about 0.5–1 minute per run, so **about 2–5 minutes a month** (4–5 Mondays). Estimate, not yet measured; the first dispatch run on the PR shows the real number.
- **`c11-installer.yml`** (installer ISO, `docs/components/c11-installer/`): builds the amd64 installer image and ISO with the published c1-base image as payload, installs it under QEMU with KVM and boots the result twice. Runs only when `components/c11-installer/**` or the workflow changes, plus manual dispatch (`paths` filter; it is not a required check). About 12 minutes per run (first green run on #135: ISO build about 9 minutes, KVM install 105 s, two boots under 30 s); it fails when the install takes over 600 s (§7). The ISO is not uploaded (artifact storage on the Free plan is 500 MB). Note: `c1-base.yml` also runs on these changes, because it treats every non-docs path as code.
