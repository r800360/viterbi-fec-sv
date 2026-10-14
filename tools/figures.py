#!/usr/bin/env python3
"""Generate every chart and trellis diagram from results/*.csv and the code model (deterministic SVG).

usage: figures.py <results dir> <figures dir> <build dir>
Charts go through tools/svgchart.py; trellis diagrams are drawn directly.
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

# ---- trellis diagrams of both codes, drawn directly: two columns of states in order, one straight branch per
# (state, input), and each label next to the state it leaves (labels in the middle collide where branches cross)
def trellis(name, code, title):
    S, k = code.s, code.k
    green, red = "#1a7f37", "#cf222e"
    dy = 56 if S <= 4 else 46
    r, x0, x1, top = 17, 170, 590, 92
    W, H = 760, top + dy * (S - 1) + 40
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
         'font-family="DejaVu Sans, Arial, sans-serif" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
         "<defs>" + "".join(f'<marker id="arrow{d}" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="6" '
                            f'markerHeight="6" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
                            for d, c in ((0, green), (1, red))) + "</defs>",
         f'<text x="{W / 2}" y="24" text-anchor="middle" font-size="15" font-weight="bold" fill="#1f2328">{title}</text>',
         f'<text x="{W / 2}" y="44" text-anchor="middle" fill="#57606a">branch label: input bit / output bits '
         f'(sym1 sym0); <tspan fill="{green}">input 0</tspan>, <tspan fill="{red}">input 1</tspan></text>',
         f'<text x="{x0}" y="{top - 30}" text-anchor="middle" fill="#57606a">state at t</text>',
         f'<text x="{x1}" y="{top - 30}" text-anchor="middle" fill="#57606a">state at t + 1</text>']
    labels = []
    for s in range(S):
        for d in (0, 1):
            ns, (s0, s1) = code.step(s, d)
            c = green if d == 0 else red
            ax, ay, bx, by = x0, top + s * dy, x1, top + ns * dy
            n = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5
            ux, uy = (bx - ax) / n, (by - ay) / n
            o.append(f'<line x1="{ax + ux * r:.1f}" y1="{ay + uy * r:.1f}" x2="{bx - ux * (r + 1):.1f}" '
                     f'y2="{by - uy * (r + 1):.1f}" stroke="{c}" stroke-width="1.6" marker-end="url(#arrow{d})"/>')
            # the label sits on its own branch (a white halo hides the line under it), input-0 labels 10 % and
            # input-1 labels 30 % of the way along: labels in one column stay >= 23 px apart for both codes
            f = 0.10 if d == 0 else 0.30
            lx, ly = ax + f * (bx - ax), ay + f * (by - ay) + 4
            labels.append(f'<text x="{lx:.1f}" y="{ly:.1f}" text-anchor="middle" font-size="11" fill="{c}" '
                          f'stroke="#ffffff" stroke-width="3" paint-order="stroke">{d}/{s1}{s0}</text>')
    for x in (x0, x1):
        for st in range(S):
            y = top + st * dy
            o.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#ffffff" stroke="#0969da" stroke-width="1.5"/>')
            o.append(f'<text x="{x}" y="{y + 4}" text-anchor="middle" fill="#1f2328">{st:0{k - 1}b}</text>')
    o += labels + ["</svg>"]
    open(os.path.join(FIG, name + ".svg"), "w", newline="\n").write("\n".join(o) + "\n")


trellis("trellis_k3", fec.K3, "K=3 (7,5) code: 4 states")
trellis("trellis_lte", fec.LTE, "LTE RSC (13,15) code: 8 states")
print("figures written to", FIG)
