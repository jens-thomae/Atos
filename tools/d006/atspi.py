#!/usr/bin/env python3
"""M6 (accessibility tree) and M7 (keyboard walkthrough) of the D-006 brief §7.
Needs a running Wayland compositor with virtual-keyboard support (sway), the AT-SPI bus switched on,
`wtype`, `wl-paste` and `grim` on PATH.
Usage: atspi.py m6|m7 <name> <binary> <fixture> <out-dir>"""
import json, os, subprocess, sys, time
import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

mode, name, binary, fx, out = sys.argv[1:6]
small, big = f"{fx}/small", f"{fx}/10k"
sdir = os.path.join(out, name)
os.makedirs(sdir, exist_ok=True)


# --- app and tree -------------------------------------------------------------
class App:
    def __init__(self, folder):
        self.path = f"{sdir}/stdout-{mode}.txt"
        self.proc = subprocess.Popen([binary, folder], stdout=open(self.path, "ab"), stderr=subprocess.DEVNULL)
        for _ in range(100):  # first frame
            time.sleep(0.1)
            if b"BUDGET_FIRST_FRAME" in open(self.path, "rb").read():
                break
        time.sleep(1.5)  # AT-SPI registration and initial focus settle
        self.out_pos = len(open(self.path, "rb").read())

    def stop(self):
        self.proc.kill()
        self.proc.wait()

    def stdout_since_start(self):
        return open(self.path, "rb").read()[self.out_pos:].decode(errors="replace")

    def root(self):
        desk = Atspi.get_desktop(0)
        for i in range(desk.get_child_count()):
            a = desk.get_child_at_index(i)
            if (a.get_name() or "").startswith("d006"):
                return a
        return None

    def nodes(self):
        """Flat list of (depth, role, name, states) of the application's tree."""
        res = []

        def walk(n, d):
            try:
                res.append((d, n.get_role_name(), n.get_name() or "",
                            sorted(s.value_nick for s in n.get_state_set().get_states())))
                for i in range(n.get_child_count()):
                    walk(n.get_child_at_index(i), d + 1)
            except Exception as e:  # node vanished while walking
                res.append((d, "?", f"<error {e}>", []))

        r = self.root()
        if r is not None:
            walk(r, 0)
        return res

    def details(self):
        """Role, name, AccessibleId (A7) and action names (A4) of every node, as text. Evidence only, not checked."""
        lines = []

        def walk(n, d):
            try:
                aid = n.get_accessible_id() or ""
                act = n.get_action_iface()
                acts = [act.get_action_name(i) for i in range(act.get_n_actions())] if act else []
                lines.append(f"{'  ' * d}{n.get_role_name()} {n.get_name() or ''!r} id={aid!r} actions={acts}\n")
                for i in range(n.get_child_count()):
                    walk(n.get_child_at_index(i), d + 1)
            except Exception as e:  # node vanished while walking
                lines.append(f"{'  ' * d}? <error {e}>\n")

        r = self.root()
        if r is not None:
            walk(r, 0)
        return "".join(lines) or "(application not on the AT-SPI bus)\n"


def dump_text(nodes):
    if not nodes:
        return "(application not on the AT-SPI bus)\n"
    return "".join(f"{'  ' * d}{r} {n!r} {s}\n" for d, r, n, s in nodes)


def focused(nodes):
    return [(r, n) for _, r, n, s in nodes if "focused" in s]


def has(nodes, name, roles=None):
    """None when the application exposes (almost) no tree at all: nothing to check."""
    if len(nodes) <= 3:
        return None
    return any(n == name and (roles is None or r in roles) for _, r, n, _ in nodes)


# --- input -----------------------------------------------------------------------
keepalive = None


def keep_keyboard():
    """Each wtype call creates and removes a virtual keyboard; while another one lives, the window keeps focus."""
    global keepalive
    keepalive = subprocess.Popen(["wtype", "-s", "3600000", "-k", "Shift_L"])
    time.sleep(0.5)


