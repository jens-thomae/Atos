# tools

Developer tooling: budget checks (spec §7), the screenshot-test harness and scripts. Nothing here ships in the image.

- `budgets/`: the budget harness and its test app; see [`docs/budgets.md`](../docs/budgets.md).
- `tokens/`: design tokens to Slint globals (`cargo run -p tokens`); see [`docs/design/README.md`](../docs/design/README.md).
- `dev-push/`: push a shell build to the owner's test PC and take a screenshot of it; see [`docs/dev-loop.md`](../docs/dev-loop.md).
