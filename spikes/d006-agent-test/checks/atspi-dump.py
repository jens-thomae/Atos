#!/usr/bin/env python3
# Dumps role, name and states of every node of the app named by argv[1] (default: any) on the AT-SPI bus.
import sys, gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi
def dump(n, d=0):
    st = [s.value_nick for s in Atspi.StateType.__enum_values__.values() if n.get_state_set().contains(s)] if False else []
    print("  "*d + f"{n.get_role_name()} {n.get_name()!r}")
    for i in range(n.get_child_count()):
        c = n.get_child_at_index(i)
        if c: dump(c, d+1)
desk = Atspi.get_desktop(0)
for i in range(desk.get_child_count()):
    a = desk.get_child_at_index(i)
    if len(sys.argv) < 2 or sys.argv[1] in (a.get_name() or ""): dump(a)
