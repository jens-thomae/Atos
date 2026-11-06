#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""AT-SPI tree of the spike (#59): dump, or press a button by name through the Action interface.
Usage: atspi_dump.py dump <out.txt> | atspi_dump.py press <button name>"""
import sys
import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402


def walk(node, depth, out):
    try:
        states = sorted(s.value_nick for s in node.get_state_set().get_states())
        out.append(f"{'  ' * depth}{node.get_role_name()} {node.get_name()!r} {states}")
        for i in range(node.get_child_count()):
            walk(node.get_child_at_index(i), depth + 1, out)
    except Exception as e:  # node vanished while walking
        out.append(f"{'  ' * depth}<error {e}>")


def apps():
    desk = Atspi.get_desktop(0)
    return [desk.get_child_at_index(i) for i in range(desk.get_child_count())]


def find(node, name):
    if node.get_name() == name and node.get_role_name() in ("push button", "button"):
        return node
    for i in range(node.get_child_count()):
        r = find(node.get_child_at_index(i), name)
        if r:
            return r
    return None


if sys.argv[1] == "dump":
    out = []
    for a in apps():
        walk(a, 0, out)
    text = "\n".join(out) + "\n" if out else "(no application on the AT-SPI bus)\n"
    open(sys.argv[2], "w").write(text)
    print(text, end="")
else:
    name = sys.argv[2]
    for a in apps():
        b = find(a, name)
        if b:
            act = b.get_action_iface()
            names = [act.get_action_name(i) for i in range(act.get_n_actions())]
            print(f"press {name!r}: actions {names}")
            act.do_action(0)
            sys.exit(0)
    sys.exit(f"no button {name!r} on the bus")
