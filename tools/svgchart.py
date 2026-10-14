#!/usr/bin/env python3
"""Minimal deterministic SVG charts (no dependencies).

usage: svgchart.py <spec.json> <out.svg>

line chart:  {"kind": "line", "title": ..., "xlabel": ..., "ylabel": ..., "logy": false,
              "series": [{"name": ..., "x": [...], "y": [...], "dash": false, "marker": true}], "note": "..."}
bar chart:   {"kind": "bar", "title": ..., "ylabel": ..., "logy": false, "categories": [...],
              "series": [{"name": ..., "y": [...]}], "labels": true}
"""
import html
import json
import math
import sys

PALETTE = ["#0969da", "#cf222e", "#1a7f37", "#8250df", "#bf8700", "#1b7c83", "#d1242f", "#57606a"]


def nice_ticks(lo, hi, n=6):
    if hi == lo:
        hi = lo + 1
    raw = (hi - lo) / n
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 2.5, 5, 10) if m * mag >= raw)
    start = math.floor(lo / step) * step
    ticks, t = [], start
    while t <= hi + step * 1e-9:
        ticks.append(round(t, 10))
        t += step
    return ticks


def fmt(v):
    if v == 0:
        return "0"
    if abs(v) >= 1e4 or abs(v) < 1e-3:
        return f"{v:.0e}".replace("e-0", "e-").replace("e+0", "e")
    return f"{v:g}"


