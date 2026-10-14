#!/usr/bin/env python3
"""Summarize a nextpnr --report JSON file: utilization, Fmax per clock, and the worst path of each kind.

usage: pnr_summary.py <report.json>
Clock names like "clk$SB_IO_IN_$glb_clk" are shortened to "clk". Numbers are rounded to 0.01 so the summary is
stable text. Path kinds: register to register (sets Fmax), input to register, register to output, and input to
output (purely combinational designs).
"""
import json
import re
import sys

r = json.load(open(sys.argv[1]))


def clk(name):
    name = re.sub(r"^(posedge|negedge) ", r"\1 ", name)
    return re.sub(r"\$SB_IO_IN(_\$glb_clk)?|\$glb_clk", "", name)


u = r["utilization"]
print("utilization: " + ", ".join(f"{k} {v['used']}/{v['available']}" for k, v in sorted(u.items())
                                  if v["used"] and k in ("ICESTORM_LC", "ICESTORM_RAM", "ICESTORM_DSP", "SB_IO",
                                                         "ICESTORM_SPRAM", "SB_GB")))
for name, f in sorted(r["fmax"].items()):
    print(f"Fmax {clk(name)}: {f['achieved']:.2f} MHz (constraint {f['constraint']:.2f} MHz)")
kinds = {}
for p in r["critical_paths"]:
    a, b = p["from"], p["to"]
    kind = ("input -> output" if a == b == "<async>" else
            "input -> register" if a == "<async>" else
            "register -> output" if b == "<async>" else
            f"register -> register ({clk(a)})")
    delay = sum(s["delay"] for s in p["path"])
    logic = sum(1 for s in p["path"] if s["type"] == "logic")
    if kind not in kinds or delay > kinds[kind][0]:
        kinds[kind] = (delay, logic, len(p["path"]))
for kind, (d, logic, n) in sorted(kinds.items()):
    print(f"worst {kind}: {d:.2f} ns, {logic} logic cells")
