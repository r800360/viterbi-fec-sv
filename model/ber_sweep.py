#!/usr/bin/env python3
"""Bit error rate of every code in the link, from the bit-exact model (fixed seeds, so the output is reproducible).

usage: ber_sweep.py <results dir>
Writes ber_bsc.csv (binary symmetric channel, hard decisions: the link's own channel emulator) and ber_awgn.csv
(BPSK over AWGN: hard decisions and 3-bit soft decisions), and depth.csv (BER against survivor depth).
The decoders are the register-exchange models that tb_viterbi checks bit for bit against the RTL.
"""
import csv
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fec  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else "results"
NBITS = int(os.environ.get("BER_BITS", "60000"))
os.makedirs(OUT, exist_ok=True)


def hamming_link(bits, channel):
    """Encode 4-bit blocks with the (8,4) code, send 8 bits as 4 symbols, decode (2-error blocks left as received)."""
    nb = len(bits) // 4 * 4
    syms = []
    for i in range(0, nb, 4):
        c = fec.hamming84_encode(tuple(bits[i:i + 4]))
        syms += [(c[1], c[0]), (c[3], c[2]), (c[5], c[4]), (c[7], c[6])]
    rx = channel(syms)
    out = []
    for i in range(0, len(rx), 4):
        c = []
        for s0, s1 in rx[i:i + 4]:
            c += [s1, s0]
        out += list(fec.hamming84_decode(tuple(c))[0])
    return sum(a != b for a, b in zip(out, bits[:nb])), nb


def conv_link(code, bits, channel, q, depth):
    syms = fec.encode(code, bits)
    rx = channel(syms)
    out = fec.viterbi_re(code, rx, q, depth)
    return sum(a != b for a, b in zip(out, bits)), len(out)


def bits_for(seed):
    r = random.Random(seed)
    return [r.getrandbits(1) for _ in range(NBITS)]


def main():
    # ---- binary symmetric channel (the hardware's channel emulator), hard decisions
    rows = []
    for p in (0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10):
        bits = bits_for(1)
        ch = lambda s, p=p: fec.bsc(s, p, random.Random(11))  # noqa: E731
        e_h, n_h = hamming_link(bits, ch)
        e_3, n_3 = conv_link(fec.K3, bits, ch, 1, 32)
        e_l, n_l = conv_link(fec.LTE, bits, ch, 1, 40)
        rows.append([p, p, e_h / n_h, e_3 / n_3, e_l / n_l, n_3])
    with open(os.path.join(OUT, "ber_bsc.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["p", "uncoded", "hamming84", "k3_hard", "lte_hard", "bits"])
        for r in rows:
            w.writerow([f"{r[0]:g}"] + [f"{x:.6g}" for x in r[1:5]] + [r[5]])

    # ---- AWGN, BPSK: hard and 3-bit soft decisions
    rows = []
    for ebn0 in (0, 1, 2, 3, 4, 5, 6):
        bits = bits_for(2)
        hard = lambda s, e=ebn0: fec.awgn_soft(s, e, 1, rng=random.Random(13))  # noqa: E731
        soft = lambda s, e=ebn0: fec.awgn_soft(s, e, 3, rng=random.Random(13))  # noqa: E731
        unc = fec.q_function(math.sqrt(2 * 10 ** (ebn0 / 10)))
        e_h, n_h = hamming_link(bits, hard)
        e_3h, n = conv_link(fec.K3, bits, hard, 1, 32)
        e_3s, _ = conv_link(fec.K3, bits, soft, 3, 32)
        e_lh, nl = conv_link(fec.LTE, bits, hard, 1, 40)
        e_ls, _ = conv_link(fec.LTE, bits, soft, 3, 40)
        rows.append([ebn0, unc, e_h / n_h, e_3h / n, e_3s / n, e_lh / nl, e_ls / nl, n])
    with open(os.path.join(OUT, "ber_awgn.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["ebn0_db", "uncoded_theory", "hamming84_hard", "k3_hard", "k3_soft3", "lte_hard", "lte_soft3", "bits"])
        for r in rows:
            w.writerow([r[0]] + [f"{x:.6g}" for x in r[1:7]] + [r[7]])

    # ---- survivor depth: BER of the K = 3 hard decoder on a 3 % BSC, and of the full ML decoder
    bits = bits_for(3)
    syms = fec.encode(fec.K3, bits)
    rx = fec.bsc(syms, 0.03, random.Random(17))
    ml = fec.viterbi_ml(fec.K3, rx)
    ml_ber = sum(a != b for a, b in zip(ml, bits)) / len(bits)
    with open(os.path.join(OUT, "depth.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["depth", "k3_hard_ber", "ml_ber"])
        for d in (4, 6, 8, 10, 12, 16, 24, 32, 48):
            out = fec.viterbi_re(fec.K3, rx, 1, d)
            w.writerow([d, f"{sum(a != b for a, b in zip(out, bits)) / len(out):.6g}", f"{ml_ber:.6g}"])
    print("wrote ber_bsc.csv, ber_awgn.csv, depth.csv to", OUT)


if __name__ == "__main__":
    main()
