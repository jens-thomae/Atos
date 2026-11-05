# D-006: agent extensibility test (M8)

Card: #13 · Run: 2026-11-05 · Method: [`D-006-prototype-brief.md` §8](D-006-prototype-brief.md#8-agent-extensibility-test), run as written except for the deviations in [section 6](#6-deviations-and-limits-of-this-test). This document reports results. It makes no recommendation; that is #14.

## 1. Result

| | libcosmic (git rev `daca62b`) | Slint 1.18.1 |
| --- | --- | --- |
| Runs completed (all 7 checks) | **0 of 3** | **3 of 3** |
| Checks passed per run | 6, 6, 6 of 7 (check 7 failed in each) | 7, 7, 7 of 7 |
| Wall time per run (median) | 6 m 54 s, 6 m 55 s, 5 m 56 s (**6 m 54 s**) | 8 m 55 s, 4 m 48 s, 6 m 31 s (**6 m 31 s**) |
| Compile-error iterations per run | 0, 1, 1 | 3, 2, 2 |
| Wrong-API attempts per run | 0, 1, 0 | 1, 1, 1 |
| Diff size per run (lines added / removed) | +243/−4, +467/−4, +419/−3 | +294/−1, +298/−1, +289/−1 |
| Web pages fetched (agent's own report) | 0, 0, 0 | 1, 0, 0 |
| `llms.txt` | None found | Exists, but only a site index (see [section 5](#5-agent-ready-docs-brief-6-c4)) |
| Markdown API docs | None found | None found; docs sources are Markdown (MDX) files in the repository |

Every number in the table comes from [section 4](#4-per-run-results). Runs alternated libcosmic, Slint, libcosmic, Slint, libcosmic, Slint.

What the failed check was. In all three libcosmic runs, both features worked and checks 1 to 6 passed. Check 7 (the new controls appear in the AT-SPI tree with names equal to their labels) failed because the AT-SPI tree of the libcosmic app is empty (`frame ''` with no children), before and after the change. This was already recorded for the unmodified prototype in #10's README. Run 2 and run 3 set accessible names in code (button `.name()`, a wrapper widget, see [section 4](#4-per-run-results)); the names cannot be observed through AT-SPI at this revision. All three agents reached the same diagnosis independently: the iced winit layer creates the AT-SPI adapter but never publishes the widget tree, and libcosmic's `text_input` and `segmented_button` have no accessibility nodes. None of them could fix that from application code.

## 2. Setup actually used

- **Model.** Every run used the Agent tool's `sonnet` alias, the same as this session's builder model, Claude Sonnet 5.5 (model ID `claude-sonnet-5-5`). The harness does not echo the resolved ID back for subagents, so the ID is the alias's documented target, not read from a log. Default settings; no extra instructions.
- **Isolation.** One fresh subagent per run, no conversation history. Each run had its own copy of the prototype (no git history, no `README.md`, no screenshot, no `target/`) at `~/agent-test/<name><n>/app` on the dev VM's own disk, and a fixture made with `spikes/d006-fixture/make-fixture.sh` at `~/agent-test/<name><n>/fixture`. `cargo fetch` was run in each copy first, and the build command was `cargo build --release --offline` with `CARGO_NET_OFFLINE=true`.
- **Build.** A wrapper script (`build.sh`, same for every run) ran the build and appended every cargo invocation and its output to a log (committed in [`spikes/d006-agent-test/logs/`](../../spikes/d006-agent-test/logs/)). The wrapper used a per-toolkit target directory shared by the three runs of that toolkit and pre-warmed by one build of the unmodified prototype (3 m 14 s for libcosmic, 2 m 28 s for Slint). So every run built the dependencies once, not three times, and wall times exclude dependency compilation.
- **Prompt.** The brief's prompt, filled in with the placeholders below, identical for both toolkits, plus an identical block of environment notes (see [section 6](#6-deviations-and-limits-of-this-test)).
- **Allowed web sources** (`{DOCS_URLS}`):
  - libcosmic: <https://pop-os.github.io/libcosmic/cosmic/> (API docs), <https://github.com/pop-os/libcosmic> (source and examples at the pinned revision), <https://github.com/pop-os/iced> (the iced fork libcosmic bundles).
  - Slint: <https://docs.slint.dev/latest/docs/slint/>, <https://docs.rs/slint/1.18.1/slint/>, <https://github.com/slint-ui/slint> (tag `v1.18.1`), <https://slint.dev/llms.txt>.
- **Tools given.** The dev VM from #16 with sway headless (pixman, 1920 × 1080 as in the brief), `grim`, `wtype`, an AT-SPI dump script printing role and name, started with `start-desktop.sh` in the notes.
- **Acceptance checks** were run by me, not by the subagent, on a new fixture copy, keyboard-driven with `wtype`, screenshots from `grim`, disk state from `ls`, and the AT-SPI dump. The 90-minute limit was never approached (longest run 8 m 55 s).

## 3. Acceptance checks

| # | Check (brief §8) | libcosmic 1 | libcosmic 2 | libcosmic 3 | Slint 1 | Slint 2 | Slint 3 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Release build succeeds, original features intact | ✓ ¹ | ✓ ¹ | ✓ ¹ | ✓ ¹ | ✓ ¹ | ✓ ¹ |
| 2 | Tab keys and clicks; per-tab folder and selection; last tab stays | ✓ ² | ✓ ² | ✓ ² | ✓ ² | ✓ ² | ✓ ² |
| 3 | Find `notes`, replace `memo`: preview, then exactly the three renames | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 4 | `notes-1` → `notes-2` disables Rename and names the conflict | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 5 | `notes` → `a/b` disables Rename | ✓ | ✓ ³ | ✓ ³ | ✓ | ✓ | ✓ |
| 6 | Cancel and Escape change nothing on disk | ✓ ⁴ | ✓ ⁴ | ✓ ⁴ | ✓ ⁴ | ✓ ⁴ | ✓ ⁴ |
| 7 | `Tabs`, each tab, dialog, both fields, both buttons in the AT-SPI tree with names equal to labels | ✗ empty tree | ✗ empty tree | ✗ empty tree | ✓ | ✓ | ✓ |
| | **Checks passed** | **6** | **6** | **6** | **7** | **7** | **7** |

1. Release build passes. Brief check 1 also asks that the original features still pass M7 steps 1 to 11. I did not re-run the M7 walkthrough (that is #12's script); I only saw list navigation, the context menu and Properties still working while testing the new features.
2. Keyboard parts checked by me: Ctrl+T, Ctrl+W (twice, second does nothing), Ctrl+Tab, Ctrl+Shift+Tab, per-tab selection, per-tab folder in Slint run 1 and the libcosmic runs' first tab. **Clicking a tab was not tested by me in any run**: the headless sway seat has no pointer device and the dev VM has no virtual-pointer tool (the same limit #11 recorded). The subagent of libcosmic run 3 reported testing a tab click; I could not reproduce that. Counting check 2 as passed means keyboard behaviour passed and click behaviour is unverified.
3. For libcosmic runs 2 and 3 I tested the `/` case with Find `notes-1` and Replace with `a/b` (the dialog showed the invalid-name conflict and disabled Rename), not Find `notes`; the validation path is the same.
4. Escape was tested, not the Cancel button by pointer. Cancel was not clicked in any run (no pointer), so the Cancel button itself is unverified.

In Slint the dialog's Rename button is reached with Tab, Tab, then Return/Space; in libcosmic runs 2 and 3 the agent added Enter in a field to apply the rename (an unrequested addition). The brief does not require keyboard operation of the new buttons.

## 4. Per-run results

All times are from sending the prompt to the DONE report, measured by me. Compile-error iterations count builds and `cargo check` runs that ended with at least one compiler error; for Slint, the Slint compiler runs inside `build.rs`, so a Slint-language error shows as `failed to run custom build command` and counts as one iteration too. Wrong-API attempts are my classification of the errors in the logs: an error caused by a toolkit item that does not exist or is used with the wrong rules, counted once per distinct attempt. The classification is a judgement; the logs are committed.

| Run | Completed | Checks | Wall time | Builds (failed) | Compile-error iterations | Wrong-API attempts | Diff +/− (all files) | Web pages (self-reported) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| libcosmic 1 | No | 6/7 | 6 m 54 s | 3 (0) | 0 | 0 | +243/−4 (`src/main.rs`) | none |
| Slint 1 | Yes | 7/7 | 8 m 55 s | 9 (3) | 3 | 1 | +294/−1 | 1 (`docs.slint.dev/latest/docs/slint/reference/common/`) |
| libcosmic 2 | No | 6/7 | 6 m 55 s | 5 (1) | 1 | 1 | +467/−4 (incl. new `src/named.rs`, 224 lines) | none |
| Slint 2 | Yes | 7/7 | 4 m 48 s | 6 (2) | 2 | 1 | +298/−1 | none |
| libcosmic 3 | No | 6/7 | 5 m 56 s | 7 (1) | 1 | 0 | +419/−3 (incl. new `src/labeled.rs`, 173 lines) | none |
| Slint 3 | Yes | 7/7 | 6 m 31 s | 7 (2) | 2 | 1 | +289/−1 | none |

Subagent token use and tool calls (from the harness): libcosmic 120k/42, 136k/45, 130k/48; Slint 144k/55, 103k/28, 113k/35.

Transcript summaries (from the subagents' final reports and the build logs; the subagent transcripts themselves are not committed):

- **libcosmic 1.** `tab_bar::horizontal` over a `SingleSelectModel` for the tabs, keyboard shortcuts in the existing key handler, a hand-built overlay dialog for batch rename. Three builds (`check`, release, release), all clean. Reported DONE and stated up front that the accessible-name requirement was not met: the tree is empty even for existing controls. Read libcosmic and iced sources from the local cargo checkout; fetched no web page.
- **libcosmic 2.** Tabs as a row of named buttons. First release build failed: `E0599 no method named iter found for &cosmic::iced::widget::list::Content<Entry>` (wrong-API) and `E0515` (own borrow error). Wrote a 224-line wrapper widget (`src/named.rs`) that gives a child its own AT-SPI node with a role and name, used for the "Tabs" bar and the two text fields, and added `iced_accessibility` (same git source and revision as libcosmic, already in `Cargo.lock`) as a direct dependency to name the accesskit types. Names are not visible in AT-SPI. Fetched no web page.
- **libcosmic 3.** Same approach as run 2 (173-line `src/labeled.rs` wrapper, same added dependency, flagged by the agent as arguable under "do not add crates"). One failed build (a syntax error and `E0369` on `&str / &str`, neither toolkit API). The agent identified the root cause precisely: the AT-SPI adapter is created per window but never receives tree updates. Fetched no web page.
- **Slint 1.** Tab bar from `Rectangle`/`TouchArea` with `accessible-role: tab-list` and `tab`; Rust-side `Vec` of tabs. Three failed builds: Slint compiler "Use parentheses to disambiguate between && and ||" (language rule), "Cannot convert TabInfo to AccessibleRole" (the agent's own struct named `TabInfo` shadowing the `tab` role; counted as one wrong-API attempt), and three `E0593` closure-arity errors in the agent's own helper. Used `PopupWindow` for the dialog like the existing Properties dialog. Reported that `wtype -M ctrl` does not deliver the Ctrl modifier to Slint apps and used explicit `-P Control_L` key presses (this is already in #11's notes). Fetched one docs page.
- **Slint 2.** Two failed builds: Slint compiler "Unknown property accessible-selectable in Rectangle" (wrong-API) and `E0502` (own borrow). Fetched no web page, read nothing else on the web. Its report names `tools/slint-tabs.sh` as the source of the `wtype -P Control_L` form; that script was my own acceptance-check helper, left visible in the shared tools directory (see [section 6](#6-deviations-and-limits-of-this-test)).
- **Slint 3.** Two failed builds: Slint compiler "Cannot access property or callback find-input.text inside of a PopupWindow from enclosing component" (language rule about `PopupWindow` scope; counted as wrong-API) and `E0502` (own borrow). Found the cause of the `wtype` modifier problem by reading Slint source in the local cargo registry. Fetched no web page.

## 5. Agent-ready docs (brief §6 C4)

Checked on 2026-11-05.

| | libcosmic | Slint |
| --- | --- | --- |
| `llms.txt` | None. `https://pop-os.github.io/libcosmic/llms.txt` returns 404, and the repository root at the pinned revision has no such file | `https://slint.dev/llms.txt` exists (2.5 KB). It is a site index: the project summary, links to the docs site, GitHub, pages, comparisons and blog posts. It has no API content. `https://docs.slint.dev/llms.txt` and `https://slint.dev/llms-full.txt` return 404 |
| Markdown API docs | None. API docs are generated rustdoc HTML at `pop-os.github.io/libcosmic/cosmic/`. The repository has a README, examples and source comments | No Markdown export of the API docs. The documentation sources are MDX files in the repository (one path checked, `docs/astro/src/content/docs/guide/language/concepts/slint-language.mdx` at `v1.18.1`, HTTP 200); the published site is HTML, and Rust API docs are on docs.rs |
| Other | | A Slint blog post titled "Getting Good Vibes from Slint" (<https://slint.dev/blog/slint-and-AI-MCP.html>) is linked from `llms.txt` and suggests an MCP server for agents. It was not read in detail and was not used in any run |

Not checked: whether `llms.txt` was consulted by any run. The self-reports list one fetched page in total (Slint run 1, a docs reference page), and none of the runs fetched `llms.txt`.

## 6. Deviations and limits of this test

Read these before using any number above.

1. **Isolation is by instruction, not enforcement.** A subagent runs as the same user on the same machine. It could read other directories on the VM and on the host; it was told to work only in its own directory and to use only the listed web sources. Nothing technical stopped it. The web restriction cannot be verified except through the agent's own list of fetched pages.
2. **Agents mostly did not use the web at all.** Five of six runs report no web fetch; they read the toolkit sources in `~/.cargo` (the cargo registry or git checkouts) inside the VM. The brief did not forbid that, and it is the same for both candidates, but it means "docs the agent used" here is mostly source code, not the websites in `{DOCS_URLS}`. The per-run "Doc lookups grouped by source" field of the brief is therefore reported as the self-reported fetch list only.
3. **Prompt additions.** Both prompts got the same two additions to the brief's text: an environment block (how to run VM commands, start the headless desktop, take screenshots, send keys, dump AT-SPI; the build wrapper that logs) and a request to list the web pages fetched in the final reply. The example key command in the block used `wtype -M ctrl …`, which does not deliver Ctrl to Slint apps; the Slint agents had to discover the workaround. The libcosmic agents did not hit that.
4. **Contamination of runs libcosmic 2 and Slint 2.** My acceptance-check scripts (`k.sh`, `slint-tabs.sh`, `rename-check.sh`, `chkstart.sh`) and logs of earlier runs sat in the VM's shared tools and test directories while libcosmic 2 and Slint 2 were running. Slint 2's report explicitly names `tools/slint-tabs.sh` as the source of its working `wtype` form. I moved them out of the agents' reach before libcosmic 3 and Slint 3. libcosmic 1 and Slint 1 ran before the scripts existed. The leaked material is test tooling, not solution code, but libcosmic 2 and Slint 2 are not fully clean. The wall time of Slint 2 (4 m 48 s, the fastest run) may be affected.
5. **Shared warm target directory.** The three runs of one toolkit shared a target directory pre-warmed by a build of the unmodified prototype, so dependency compilation (3 m 14 s libcosmic, 2 m 28 s Slint) is excluded from every wall time. Per-run builds were incremental builds of the app crate only: about 20 to 120 s for libcosmic and 5 to 130 s for Slint.
6. **Same-model runs on one machine.** The VM has 4 vCPUs, and no other build ran in it during a run. Wall time includes the model's thinking time and every tool call; it is not a measure of build time.
7. **Click behaviour and M7 1 to 11 were not verified** by me (see notes 1 and 2 of [section 3](#3-acceptance-checks)).
8. **Classification of errors is mine.** "Wrong-API attempt" for Slint covers Slint-language errors from `build.rs` (an unknown property, a name clash with a built-in role, a `PopupWindow` scoping rule), because the brief's examples are rustc error codes and Slint reports its own. If those are excluded, Slint's wrong-API count is 0, 0, 0 and its compile-error iterations still include them.
9. **Three runs per candidate** is a small sample; every Slint run differs in size and every libcosmic run fails the same check.
10. **Model ID.** See [section 2](#2-setup-actually-used).

## 7. Where the code is

The extended source (everything the agents changed or added, plus `Cargo.toml` and `Cargo.lock`, no build output) is on this PR branch only and is not merged into the prototypes:

| Run | Directory | Build log |
| --- | --- | --- |
| libcosmic 1 | [`spikes/d006-agent-test/libcosmic-run1/`](../../spikes/d006-agent-test/libcosmic-run1) | [log](../../spikes/d006-agent-test/logs/libcosmic-run1.build.log) |
| libcosmic 2 | [`spikes/d006-agent-test/libcosmic-run2/`](../../spikes/d006-agent-test/libcosmic-run2) | [log](../../spikes/d006-agent-test/logs/libcosmic-run2.build.log) |
| libcosmic 3 | [`spikes/d006-agent-test/libcosmic-run3/`](../../spikes/d006-agent-test/libcosmic-run3) | [log](../../spikes/d006-agent-test/logs/libcosmic-run3.build.log) |
| Slint 1 | [`spikes/d006-agent-test/slint-run1/`](../../spikes/d006-agent-test/slint-run1) | [log](../../spikes/d006-agent-test/logs/slint-run1.build.log) |
| Slint 2 | [`spikes/d006-agent-test/slint-run2/`](../../spikes/d006-agent-test/slint-run2) | [log](../../spikes/d006-agent-test/logs/slint-run2.build.log) |
| Slint 3 | [`spikes/d006-agent-test/slint-run3/`](../../spikes/d006-agent-test/slint-run3) | [log](../../spikes/d006-agent-test/logs/slint-run3.build.log) |

Each log line starting with `=== <time> cargo …` marks one build; the time stamps give the timeline of builds within a run.
