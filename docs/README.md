# Docs index

Start with [`../CLAUDE.md`](../CLAUDE.md), then [`spec.md`](spec.md) §1–3 and §9–10. This page says what else to read for your kind of task.

## What to read for your task

| Task | Read |
| --- | --- |
| Any card | Its card and last handoff note; the spec sections it links; [decisions index](decisions/README.md) for what it touches |
| Any code | [budgets.md](budgets.md), [dev-environment.md](dev-environment.md) (Linux VM on macOS), [dev-pc.md](dev-pc.md) (build on the test PC), [ci.md](ci.md) |
| UI work | [dev-loop.md](dev-loop.md) (see it on the test PC), [design/README.md](design/README.md), the toolkit docs in `components/c4-toolkit/`, esp. [screenshot-tests.md](components/c4-toolkit/screenshot-tests.md) and [widgets.md](components/c4-toolkit/widgets.md) |
| Compositor (C2) | [components/c2-compositor/](components/c2-compositor/README.md), then its [code map](components/c2-compositor/code-map.md) |
| Shell (C3) | `components/c3-shell/README.md`, then the C4 docs |
| Base image, boot, trust (C1) | [components/c1-base/README.md](components/c1-base/README.md) |
| Installer (C11) | [components/c11-installer/README.md](components/c11-installer/README.md) |
| CI or the NUC | [ci.md](ci.md), [reference-runner.md](reference-runner.md) |
| Planning or board work | [planner.md](planner.md) |
| User-visible behaviour | [user/README.md](user/README.md) |

Components without a doc folder yet (C5–C10, C12) have only their spec §6 section.

## Every document under `docs/`

- [spec.md](spec.md): the specification; the owner changes it.
- [planner.md](planner.md): the planner's standing rules and lessons.
- [budgets.md](budgets.md): the budget harness and how to run it.
- [ci.md](ci.md): CI workflows and hosted minutes.
- [dev-environment.md](dev-environment.md): the Linux dev VM on macOS.
- [dev-pc.md](dev-pc.md): build and test on the owner's test PC (`tools/dev-pc/pc`).
- [dev-loop.md](dev-loop.md): a shell change on the owner's test PC in under a minute (`tools/dev-push`).
- [reference-runner.md](reference-runner.md): the NUC runner and its setup.
- [design/](design/README.md): design tokens (`tokens.json`).
- [decisions/](decisions/README.md): decision write-ups; the index lists D-001 to D-017.
- [user/](user/README.md): documentation for users of Atos.
- `components/c1-base/`: [README](components/c1-base/README.md) (image), [base-mirror](components/c1-base/base-mirror.md), [boot-counting](components/c1-base/boot-counting.md), [developer-mode](components/c1-base/developer-mode.md), [trust-policy](components/c1-base/trust-policy.md), [module-trust](components/c1-base/module-trust.md), [nvidia](components/c1-base/nvidia.md); spikes: [dev-image](components/c1-base/dev-image-spike.md), [ipe-modules](components/c1-base/ipe-modules.md), [shim-mok](components/c1-base/shim-mok-spike.md), [uefi-ca-2023](components/c1-base/uefi-ca-2023.md), [usr-overlay](components/c1-base/usr-overlay-spike.md).
- `components/c11-installer/`: [README](components/c11-installer/README.md).
- `components/c2-compositor/`: [README](components/c2-compositor/README.md), [code-map](components/c2-compositor/code-map.md), [upstream](components/c2-compositor/upstream.md).
- `components/c4-toolkit/`: [README](components/c4-toolkit/README.md) (Slint fork), [rebase](components/c4-toolkit/rebase.md), [widgets](components/c4-toolkit/widgets.md) (shared widgets), [screenshot-tests](components/c4-toolkit/screenshot-tests.md), accessibility: [a8-tree-on](components/c4-toolkit/a8-tree-on.md), [popups-and-dialogs](components/c4-toolkit/popups-and-dialogs.md), [semantic-actions](components/c4-toolkit/semantic-actions.md), [stable-ids](components/c4-toolkit/stable-ids.md); spike: [layer-shell](components/c4-toolkit/layer-shell-spike.md).
