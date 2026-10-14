#!/usr/bin/env python3
"""Render selected signals of a VCD file as a timing diagram (SVG). Pure Python, deterministic output.

usage: vcd2svg.py <spec.json> <out.svg>

spec = {
  "vcd": "build/x.vcd",              # path relative to the spec's working directory
  "title": "...",                     # optional
  "t0": 0, "t1": 400,                 # window, in the VCD's time unit
  "unit": "ns", "timescale": 1,       # tick labels: time * timescale, shown with this unit
  "width": 960,                       # waveform area width in px (optional)
  "signals": [                        # rows; name is the hierarchical name with dots
     {"name": "tb.clk", "label": "clk"},
     {"name": "tb.dut.count", "label": "count", "radix": "bin" | "hex" | "dec" | "sdec"},
     {"divider": "outputs"}           # optional separator row with a caption
  ],
  "markers": [{"t": 120, "label": "load"}]   # optional vertical markers
}
"""
import html
import json
import re
import sys


def parse_vcd(path):
    """Return (timescale string, {fullname: id}, {id: width}, {id: [(t, value_str)]})."""
    names, widths, changes = {}, {}, {}
    scope = []
    t = 0
    timescale = ""
    with open(path) as f:
        data = f.read()
    tokens = iter(data.split())
    for tok in tokens:
        if tok == "$timescale":
            parts = []
            for x in tokens:
                if x == "$end":
                    break
                parts.append(x)
            timescale = "".join(parts)
        elif tok == "$scope":
            next(tokens)
            scope.append(next(tokens))
            next(tokens)
        elif tok == "$upscope":
            scope.pop()
            next(tokens)
        elif tok == "$var":
            parts = []
            for x in tokens:
                if x == "$end":
                    break
                parts.append(x)
            width, ident, name = int(parts[1]), parts[2], parts[3]
            full = ".".join(scope + [name])
            names.setdefault(full, ident)
            widths[ident] = width
            changes.setdefault(ident, [])
        elif tok in ("$comment", "$date", "$version"):
            for x in tokens:
                if x == "$end":
                    break
        elif tok in ("$enddefinitions", "$dumpvars", "$end", "$dumpon", "$dumpoff", "$dumpall"):
            continue
        elif tok[0] == "#":
            t = int(tok[1:])
        elif tok[0] in "01xzXZ":
            changes.setdefault(tok[1:], []).append((t, tok[0].lower()))
        elif tok[0] in "bB":
            ident = next(tokens)
            changes.setdefault(ident, []).append((t, tok[1:].lower()))
        elif tok[0] in "rR":
            ident = next(tokens)
            changes.setdefault(ident, []).append((t, tok[1:]))
    return timescale, names, widths, changes


def value_at(ch, t):
    v = None
    for tt, vv in ch:
        if tt > t:
            break
        v = vv
    return v