def key(*keys, mods=(), wait=0.5):
    """Press keys with modifiers held. Both ways at once: libcosmic reads the modifier state the compositor
    tracks (wtype -M), Slint derives it from the Shift/Alt key events (wtype -P, and it ignores -M)."""
    cmd = ["wtype", "-s", "500"]  # the first key after a wtype start is lost without a delay (iced README)
    for m in mods:
        cmd += ["-M", m.split("_")[0].lower(), "-P", m]
    for k in keys:
        cmd += ["-k", k]
    for m in reversed(mods):
        cmd += ["-p", m, "-m", m.split("_")[0].lower()]
    subprocess.run(cmd, check=True)
    time.sleep(wait)


def shot(label):
    subprocess.run(["grim", "-s", "0.75", f"{sdir}/{label}.png"], check=False)


def clipboard():
    r = subprocess.run(["wl-paste", "--no-newline"], capture_output=True, timeout=5)
    return r.stdout.decode(errors="replace")


# --- M6 ---------------------------------------------------------------------------------
def m6():
    app = App(small)
    keep_keyboard()
    key("Down")  # select the first row, so the context menu has a target
    initial = app.nodes()
    open(f"{sdir}/m6-details-initial.txt", "w").write(app.details())
    shot("m6-initial")
    key("Menu", wait=0.8)
    menu = app.nodes()
    open(f"{sdir}/m6-details-menu.txt", "w").write(app.details())
    shot("m6-menu")
    key("Escape")
    key("Menu", wait=0.5)
    key("Down", "Down", "Return", wait=1.0)  # Properties
    dialog = app.nodes()
    open(f"{sdir}/m6-details-dialog.txt", "w").write(app.details())
    shot("m6-dialog")
    key("Escape")
    app.stop()
    for label, nodes in (("initial", initial), ("menu", menu), ("dialog", dialog)):
        open(f"{sdir}/m6-tree-{label}.txt", "w").write(dump_text(nodes))

    W, L, LI, PB, LAB = {"frame", "window"}, {"list", "list box"}, {"list item"}, {"push button"}, {"label"}
    TBL = {"table", "list", "list box"}
    entries = ["docs", "empty", "notes-1.txt", "notes-2.txt", "notes-3.txt", "photo.png", "report.pdf", "with space.md", "Ünïcödé.txt"]
    spec = [  # (control, expected role text, role set, name or None, tree)
        ("Window", "frame or window", W, "Files", initial),
        ("Sidebar", "list", L, "Places", initial),
        *[(f"Place {p}", "list item", LI, p, initial) for p in ("Home", "File system", "Start folder")],
        ("Up button", "push button", PB, "Up", initial),
        ("Path label", "label", LAB, small, initial),
        ("File list", "table or list", TBL, "Files", initial),
        *[(f"Column header {h}", "column header", {"column header", "table column header"}, h, initial) for h in ("Name", "Size", "Modified")],
        *[(f"Row {e}", "table row or list item", {"table row", "list item"}, e, initial) for e in entries],
        ("Context menu", "menu or popup menu", {"menu", "popup menu"}, None, menu),
        *[(f"Menu item {m}", "menu item", {"menu item"}, m, menu) for m in ("Open", "Copy Path", "Properties")],
        ("Properties dialog", "dialog", {"dialog"}, "Properties", dialog),
        ("Close button", "push button", PB, "Close", dialog),
    ]
    rows, bad = [], 0
    for control, exp_role, roles, nm, nodes in spec:
        if nm is None:
            ok = any(r in roles for _, r, _, _ in nodes)
            found = "no node with that role"
        else:
            ok = bool(has(nodes, nm, roles))
            others = sorted({r for _, r, n, _ in nodes if n == nm})
            found = f"wrong role: {', '.join(others)}" if others else "missing"
        bad += not ok
        rows.append({"control": control, "expected_role": exp_role, "expected_name": nm,
                     "result": "ok" if ok else found, "ok": ok})
    foc = {label: focused(nodes) for label, nodes in (("initial", initial), ("menu", menu), ("dialog", dialog))}
    json.dump({"total": len(spec), "failing": bad, "rows": rows, "focused": foc,
               "node_count": {k: len(v) for k, v in (("initial", initial), ("menu", menu), ("dialog", dialog))}},
              open(f"{sdir}/m6.json", "w"), indent=1, ensure_ascii=False)
    print(f"M6 {name}: {bad} of {len(spec)} controls missing or wrong; focused: {foc}")


