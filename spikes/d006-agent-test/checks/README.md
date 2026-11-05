# Acceptance-check helpers (card #13)

Run inside the dev VM (`tools/dev-vm/vm`), as the builder ran them. Paths in the scripts are the VM paths used (`~/agent-test/...`); adjust `B` and the tools directory if you move them.

| File | Purpose |
| --- | --- |
| `start-desktop.sh` | Headless sway (1920x1080, pixman) on its own session bus, as in the brief §6; writes `desktop.env` to `source` |
| `atspi-dump.py` | Role and name of every AT-SPI node (check 7). Same output the subagents had |
| `mkrun.sh` | Writes the logging `build.sh` into a run directory (compile-error and wrong-API counts come from its log) |
| `chkstart.sh <iced\|slint> <n>` | Fresh fixture copy, desktop, keyboard kept alive with `wtype -s 600000 -k Shift_L`, app started on `small` |
| `k.sh <shot> <wtype args>` | Send keys, wait, screenshot with `grim` |
| `slint-tabs.sh` | Check 2 key sequence for Slint (Ctrl via `-P Control_L`; `-M ctrl` does not reach Slint) |
| `stats.sh <run>` | Builds, errors and diff size from the run's log |

**AT-SPI precondition.** `org.a11y.Status ScreenReaderEnabled` read back as `true` in the check desktop before any app started (`busctl --user get-property org.a11y.Bus /org/a11y/bus org.a11y.Status ScreenReaderEnabled`); the builder did not set it. After the fact, setting it explicitly to `true` and restarting the libcosmic app gave the same result: `application 'd006-iced'` with an empty `frame ''`. #10's README ("Accessibility") describes the same behaviour for the unmodified prototype.

**Sequences used** (libcosmic keys use `-M ctrl`; Slint keys use `-P Control_L -P <key> -p <key> -p Control_L`):

1. Check 2: Down x3 (select), Ctrl+T, Down x2, Ctrl+Shift+Tab, Ctrl+Tab, Ctrl+W, Ctrl+W; screenshots between.
2. Dialog: Shift+F10 (context menu on the selected row), Down to *Rename…* (libcosmic: Down x3; Slint: Down x2), Return.
3. Check 3: type `notes`, Tab, type `memo`, apply (libcosmic: Return in the field; Slint: Tab x2 then Return), then `ls` of the fixture.
4. Check 4: `notes-1`, Tab, `notes-2`; screenshot. Check 5: Replace with `a/b` (libcosmic runs 2 and 3: Find `notes-1`), Return, `ls` unchanged. Check 6: Escape, `ls` unchanged.
5. Check 7: with the dialog open, `python3 atspi-dump.py`.

These sequences were typed into a shell during checking, not kept as one script; an earlier combined script (`rename-check.sh`) was dropped because its text editing was unreliable. The keystrokes above are what produced the reported results. Clicks are not covered: the headless sway seat has no pointer.