def fmt(bits, width, radix):
    if bits is None:
        return "?"
    bits = bits.rjust(width, bits[0] if bits[0] in "xz" else "0")
    if "x" in bits:
        return "X"
    if "z" in bits:
        return "Z"
    n = int(bits, 2)
    if radix == "bin":
        return bits
    if radix == "dec":
        return str(n)
    if radix == "sdec":
        return str(n - (1 << width) if bits[0] == "1" else n)
    digits = max(1, (width + 3) // 4)
    return format(n, "0%dX" % digits)


def main():
    spec_path, out = sys.argv[1], sys.argv[2]
    spec = json.load(open(spec_path))
    tscale, names, widths, changes = parse_vcd(spec["vcd"])
    # spec times are in spec["unit"]; the VCD counts in its own $timescale (e.g. 1ps): convert
    units = {"s": 1.0, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15}
    m = re.match(r"(\d+)\s*([munpf]?s)", tscale or "1ns")
    tick = int(m.group(1)) * units[m.group(2)]
    k = units[spec.get("unit", "ns")] / tick
    t0, t1 = round(spec["t0"] * k), round(spec["t1"] * k)
    spec["timescale"] = spec.get("timescale", 1) / k
    for mk in spec.get("markers", []):
        mk["t"] = round(mk["t"] * k)
    W = spec.get("width", 960)
    LW = spec.get("label_width", 150)
    RH, PAD = 26, 10
    scale = W / (t1 - t0)
    rows = spec["signals"]
    top = 34 if spec.get("title") else 12
    if spec.get("markers"):
        top += 16
    H = top + RH * len(rows) + 42
    X = lambda t: LW + (min(max(t, t0), t1) - t0) * scale  # noqa: E731
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{LW + W + PAD}" height="{H}" '
         f'viewBox="0 0 {LW + W + PAD} {H}" font-family="DejaVu Sans Mono, Consolas, monospace" font-size="12">',
         f'<rect width="{LW + W + PAD}" height="{H}" fill="#ffffff"/>']
    if spec.get("title"):
        o.append(f'<text x="{PAD}" y="20" font-family="DejaVu Sans, Arial, sans-serif" font-size="14" '
                 f'font-weight="bold" fill="#1f2328">{html.escape(spec["title"])}</text>')
    # clock grid: light lines at every rising edge of the first signal flagged "grid"
    for r in rows:
        if r.get("grid"):
            ch = changes[names[r["name"]]]
            for tt, vv in ch:
                if vv == "1" and t0 <= tt <= t1:
                    o.append(f'<line x1="{X(tt):.2f}" y1="{top - 4}" x2="{X(tt):.2f}" y2="{top + RH * len(rows)}" '
                             f'stroke="#e6e8eb" stroke-width="1"/>')
    for i, r in enumerate(rows):
        y = top + i * RH
        mid, hi, lo = y + RH / 2, y + 5, y + RH - 5
        if "divider" in r:
            o.append(f'<line x1="{PAD}" y1="{mid:.1f}" x2="{LW + W}" y2="{mid:.1f}" stroke="#d0d7de" '
                     f'stroke-dasharray="4 3"/>')
            o.append(f'<text x="{PAD}" y="{mid - 3:.1f}" fill="#57606a" font-size="11">{html.escape(r["divider"])}'
                     f'</text>')
            continue
        name = r["name"]
        if name not in names:
            raise SystemExit(f"signal {name} not in {spec['vcd']}; have e.g. {sorted(names)[:20]}")
        ident = names[name]
        width = widths[ident]
        ch = changes[ident]
        o.append(f'<text x="{PAD}" y="{mid + 4:.1f}" fill="#1f2328">{html.escape(r.get("label", name))}</text>')
        # segments within the window
        segs = []
        v = value_at(ch, t0)
        start = t0
        for tt, vv in ch:
            if tt <= t0:
                continue
            if tt >= t1:
                break
            if vv != v:
                segs.append((start, tt, v))
                start, v = tt, vv
        segs.append((start, t1, v))
        if width == 1 and r.get("radix") is None:
            pts = []
            for a, b, val in segs:
                xa, xb = X(a), X(b)
                if val in ("x", None):
                    o.append(f'<rect x="{xa:.2f}" y="{hi}" width="{xb - xa:.2f}" height="{lo - hi}" fill="#ffd7d5" '
                             f'stroke="#cf222e" stroke-width="0.8"/>')
                    pts.append(None)
                    continue
                if val == "z":
                    o.append(f'<line x1="{xa:.2f}" y1="{mid:.1f}" x2="{xb:.2f}" y2="{mid:.1f}" stroke="#0969da" '
                             f'stroke-width="1.5"/>')
                    pts.append(None)
                    continue
                yy = hi if val == "1" else lo
                pts.append((xa, yy))
                pts.append((xb, yy))
            # draw the 0/1 trace as polylines broken at X/Z
            run = []
            for p in pts + [None]:
                if p is None:
                    if len(run) > 1:
                        o.append('<polyline fill="none" stroke="#1a7f37" stroke-width="1.6" points="' +
                                 " ".join(f"{px:.2f},{py:.1f}" for px, py in run) + '"/>')
                    run = []
                else:
                    run.append(p)
        else:
            radix = r.get("radix", "hex")
            for a, b, val in segs:
                xa, xb = X(a), X(b)
                txt = fmt(val, width, radix) if width > 1 or radix else (val or "?")
                bad = txt in ("X", "?")
                k = min(4.0, (xb - xa) / 2)
                fill = "#ffd7d5" if bad else "#ddf4ff"
                stroke = "#cf222e" if bad else "#0550ae"
                o.append(f'<polygon points="{xa:.2f},{mid:.1f} {xa + k:.2f},{hi} {xb - k:.2f},{hi} {xb:.2f},{mid:.1f} '
                         f'{xb - k:.2f},{lo} {xa + k:.2f},{lo}" fill="{fill}" stroke="{stroke}" stroke-width="1"/>')
                if (xb - xa) > 7.2 * len(txt) + 4:
                    o.append(f'<text x="{(xa + xb) / 2:.2f}" y="{mid + 4:.1f}" text-anchor="middle" '
                             f'fill="#1f2328">{html.escape(txt)}</text>')
    # time axis
    ya = top + RH * len(rows) + 6
    o.append(f'<line x1="{LW}" y1="{ya}" x2="{LW + W}" y2="{ya}" stroke="#57606a"/>')
    span = t1 - t0
    ts = spec.get("timescale", 1)
    raw = span / 10
    mag = 10 ** (len(str(int(raw))) - 1) if raw >= 1 else 1
    step = next(m * mag for m in (1, 2, 5, 10) if m * mag >= raw)
    tick = (t0 // step) * step
    while tick <= t1:
        if tick >= t0:
            o.append(f'<line x1="{X(tick):.2f}" y1="{ya}" x2="{X(tick):.2f}" y2="{ya + 4}" stroke="#57606a"/>')
            label = round(tick * ts, 6)
            label = int(label) if float(label).is_integer() else label
            o.append(f'<text x="{X(tick):.2f}" y="{ya + 16}" text-anchor="middle" fill="#57606a" font-size="11">'
                     f'{label}</text>')
        tick += step
    o.append(f'<text x="{LW + W}" y="{ya + 28}" text-anchor="end" fill="#57606a" font-size="11">'
             f'time ({html.escape(spec.get("unit", "ns"))})</text>')
    for m in spec.get("markers", []):
        xm = X(m["t"])
        o.append(f'<line x1="{xm:.2f}" y1="{top - 14}" x2="{xm:.2f}" y2="{top + RH * len(rows)}" stroke="#bf8700" '
                 f'stroke-width="1.2" stroke-dasharray="5 3"/>')
        o.append(f'<text x="{xm + 3:.2f}" y="{top - 4}" fill="#9a6700" font-size="11">'
                 f'{html.escape(m["label"])}</text>')
    o.append("</svg>")
    with open(out, "w", newline="\n") as f:
        f.write("\n".join(o) + "\n")


if __name__ == "__main__":
    main()
