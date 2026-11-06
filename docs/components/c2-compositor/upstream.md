# C2: following upstream (cosmic-comp)

D-007: we carry our fork and follow upstream by **merging, never by contributing**. This page is the merge routine, the security watch and the dependency checks. Fork point and downstream changes: [README](README.md).

## Merge routine

**Rhythm (proposal, the owner confirms):** one merge per upstream Epoch tag (`epoch-X.Y.Z` on <https://github.com/pop-os/cosmic-comp>), started within two weeks of the tag. Between tags we merge only security fixes (next section). Epoch releases are the only points upstream calls stable; merging `master` continuously would mean tracking half-finished work for no gain. If an Epoch tag is more than 6 months old with no newer one, do a merge against `master` once, so drift stays bounded.

Check for a new tag: `git ls-remote --tags https://github.com/pop-os/cosmic-comp 'epoch-*'`.

Steps (a Builder on a card "C2: merge epoch-X.Y.Z"):

1. Clone upstream outside the repo (`git clone --filter=blob:none`). Diff old base → new tag: `git diff epoch-OLD epoch-NEW > up.diff`. The old base is the tag in the README's fork-point table.
2. Apply with the component path and the renames. Upstream paths map as: `cosmic-comp-config/` → `atos-comp-config/`, `resources/i18n/*/cosmic_comp.ftl` → `atos_comp.ftl`, `data/cosmic-comp.service` → `data/atos-comp.service`. Files we removed (README "Removed": `.github/`, `debian/`, `flake.*`, `rust-toolchain.toml`, bare-session data) are dropped from the diff. `git apply --reject --directory=components/c2-compositor up.diff` after renaming those paths inside `up.diff` (`sed`). Resolve every `.rej` by hand; our downstream changes are listed in the README and are the only expected conflicts.
3. Take upstream's `Cargo.lock` changes, then re-apply our edits to `Cargo.toml` (package name, `rust-version`, authors). Run `cargo update` only for crates named by a security advisory.
4. Build and test: the `C2 compositor` workflow, or in the dev VM `cargo build --locked && cargo test --locked && cargo clippy --all-targets --locked -- -D warnings`. New clippy findings on the repository toolchain are fixed minimally and listed in the README.
5. Run the audit checks below; new advisories or licences are fixed or recorded in `deny.toml` with a reason.
6. Update the README: fork-point table (new tag, commit, date), downstream changes, "Deliberately not renamed". Record the effort below.
7. One PR, commits `T-NNN: merge epoch-X.Y.Z`. The PR text lists conflicts and how each was resolved.

### Effort log

| Run | Date | From → to | Files in diff | Conflicts | Effort |
| --- | --- | --- | --- | --- | --- |
| 1 | 2026-11-06 | `epoch-1.11.0` → none (no newer Epoch tag exists; 1.11.0 is the latest) | 0 | 0 | The real merge is a no-op. **Rehearsal** against upstream `master` (`63dacd1`, 32 commits after the tag, nothing released): 45 files, +713/−832. With paths unmapped, 6 files fail on renames (config crate, 5 `.ftl` files) and `rust-toolchain.toml`; with mapping, 4 files conflict: `Cargo.toml` (our `rust-version`/authors/name) and the three files where we patched clippy findings (`utils/ids.rs`, `shell/element/stack.rs`, `shell/focus/mod.rs`). Estimated a Builder session of about one hour for this size. The rehearsal was done by `git apply --reject` and reverted; nothing from `master` was merged. |

Append a row per run. Expect conflicts to grow with every downstream feature (scroll tiling, design tokens): that is the cost of D-007 and the reason to keep downstream changes small and listed.

## Security watch

Goal: an upstream security fix reaches `atos-comp` within days, outside the merge rhythm.

1. **Dependencies (automatic).** `audit.yml` runs `cargo audit` and `cargo deny` weekly (Monday) and on every change to a manifest or lockfile. A new RustSec advisory for any crate in C2's lockfile (Smithay, libcosmic and the rest included) fails the scheduled run. Fix: `cargo update -p <crate>` in `components/c2-compositor/`, or a documented ignore in `deny.toml` + `.cargo/audit.toml` when it is unreachable (see the quick-xml entries).
2. **cosmic-comp itself (manual, cheap).** The owner watches `pop-os/cosmic-comp` on GitHub for *Security alerts* and *Releases* (Watch → Custom; watching is not contributing). Anything labelled security, plus the weekly check below, opens a card "C2: cherry-pick upstream fix <ref>".
3. **Weekly check.** Whoever does the Monday audit-run triage also runs `git log --since='8 days ago' --grep -iE 'security|CVE|overflow|use-after|unsound|crash' origin/master` in a throwaway clone of upstream and reads hits. ponytail: manual; automate with a scheduled agent only if it proves worth it.
4. **Cherry-pick.** Take the upstream commit's diff (`git show <sha> | git apply --directory=components/c2-compositor`, with the path mapping of the merge routine), one commit `T-NNN: cherry-pick upstream <sha> (<what>)`, and add a line to the README "Downstream changes" so the next merge knows the fix is already in (the merge then drops it).
5. **Severity.** A fix for something reachable from a client or from input is released with the next image; others wait for the next merge.

## Dependency checks

`audit.yml` (workflow "Dependency audit"), policy in `deny.toml` (repository root) and `.cargo/audit.toml`. Covers both workspaces: the root and `components/c2-compositor/` (the throwaway `spikes/` are excluded, spec §9).

- **Advisories:** vulnerabilities and unsound crates fail; unmaintained and yanked crates warn. Ignores need a reason and a revisit at each merge.
- **Licences (D-013):** allow-list of permissive licences plus MPL-2.0 (libcosmic, a build dependency of C2) and `GPL-3.0-only` / `GPL-3.0-or-later` (for C2 only, which is `GPL-3.0-only`). The root workspace is `MIT OR Apache-2.0` and has no GPL dependency today; `cargo deny` runs per workspace but one list serves both, so a GPL crate added to a non-C2 workspace would pass this check. Reviewers must watch for it. ponytail: per-workspace allow-lists when a second workspace gets copyleft dependencies.
- **Sources:** only crates.io, the `pop-os` and `smithay` GitHub organisations, and two named git forks that upstream uses (`atomicwrites`, `id-tree`).
- **Clarifications:** nine git crates have no licence field; `deny.toml` states their licence from the repository's LICENSE file (checked 2026-11-06). The clarify hashes are `0x00000000`, which cargo-deny 0.20.2 accepts without checking (shown by the run being green); they do not protect against the licence changing on a revision bump. Reviewers read licence changes on lockfile diffs.
- **First run (2026-11-06):** it found four advisories in upstream's lockfile. Fixed by `cargo update -p anyhow -p async-executor -p chacha20 -p rand@0.10.0` (patch bumps, lockfile only). Two on `quick-xml` 0.39 stay ignored: only `wayland-scanner` (a build-time proc-macro on trusted XML) uses it and the fix needs 0.41.

**Hosted minutes (Free plan):** one job, no compile, no system libraries: checkout, prebuilt tool binaries (`taiki-e/install-action`), `rustup toolchain install`, two `cargo audit`, two `cargo deny` (git dependencies are fetched). Expected about 1–2 minutes per run (not yet measured on a hosted runner; see the first run of the PR). Triggers: PRs and pushes to `main` that touch a manifest, lockfile or the policy, and one scheduled run a week (about 4–9 minutes a month). Permissions: `contents: read`; actions SHA-pinned.