def main():
    spec = json.load(open(sys.argv[1]))
    W, H = spec.get("width", 760), spec.get("height", 420)
    L, R, T, B = 78, 24 + (170 if spec.get("legend_right") else 0), 44, 62
    pw, ph = W - L - R, H - T - B
    logy = spec.get("logy", False)
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
         f'font-family="DejaVu Sans, Arial, sans-serif" font-size="12">',
         f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
         f'<text x="{L}" y="24" font-size="15" font-weight="bold" fill="#1f2328">{html.escape(spec["title"])}</text>']
    ys = [y for s in spec["series"] for y in s["y"] if y is not None and (not logy or y > 0)]
    if logy:
        ylo = 10 ** math.floor(math.log10(min(ys)))
        yhi = 10 ** math.ceil(math.log10(max(ys)))
        ylo = spec.get("ymin", ylo)
        yhi = spec.get("ymax", yhi)
        Y = lambda v: T + ph - (math.log10(v) - math.log10(ylo)) / (math.log10(yhi) - math.log10(ylo)) * ph  # noqa
        yt = [10 ** e for e in range(int(round(math.log10(ylo))), int(round(math.log10(yhi))) + 1)]
    else:
        ylo = spec.get("ymin", min(0, min(ys)))
        yhi = spec.get("ymax", max(ys) * 1.08 if max(ys) > 0 else 1)
        yt = nice_ticks(ylo, yhi)
        ylo, yhi = min(ylo, yt[0]), max(yhi, yt[-1])
        Y = lambda v: T + ph - (v - ylo) / (yhi - ylo) * ph  # noqa
    for t in yt:
        o.append(f'<line x1="{L}" y1="{Y(t):.1f}" x2="{L + pw}" y2="{Y(t):.1f}" stroke="#eaeef2"/>')
        o.append(f'<text x="{L - 6}" y="{Y(t) + 4:.1f}" text-anchor="end" fill="#57606a">{fmt(t)}</text>')
    o.append(f'<text transform="translate(18,{T + ph / 2}) rotate(-90)" text-anchor="middle" fill="#1f2328">'
             f'{html.escape(spec.get("ylabel", ""))}</text>')
    o.append(f'<rect x="{L}" y="{T}" width="{pw}" height="{ph}" fill="none" stroke="#8c959f"/>')
    if spec["kind"] == "line":
        xs = [x for s in spec["series"] for x in s["x"]]
        xlo, xhi = spec.get("xmin", min(xs)), spec.get("xmax", max(xs))
        xt = spec.get("xticks") or nice_ticks(xlo, xhi)
        X = lambda v: L + (v - xlo) / (xhi - xlo) * pw  # noqa
        for t in xt:
            if xlo <= t <= xhi:
                o.append(f'<line x1="{X(t):.1f}" y1="{T}" x2="{X(t):.1f}" y2="{T + ph}" stroke="#f3f4f6"/>')
                o.append(f'<text x="{X(t):.1f}" y="{T + ph + 16}" text-anchor="middle" fill="#57606a">{fmt(t)}</text>')
        o.append(f'<text x="{L + pw / 2}" y="{H - 22}" text-anchor="middle" fill="#1f2328">'
                 f'{html.escape(spec.get("xlabel", ""))}</text>')
        for i, s in enumerate(spec["series"]):
            c = s.get("color", PALETTE[i % len(PALETTE)])
            pts = [(X(x), Y(y)) for x, y in zip(s["x"], s["y"]) if y is not None and (not logy or y > 0)]
            dash = ' stroke-dasharray="6 4"' if s.get("dash") else ""
            o.append(f'<polyline fill="none" stroke="{c}" stroke-width="2"{dash} points="' +
                     " ".join(f"{px:.1f},{py:.1f}" for px, py in pts) + '"/>')
            if s.get("marker", True):
                for px, py in pts:
                    o.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="3" fill="{c}"/>')
    else:
        cats = spec["categories"]
        n = len(spec["series"])
        gw = pw / len(cats)
        bw = gw * 0.8 / n
        base = Y(ylo) if not logy else T + ph
        for ci, cat in enumerate(cats):
            o.append(f'<text x="{L + gw * (ci + 0.5):.1f}" y="{T + ph + 16}" text-anchor="middle" fill="#1f2328">'
                     f'{html.escape(cat)}</text>')
            for si, s in enumerate(spec["series"]):
                v = s["y"][ci]
                if v is None or (logy and v <= 0):
                    continue
                c = s.get("color", PALETTE[si % len(PALETTE)])
                x = L + gw * ci + gw * 0.1 + bw * si
                y = Y(v)
                o.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw - 2:.1f}" height="{base - y:.1f}" fill="{c}"/>')
                if spec.get("labels", True):
                    o.append(f'<text x="{x + (bw - 2) / 2:.1f}" y="{y - 4:.1f}" text-anchor="middle" '
                             f'font-size="10" fill="#1f2328">{fmt(v)}</text>')
        if spec.get("xlabel"):
            o.append(f'<text x="{L + pw / 2}" y="{H - 22}" text-anchor="middle" fill="#1f2328">'
                     f'{html.escape(spec["xlabel"])}</text>')
    # legend
    lx = L + pw + 12 if spec.get("legend_right") else L + 10
    ly = T + 10 if spec.get("legend_right") else T + 12
    if len(spec["series"]) > 1 or spec.get("legend_right"):
        for i, s in enumerate(spec["series"]):
            c = s.get("color", PALETTE[i % len(PALETTE)])
            yy = ly + i * 17
            if not spec.get("legend_right"):
                o.append(f'<rect x="{lx - 4}" y="{yy - 10}" width="{8 + 7 * len(s["name"]) + 22}" height="16" '
                         f'fill="#ffffff" fill-opacity="0.85"/>')
            dash = ' stroke-dasharray="6 4"' if s.get("dash") else ""
            o.append(f'<line x1="{lx}" y1="{yy - 3}" x2="{lx + 18}" y2="{yy - 3}" stroke="{c}" stroke-width="3"'
                     f'{dash}/>')
            o.append(f'<text x="{lx + 24}" y="{yy + 1}" fill="#1f2328">{html.escape(s["name"])}</text>')
    if spec.get("note"):
        o.append(f'<text x="{L}" y="{H - 6}" font-size="11" fill="#57606a">{html.escape(spec["note"])}</text>')
    o.append("</svg>")
    with open(sys.argv[2], "w", newline="\n") as f:
        f.write("\n".join(o) + "\n")


if __name__ == "__main__":
    main()
