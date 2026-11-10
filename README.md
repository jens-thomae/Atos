# Atos

A Linux-based desktop OS: Wayland compositor, shell, UI toolkit and native app suite on a signed, image-based base. Start with [`CLAUDE.md`](CLAUDE.md) and [`docs/spec.md`](docs/spec.md).

## Layout

- `components/`: one directory per component (C1–C12, spec §6).
- `tools/`: budget checks, test harnesses and scripts.
- `spikes/`: throwaway experiments (see below).
- `docs/`: spec, decisions, component and user docs; index in [`docs/README.md`](docs/README.md).

## Rust workspace

The root `Cargo.toml` is a Cargo workspace (edition 2024, resolver 3). `rust-toolchain.toml` pins the toolchain, and rustup installs it on first use. Lints are set in `[workspace.lints]`; each crate opts in with `[lints] workspace = true`.

To add a crate, create it under its component directory and list its path in `members` in the root `Cargo.toml`.

The root workspace is only part of the project: C2, C3 and the C4 test harness are separate workspaces. The exact lint and test commands for each are in the table under "Commands" in [`CLAUDE.md`](CLAUDE.md).

## Spikes

`spikes/` holds short experiments, such as the toolkit prototypes for D-006. It is excluded from the workspace (`exclude` in the root `Cargo.toml`), so a spike can pull in dependencies and fail to build without breaking the checks above. Each spike lives in `spikes/<name>/`, is its own Cargo project with its own `Cargo.lock`, and is built from its own directory. `cargo new spikes/<name>` still adds the spike to `members` in the root `Cargo.toml`; remove that entry before committing. Spike code never ships; anything worth keeping moves into a component through a card.

## Licence

Atos's own source code is licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT licence](LICENSE-MIT), at your option (D-013). Contributions are accepted under the same terms.

Shipped binaries carry the licence their dependencies require: the compositor (a cosmic-comp fork) is GPL-3.0-only, and so are binaries that link Slint (D-006). Spikes under `spikes/` keep their own licence statements.
