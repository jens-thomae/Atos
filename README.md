# Atos

A Linux-based desktop OS: Wayland compositor, shell, UI toolkit and native app suite on a signed, image-based base. Start with [`CLAUDE.md`](CLAUDE.md) and [`docs/spec.md`](docs/spec.md).

## Layout

- `components/`: one directory per component (C1–C11, spec §6).
- `tools/`: budget checks, test harnesses and scripts.
- `spikes/`: throwaway experiments (see below).
- `docs/`: spec, decisions and component docs.

## Rust workspace

The root `Cargo.toml` is a Cargo workspace (edition 2024, resolver 3). `rust-toolchain.toml` pins the toolchain, and rustup installs it on first use. Lints are set in `[workspace.lints]`; each crate opts in with `[lints] workspace = true`.

To add a crate, create it under its component directory and list its path in `members` in the root `Cargo.toml`.

Check everything from the repository root:

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

## Spikes

`spikes/` holds short experiments, such as the toolkit prototypes for D-006. It is excluded from the workspace (`exclude` in the root `Cargo.toml`), so a spike can pull in dependencies and fail to build without breaking the checks above. Each spike lives in `spikes/<name>/`, is its own Cargo project with its own `Cargo.lock`, and is built from its own directory. `cargo new spikes/<name>` still adds the spike to `members` in the root `Cargo.toml`; remove that entry before committing. Spike code never ships; anything worth keeping moves into a component through a card.
