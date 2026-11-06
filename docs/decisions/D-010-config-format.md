# D-010: Configuration format (TOML or KDL)

Status: **Proposed** (the owner decides; see `docs/spec.md` §5).
Card: #2 · Facts checked: 2026-11-06 · Spike: `spikes/d010-config/`

## Context

C8 requires that every setting is stored in a readable config file and that "Settings and the file never disagree" (spec §6 C8). Users also edit the file by hand (design principle "Owned and customisable", §2 priority 5). Both only work together if Settings can change one value and leave everything else the user wrote untouched: comments, ordering, spacing. So the deciding criterion is **format-preserving round-trip editing in Rust** (D-009), then readability, then crate maturity.

This write-up compares TOML and KDL and does not define the real schema (out of scope). Other formats are excluded in one sentence each: JSON has no comments; YAML's indentation and implicit typing make hand edits error-prone and the Rust ecosystem is weak; RON is Rust-syntax-specific, unfamiliar to ordinary users and has no mature format-preserving editor.

## Options

### The same sample in both formats

The sample has one shell preset, a keybinding list, one workspace with a window mode and one theme token override. The files are in the spike ([sample.toml](../../spikes/d010-config/sample.toml), [sample.kdl](../../spikes/d010-config/sample.kdl)); the keys are invented for the spike.

TOML:

```toml
[shell]
preset = "classic"      # classic | minimal | tablet
dock_position = "bottom"

[[keybinding]]
keys = "Super+Return"
action = "open-terminal"

[[keybinding]]
keys = "Super+Space"   # palette
action = "palette"

[[workspace]]
name = "Work"
window_mode = "tiling"   # tiling | floating

[theme.tokens]
"color.accent" = "#3584e4"
```

KDL:

```kdl
shell {
    preset "classic"      // classic | minimal | tablet
    dock-position "bottom"
}

keybindings {
    bind "Super+Return" action="open-terminal"
    bind "Super+Space" action="palette"   // palette
}

workspace "Work" {
    window-mode "tiling"   // tiling | floating
}

theme {
    token "color.accent" "#3584e4"
}
```

(Both abbreviated here; the spike files contain a third keybinding and header comments.)

### Readability

| | TOML 1.x | KDL 2.0 |
| --- | --- | --- |
| Flat key/value settings | Very clear: `key = value`, typed values | Clear, but `preset "classic"` has no separator and a reader must know that the first argument is the value |
| Lists of records (keybindings, workspaces) | `[[keybinding]]` repeats a header and a line per field; long for many items | One line per item: `bind "Super+Q" action="close-window"`. Noticeably shorter and easier to scan |
| Nesting | Headers (`[theme.tokens]`) or dotted keys; deep trees get verbose | Braces; nesting reads naturally |
| Keys with dots (`color.accent`) | Must be quoted, otherwise it means nesting | Node arguments, so no escaping issue |
| Comments | `#` | `//`, `/* */` and `/-` to comment out a whole node, handy for trying a setting |
| Familiarity | Known from `Cargo.toml`, `pyproject.toml`; most users have seen it | Rare; users meet it in niri and Zellij |
| Typing | Ints, floats, bools, dates, arrays, tables | Ints, floats, bools, strings, null, optional type annotations; no native arrays or maps (use repeated nodes or properties) |

Judgement: TOML is the clearer format for plain settings; KDL is clearer for lists of records such as keybindings. The sample is half of each, so this does not settle the choice.

### Rust crate maturity (checked on crates.io and in the repositories, 2026-11-06)

| | TOML | KDL |
| --- | --- | --- |
| Format-preserving editor | [toml_edit] 0.25.18 (2026-11-04), MSRV 1.85, MIT OR Apache-2.0, about 1.0 billion downloads [1] | [kdl] 6.7.1 (2026-05-31), MSRV 1.95, Apache-2.0 only, about 3 million downloads [2] |
| Typed read (serde) | [toml] 1.2.0 (2026-11-04), same repository [1] | `kdl` serde support landed in 6.6.0 (2026-05-29) and its changelog calls it experimental [2]; [knus] 3.4.1 (2026-11-02, derive-based decoding, a fork of [knuffel]) [3]; knuffel itself last released 3.2.0 in April 2023 [4] |
| Spec version | TOML 1.1 (`+spec-1.1.0` in the version) | `kdl` implements KDL v2.0.0 and v1.0.0 behind a feature [2] |
| Maintenance | One repository (toml-rs/toml), last push 2026-11-04, releases roughly monthly, used by Cargo | kdl-org/kdl-rs, last push 2026-10-15, active but small team; knus is a separate small project with no repository link on crates.io |
| Who relies on it | Cargo and most of the Rust ecosystem | niri uses knuffel 3.2.0 [5]; see below for what that means |

Points that matter for us:

- `kdl` is Apache-2.0 only. Linking it into our MIT OR Apache-2.0 code (D-013) is permitted, but the shipped binary is then effectively under Apache-2.0 terms. Worth the owner knowing; not a blocker.
- `kdl`'s MSRV 1.95 is within our pinned 1.99.1.
- The KDL stack splits in two: `kdl` preserves formatting but has only experimental serde; the typed decoders (knuffel, knus) parse into structs and cannot write back. We would likely carry glue between them ourselves. For TOML the same split exists (`toml` for typed reads, `toml_edit` for edits) but both are one mature repository.
- We do not contribute upstream (owner policy). If a bug blocks us we carry a fork. A format with one small maintained editor crate is a higher fork risk than one with a large maintained one.

