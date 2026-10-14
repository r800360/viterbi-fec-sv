#!/usr/bin/env python3
"""Generate every chart and trellis diagram from results/*.csv and the code model (deterministic SVG).

usage: figures.py <results dir> <figures dir> <build dir>
Charts go through tools/svgchart.py; trellis diagrams are Graphviz files rendered with dot.
"""
import csv
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "model"))
import fec  # noqa: E402

RES, FIG, BLD = sys.argv[1:4]
os.makedirs(FIG, exist_ok=True)
os.makedirs(BLD, exist_ok=True)


def chart(name, spec):
    p = os.path.join(BLD, name + ".json")
    json.dump(spec, open(p, "w"))
    subprocess.run([sys.executable, os.path.join(HERE, "svgchart.py"), p, os.path.join(FIG, name + ".svg")], check=True)


def rows(name):
    return list(csv.DictReader(open(os.path.join(RES, name))))


def col(rs, key, x="x"):
    return [float(r[key]) if float(r[key]) > 0 else None for r in rs]


# ---- BER on the binary symmetric channel (the hardware's channel emulator)
r = rows("ber_bsc.csv")
x = [100 * float(v["p"]) for v in r]
chart("ber_bsc", {
    "kind": "line", "logy": True, "ymin": 1e-5, "ymax": 1, "legend_right": True, "width": 900,
    "title": "Decoded bit error rate, binary symmetric channel, hard decisions",
    "xlabel": "channel bit error probability (%)", "ylabel": "bit error rate",
    "series": [{"name": "uncoded", "x": x, "y": col(r, "uncoded"), "dash": True},
               {"name": "Hamming (8,4) SEC-DED", "x": x, "y": col(r, "hamming84")},
               {"name": "K=3 (7,5) Viterbi, depth 32", "x": x, "y": col(r, "k3_hard")},
               {"name": "LTE RSC K=4 Viterbi, depth 40", "x": x, "y": col(r, "lte_hard")}],
    "note": f"{r[0]['bits']} bits per point; points with no errors are not drawn. All codes are rate 1/2."})

# ---- BER on AWGN, hard vs soft decisions
r = rows("ber_awgn.csv")
x = [float(v["ebn0_db"]) for v in r]
chart("ber_awgn", {
    "kind": "line", "logy": True, "ymin": 1e-5, "ymax": 1, "legend_right": True, "width": 900,
    "title": "Decoded bit error rate, BPSK over AWGN: hard vs 3-bit soft decisions",
    "xlabel": "Eb/N0 (dB)", "ylabel": "bit error rate",
    "series": [{"name": "uncoded BPSK (theory)", "x": x, "y": col(r, "uncoded_theory"), "dash": True},
               {"name": "Hamming (8,4), hard", "x": x, "y": col(r, "hamming84_hard")},
               {"name": "K=3 Viterbi, hard", "x": x, "y": col(r, "k3_hard")},
               {"name": "K=3 Viterbi, 3-bit soft", "x": x, "y": col(r, "k3_soft3")},
               {"name": "LTE RSC Viterbi, hard", "x": x, "y": col(r, "lte_hard")},
               {"name": "LTE RSC Viterbi, 3-bit soft", "x": x, "y": col(r, "lte_soft3")}],
    "note": f"{r[0]['bits']} bits per point. Soft decisions gain about 2 dB."})

# ---- survivor depth
r = rows("depth.csv")
x = [float(v["depth"]) for v in r]
chart("depth", {
    "kind": "line", "logy": True,
    "title": "Register-exchange survivor depth vs. full maximum-likelihood decoding (K=3, 3 % BSC)",
    "xlabel": "survivor depth D (symbols of latency)", "ylabel": "bit error rate",
    "series": [{"name": "register-exchange decoder", "x": x, "y": col(r, "k3_hard_ber")},
               {"name": "maximum-likelihood (full trace-back)", "x": x, "y": col(r, "ml_ber"), "dash": True,
                "marker": False}],
    "note": "From about D = 4K = 12 the fixed-latency decoder matches maximum-likelihood decoding."})

# ---- area and speed on iCE40
r = rows("ppa.csv")
chart("ppa", {
    "kind": "bar", "title": "Decoder size on an iCE40 HX8K (nextpnr, seed 1)",
    "ylabel": "logic cells", "categories": [v["config"].replace("_", " ") for v in r],
    "series": [{"name": "logic cells", "y": [int(v["LCs"]) for v in r]}], "labels": True, "width": 900})
chart("fmax", {
    "kind": "bar", "title": "Decoder clock frequency on an iCE40 HX8K (nextpnr timing, seed 1)",
    "ylabel": "Fmax (MHz)", "categories": [v["config"].replace("_", " ") for v in r],
    "series": [{"name": "Fmax", "y": [float(v["fmax_mhz"]) for v in r]}], "labels": True, "width": 900})

# ---- trellis diagrams of both codes
for name, code, title in (("trellis_k3", fec.K3, "K=3 (7,5): 4 states"),
                          ("trellis_lte", fec.LTE, "LTE RSC (13,15): 8 states")):
    k = code.k
    lines = ["digraph trellis {", '  rankdir=LR; bgcolor="white"; nodesep=0.25; ranksep=1.6; splines=line;',
             '  node [shape=circle, fontname="DejaVu Sans", fontsize=10, width=0.5, fixedsize=true, color="#0969da"];',
             '  edge [fontname="DejaVu Sans", fontsize=8, arrowsize=0.5];',
             f'  label="{title}   (labels: input / output sym1 sym0)"; labelloc=t; fontname="DejaVu Sans"; fontsize=12;']
    S = code.s
    for t in (0, 1):
        lines.append(f"  subgraph cluster_{t} {{ style=invis; " +
                     " ".join(f'"{t}_{s}" [label="{s:0{k - 1}b}"];' for s in range(S)) + " }")
    for s in range(S):
        for d in (0, 1):
            ns, (s0, s1) = code.step(s, d)
            color = "#1a7f37" if d == 0 else "#cf222e"
            lines.append(f'  "0_{s}" -> "1_{ns}" [label="{d}/{s1}{s0}", color="{color}", fontcolor="{color}"];')
    lines.append("}")
    dot = os.path.join(BLD, name + ".dot")
    open(dot, "w", newline="\n").write("\n".join(lines) + "\n")
    svg = subprocess.run(["dot", "-Tsvg", dot], check=True, capture_output=True, text=True).stdout
    svg = "\n".join(l for l in svg.splitlines() if not l.startswith("<!-- Generated by graphviz")
                    and not l.strip().startswith("<title>"))
    open(os.path.join(FIG, name + ".svg"), "w", newline="\n").write(svg + "\n")
print("figures written to", FIG)
