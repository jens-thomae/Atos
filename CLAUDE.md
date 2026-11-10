# CLAUDE.md

You are working on a new Linux-based desktop OS: a Wayland compositor, shell, UI toolkit and native app suite on a signed, image-based base. You remember nothing from earlier sessions. This file, `docs/`, the task board and the git history are the project's only memory, so read before you act.

## Start of every session

Read in this order before writing any code:

1. This file.
2. `docs/spec.md` sections 1–3 (rules, mission, scope) and 9–10 (agent operating model, project management).
3. Your task card (GitHub issue): `gh issue view <number> --comments`. Read the **last handoff note** first.
4. The spec sections linked on the card, usually §6 (your component) and §7 (quality budgets).
5. `docs/spec.md` §5 (decisions log) for anything your task touches.
6. `docs/README.md` (what to read for your kind of task) and the component's code map, where one exists.
7. For any UI work: the owner provides the design system when relevant. Use only its values; if it is missing, ask on the card.

If you have no task card, stop and ask the owner. Do not choose work yourself.

## Non-negotiable rules

- **One card, nothing else.** Work only on your assigned card. Anything else you notice becomes a new issue (`gh issue create`), not an unasked change.
- **Decided means binding.** Never contradict a _Decided_ entry in the decisions log. If you think one is wrong, add a _Proposed_ entry in a comment on the card and move the card to Blocked.
- **Never invent requirements.** If the spec or card is silent or ambiguous, write the question on the card, move it to Blocked and stop.
- **Do not edit `docs/spec.md` or this file.** Propose changes in a card comment; only the owner changes them.
- **Stay in your component.** Do not modify code owned by another component (C1–C12) unless the card says so.
- **Budgets are release blockers.** A change that breaks a quality budget in §7 is not done, even if it works.
- **Never mark your own work approved.** A separate reviewer agent and the owner accept work.

## Session protocol

1. Read (see above).
2. Move the card to **In progress** and comment a plan of at most 3 lines.
3. Create a branch named after the card: `T-<issue number>-<short-slug>`, for example `T-142-files-split-view`.
4. Implement in small commits. Commit messages: `T-142: <imperative summary>`.
5. Run tests, lints and the budget checks for the component (see Commands).
6. Open a pull request with `gh pr create` using the template. Link the card (`Closes #142`). Move the card to **Review**.
7. Post the handoff note on the card (template below) and end the session.

If you run out of context or time before finishing, skip to step 7. A clear handoff matters more than more code.

## Handoff note (post as a card comment at the end of every session)

```markdown
### Handoff – <date>

**Done:** what was finished, with commit or PR links
**Not done:** what remains and why
**Decisions made:** anything chosen that is not in the spec (flag for owner)
**Next step:** the first thing the next agent should do
**Risks or questions:** blockers or surprises
```

## Definition of done