# --- M7 -----------------------------------------------------------------------------------
def m7():
    results = []
    app = App(small)
    keep_keyboard()

    def label(nodes):
        return next((n for _, r, n, _ in nodes if r == "label" and n.startswith("/")), None)

    def foc(nodes):
        f = focused(nodes)
        return f[0] if f else None

    def selected_row(nodes):
        return next((n for _, r, n, s in nodes
                     if r in ("table row", "list item") and "selected" in s
                     and n not in ("Home", "File system", "Start folder")), None)

    def step(n, text, checks):
        results.append({"step": n, "text": text, "checks": checks})
        shot(f"m7-step{n:02d}")
        print(f"M7 {name} step {n}: " + "; ".join(f"{c['check']}: {c['result']}" for c in checks))

    def chk(check, want, got):
        """pass if got == want; 'unverifiable' if the toolkit exposes nothing (got is None); else fail."""
        want_t = list(want) if isinstance(want, tuple) else want
        got_t = list(got) if isinstance(got, tuple) else got
        r = "pass" if got == want else ("unverifiable" if got is None else "fail")
        return {"check": check, "result": r, "expected": want_t, "observed": got_t}

    def no_selection(nodes, text):
        """No selected row is visible through AT-SPI: either none selected, or rows are not exposed at all."""
        s = selected_row(nodes)
        return chk(text, "none", s) if s else {"check": text, "result": "unverifiable",
                                                "expected": "none", "observed": "rows or selection not exposed"}

    # 1
    n0 = app.nodes()
    c = [chk("focus on list at start", ("table", "Files"), foc(n0)), no_selection(n0, "no row selected at start")]
    key("Down")
    c.append(chk("Down selects docs", "docs", selected_row(app.nodes())))
    step(1, "Focus on the list, no row selected; Down selects docs", c)
    # 2
    key("Return")
    step(2, "Enter opens docs", [chk("path label", f"{small}/docs", label(app.nodes()))])
    # 3
    c = []
    key("Down", "Return")
    c.append(chk("path label after 2026", f"{small}/docs/2026", label(app.nodes())))
    key("Down", "Return")
    nodes = app.nodes()
    c.append(chk("path label after november", f"{small}/docs/2026/november", label(nodes)))
    c.append(no_selection(nodes, "no row selected"))
    step(3, "Down/Enter into 2026 and november", c)
    # 4
    key("BackSpace")
    a = label(app.nodes())
    key("Up", mods=["Alt_L"])
    b = label(app.nodes())
    step(4, "Backspace to docs/2026; Alt+Up to docs",
         [chk("after Backspace", f"{small}/docs/2026", a), chk("after Alt+Up", f"{small}/docs", b)])
    # 5
    c = []
    key("Tab", mods=["Shift_L"])
    c.append(chk("Shift+Tab focuses Up", ("push button", "Up"), foc(app.nodes())))
    key("Tab", mods=["Shift_L"])
    c.append(chk("Shift+Tab focuses Home", ("list item", "Home"), foc(app.nodes())))
    key("Down")
    c.append(chk("Down focuses File system", ("list item", "File system"), foc(app.nodes())))
    key("Return")
    c.append(chk("Enter opens /", "/", label(app.nodes())))
    step(5, "Shift+Tab to Up, to Home; Down; Enter opens /", c)
    # 6
    c = []
    key("Down")
    c.append(chk("Down focuses Start folder", ("list item", "Start folder"), foc(app.nodes())))
    key("Return")
    c.append(chk("Enter returns to small", small, label(app.nodes())))
    key("Tab")
    key("Tab")
    c.append(chk("Tab twice focuses the list", ("table", "Files"), foc(app.nodes())))
    step(6, "Down to Start folder; Enter; Tab twice to list", c)
    # 7: the Enter probe reads stdout: Enter on a file prints SPIKE_OPEN and does nothing else.
    key("End")
    sel = selected_row(app.nodes())
    mark = len(app.stdout_since_start())
    key("Return")
    opened = app.stdout_since_start()[mark:].strip()
    c = [chk("End selects Ünïcödé.txt (AT-SPI)", "Ünïcödé.txt", sel),
         chk("End selects Ünïcödé.txt (Enter prints SPIKE_OPEN)", f"SPIKE_OPEN {small}/Ünïcödé.txt", opened)]
    key("Home")
    c.append(chk("Home selects docs (AT-SPI)", "docs", selected_row(app.nodes())))
    step(7, "End selects Ünïcödé.txt; Home selects docs", c)
    # 8
    c = []
    key("F10", mods=["Shift_L"], wait=0.8)
    c.append(chk("Shift+F10 opens a menu with Open", True, has(app.nodes(), "Open")))
    key("Down", "Down", "Return", wait=1.0)
    c.append(chk("Properties dialog open", True, has(app.nodes(), "Properties")))
    key("Escape", wait=0.8)
    nodes = app.nodes()
    c.append(chk("dialog closed", False, has(nodes, "Properties")))
    c.append(chk("focus returns to list", ("table", "Files"), foc(nodes)))
    step(8, "Shift+F10; Down twice; Enter opens Properties; Escape closes, focus on list", c)
    # 9
    key("Down", "Down")
    key("Menu", wait=0.8)
    key("Down", "Return", wait=1.0)
    step(9, "Down twice selects notes-1.txt; Menu, Down, Enter copies the path",
         [chk("wl-paste", f"{small}/notes-1.txt", clipboard())])
    # 10
    key("Menu", wait=0.8)
    was_open = has(app.nodes(), "Open")
    key("Escape", wait=0.8)
    nodes = app.nodes()
    step(10, "Escape closes an open menu without action",
         [chk("menu was open", True, was_open), chk("menu closed", False, has(nodes, "Open")),
          chk("no dialog opened", False, has(nodes, "Properties")), chk("focus on list", ("table", "Files"), foc(nodes))])
    # 11
    mark = len(app.stdout_since_start())
    key("Return")
    step(11, "Enter on notes-1.txt prints SPIKE_OPEN",
         [chk("stdout", f"SPIKE_OPEN {small}/notes-1.txt", app.stdout_since_start()[mark:].strip())])
    app.stop()
    # 12: 10k folder. Neither toolkit exposes rows, so: Enter probe for End, screenshots 1 s after each key for the rest.
    app = App(big)
    key("End", wait=1.0)
    shot("m7-step12-end")
    mark = len(app.stdout_since_start())
    key("Return")
    o = app.stdout_since_start()[mark:].strip()
    key("Home", wait=1.0)
    shot("m7-step12-home")
    key("Next", wait=1.0)
    shot("m7-step12-pagedown")
    key("Prior", wait=1.0)
    shot("m7-step12-pageup")
    step(12, "10k folder: End, Home, Page Down, Page Up, each within 1 s (screenshots reviewed by hand)",
         [chk("End selects item-09999.md (Enter prints SPIKE_OPEN)", f"SPIKE_OPEN {big}/item-09999.md", o)])
    app.stop()
    keepalive.kill()
    json.dump(results, open(f"{sdir}/m7.json", "w"), indent=1, ensure_ascii=False)


{"m6": m6, "m7": m7}[mode]()