### Format-preserving round-trip editing (spike results)

The spike (`spikes/d010-config/`, `cargo run`) parses each sample, changes **one value** (the first workspace's window mode, `tiling` → `floating`), serialises, and asserts that exactly one line differs and the line count is unchanged. Both crates were pulled at the versions above. Results:

```
toml_edit: -window_mode = "tiling"   # tiling | floating
toml_edit: +window_mode = "floating"   # tiling | floating
toml_edit: OK, exactly one line changed

kdl: -    window-mode "tiling"   // tiling | floating
kdl: +    window-mode floating   // tiling | floating
kdl: OK, exactly one line changed
```

Both formats pass the criterion: comments, ordering, blank lines and column alignment were kept, and only the edited line changed. Details that matter:

- **toml_edit** needs one step beyond the obvious: replacing the value drops its decor (the trailing comment), so the spike copies the decor to the new value. With that, the comment stays.
- **kdl**: calling `set_value` on an entry alone changed **zero lines** in the output, because the entry keeps the original text in its format and prints that. Calling `autoformat()` on the edited entry re-renders it. KDL v2 then writes the string as a bare word (`floating`, valid in v2) instead of `"floating"`, a style change on that line. Keeping quotes needs a hand-built entry format. This is a pitfall, not a blocker, and a C8 wrapper could hide it.
- The spike covers one in-place value edit only. It does **not** test inserting or removing nodes/items, reordering, or edits on files with unusual layout; those are the cases most likely to reveal differences and are listed under Open questions.
- Both crates expose a document tree you edit in place, not a serde round trip. Settings would therefore need a small layer that maps typed settings to "set this path in the document" for either format.

## Recommendation

**Decide D-010 as TOML**, with `toml_edit` for writing and `toml` for typed reads.

Why:

1. Both formats pass the round-trip test, so the deciding factors are maturity and risk. `toml_edit`/`toml` are one very widely used, frequently released, same-repository pair; KDL's editor crate is much smaller, has only experimental serde, and its typed decoders are a separate and partly stale ecosystem.
2. Our no-upstream policy makes the maintained-crate gap matter more: a bug we hit in `kdl` is more likely to mean a carried fork.
3. TOML is more familiar, and keys, values and typing are plainer for the many flat settings. The weaker spot, lists of records, is acceptable (verbose but unambiguous), and keybindings could use inline tables or arrays if length becomes a problem.
4. License: `toml_edit` is MIT OR Apache-2.0, matching D-013.

When KDL would be the better call: if the config is mostly lists of records and nested trees (keybindings, window rules, layouts), where KDL's one-line-per-item form is clearly nicer, and the owner accepts the smaller ecosystem. niri's config is such a case.

This is a recommendation only; the owner decides.

## Consequences

If TOML is decided:

- C8 depends on `toml_edit` and `toml`; each needs a one-line justification in the PR that adds it (D-009 rule). Both are already in many dependency trees.
- Settings writes through `toml_edit::DocumentMut`, never by re-serialising typed structs, so user comments and ordering survive. A round-trip test (like the spike's) belongs in C8's test suite and in CI.
- The schema, versioning and the "file changed on disk while Settings is open" behaviour are still to be designed in C8 cards.
- Keybinding lists use `[[array of tables]]` or inline tables; the real schema should be chosen with length in mind.
- Keys containing dots (design tokens such as `color.accent`) need quoting; the token naming scheme should avoid dots in keys or accept the quoting.

If KDL is decided instead:

- C8 depends on `kdl` (Apache-2.0 only, MSRV 1.95) for read and write, plus either its experimental serde support or our own mapping layer; a typed decoder such as knus would be read-only.
- The editing pitfall above (`set_value` does nothing on its own; `autoformat` changes string quoting) must be wrapped once and covered by tests.
- Settings, the `os` tool (§6 C7) and extensions all depend on the thinner ecosystem.

## Open questions

1. Is `kdl`'s Apache-2.0-only license acceptable under D-013 if KDL is chosen?
2. Do we need a follow-up spike for structural edits (insert, remove, reorder items, add a missing section) before C8 is built? The spike tests only one in-place value change.
3. Should the config be split into several files (for example one per component) or one file? Affects both formats equally and is a C8 design question.
4. How should Settings react if a user edits the file by hand while Settings is open (watch and reload, or lock)? Not decided by the format.

## References

[1]: https://crates.io/crates/toml_edit (also https://crates.io/crates/toml) and https://github.com/toml-rs/toml
[2]: https://crates.io/crates/kdl, https://github.com/kdl-org/kdl-rs and its CHANGELOG.md
[3]: https://crates.io/crates/knus
[4]: https://crates.io/crates/knuffel and https://github.com/tailhook/knuffel (last push 2024-02-08)
[5]: https://github.com/YaLTeR/niri, `niri-config/Cargo.toml`
[toml_edit]: https://crates.io/crates/toml_edit
[toml]: https://crates.io/crates/toml
[kdl]: https://crates.io/crates/kdl
[knus]: https://crates.io/crates/knus
[knuffel]: https://crates.io/crates/knuffel