- Acceptance criteria on the card are met.
- Tests exist and pass in CI.
- Quality budgets (§7) still pass.
- UI changes follow the design system and have screenshot tests.
- Affected docs are updated (component docs only; propose spec changes, don't make them).
- A reviewer agent approved the PR, and the owner accepted it.
- The owner delegates acceptance to the planner for cards that decide nothing, change no spec text and touch no security-relevant code; those merge once the reviewer approves and CI is green.

## Roles

- **Builder:** implements one card on its own branch. The default role unless the owner says otherwise.
- **Reviewer:** checks a PR against its card, the spec and the budgets. Comments with _Approve_ or _Request changes_ and specific reasons. Never fixes the code itself and never reviews its own work.
- **Planner:** turns a roadmap phase (§8) into cards using the task template. Writes no production code.
- **Docs:** keeps component docs and the glossary in sync with merged work.

The owner states the role at the start of the session. If not stated, you are a Builder.

## Task board

The board is a GitHub Projects board with columns Backlog → Ready → In progress → Blocked → Review → Done. Only cards in **Ready** may be started. Useful commands:

```sh
gh issue view <n> --comments            # read a card and its handoff notes
gh issue comment <n> --body-file note.md # post a plan or handoff note
gh issue create --template task.md      # file a new card for out-of-scope findings
gh project item-edit ...                # move a card between columns
gh pr create --fill                     # open a PR from the current branch
```

## Repository layout (update as it is created)

```
docs/            spec.md, decisions/, per-component docs, user/ (user docs), index in README.md
components/      one directory per component, named by ID
  c1-base/  c2-compositor/  c3-shell/  c4-toolkit/  c5-apps/
  c6-search/  c7-software/  c8-settings/  c9-connectivity/
  c10-privacy/  c11-installer/
  C12 agent integration: not created yet (its first card names the directory)
tools/           budget checks, screenshot-test harness, scripts
.github/         issue and PR templates, CI workflows
```

## Commands

The root workspace holds only `tools/budgets`, `tools/tokens` and `components/c11-installer/atos-install`. C2, C3 and the C4 test harness are separate workspaces: `cargo` at the root does not touch them. The toolchain is pinned in `rust-toolchain.toml`; `rustup` installs it on first use. `cargo nextest` is not in rustup: `cargo install --locked --version 0.9.150 cargo-nextest` (CI uses the release binary pinned in `ci.yml`).

| Where | Lint and test (run in that directory) | CI workflow |
| --- | --- | --- |
| Root workspace | `cargo fmt --check && cargo clippy --all-targets -- -D warnings`, then `cargo nextest run && cargo test --doc` | `ci.yml` |
| C2 `components/c2-compositor` | `cargo build --workspace --locked`, `cargo test --workspace --locked`, `cargo clippy --workspace --all-targets --locked -- -D warnings` (system libraries in the workflow) | `c2-compositor.yml` |
| C3 `components/c3-shell` | First, from the root: `tools/slint-fork/slint-fork.sh setup`. Then `cargo fmt --check`, `cargo clippy --all-targets --config ../../third_party/slint/patch.toml -- -D warnings`, `cargo nextest run --config ../../third_party/slint/patch.toml` (no `--locked`) | `c3-shell.yml` |
| C4 harness `components/c4-toolkit/test-harness` | Same `setup`; same three commands with `--config ../../../third_party/slint/patch.toml` | `slint-fork.yml` |
| C1 `components/c1-base` | `podman build` of the Containerfile, then `check-seal.sh`, `nvidia/check.sh`; `shell-boot-test.sh` needs KVM, so it runs only in CI | `c1-base.yml` |
| C11 `components/c11-installer` | `atos-install` is in the root workspace; `build-iso.sh` and `vm-test.sh` (install and boot under KVM) run only in CI | `c11-installer.yml` |

Budgets: `cargo build --release -p budgets && target/release/budgets target/release/budget-test-app --cpu-window 10`. It needs Linux (the harness reads `/proc`); for the §7 numbers use `--cpu-window full` and the NUC (`perf.yml`). On a Mac use the dev VM: `tools/dev-vm/vm run <command>` (`docs/dev-environment.md`).

## Lanes

Every card is in one lane. The planner names it on the card.

- **Fast lane:** only `components/*/ui/**/*.slint`, `docs/design/tokens.json`, the generated `tokens.slint` and screenshot references change. One "polish" card may collect many tweaks from one sitting with the owner: one branch and one PR per sitting, and the handoff note lists what changed. The reviewer checks tokens-only values, the screenshot diffs and the accessibility tests. It merges under the planner delegation above.
- **Standard lane:** everything else, as described in this file.
- **Security lane:** permissions, sandboxing, signing, trust policy, network, the C12 broker, CI workflows, and anything under `components/c1-base/` or `components/c11-installer/` that changes what boots or what is trusted. As standard, plus Opus for builder and reviewer, and the owner always accepts.

## Conventions

- Language for system components and native apps: Rust (decision D-009, decided). Do not add another language without a decision.
- Add a third-party crate only when it is clearly trustworthy, maintained and stable, and worth its size. Justify each new dependency in the pull request (D-009).
- Use the terms in the glossary (`docs/spec.md` §11) exactly, in code, docs and cards.
- Design values come only from design tokens. No hard-coded colours, sizes, radii or animation timings.
- No telemetry, network calls home or account requirements, ever (D-005).
- Prefer existing, proven Linux components and standards (Wayland protocols, xdg portals, Flatpak) over writing new ones. If you think something new is needed, propose it.
- When unsure about an external API or library version, check its current docs instead of relying on memory.
