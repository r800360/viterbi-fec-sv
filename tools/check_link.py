#!/usr/bin/env python3
"""Compare tb_link's counters with model/link_model.py, scenario by scenario.

usage: check_link.py <tb_link log> [<results table .md>]
Every LINK line must match the model's prediction exactly (bits, errors, channel flips, Hamming counters).
Prints a table and exits 1 on any difference.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "model"))
import link_model  # noqa: E402

FIELDS = ("bits", "errors", "flips", "ham_corrected", "ham_double")
CODES = {0: "uncoded", 1: "K=3 (7,5)", 2: "LTE RSC K=4", 3: "Hamming (8,4)"}


def main():
    lines = [l for l in open(sys.argv[1]) if l.startswith("LINK ")]
    if not lines:
        sys.exit("no LINK lines in the log")
    rows, bad = [], 0
    for ln in lines:
        name = ln.split()[1]
        kv = dict(re.findall(r"(\w+)=(\d+)", ln))
        kv = {k: int(v) for k, v in kv.items()}
        pred = link_model.predict(kv["code"], kv["nsrc"], mode=kv["mode"], thresh=kv["thresh"], period=kv["period"],
                                  burst=kv["burst"], mask=kv["mask"])
        same = all(pred[f] == kv[f] for f in FIELDS)
        bad += not same
        rows.append((name, CODES[kv["code"]], kv["nsrc"], kv["bits"], kv["flips"], kv["errors"],
                     kv["errors"] / max(kv["bits"], 1), "yes" if same else f"NO: model {pred}"))
    out = ["| scenario | code | source bits | bits checked | channel bit flips | decoded bit errors | BER | = model |",
           "|---|---|---:|---:|---:|---:|---:|---|"]
    out += [f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} | {r[5]} | {r[6]:.2e} | {r[7]} |" for r in rows]
    text = "\n".join(out)
    print(text)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w", newline="\n") as f:
            f.write(text + "\n")
    print("RESULT: " + ("PASS" if not bad else f"FAIL {bad} of {len(rows)} scenarios") + f" ({len(rows)} scenarios)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
