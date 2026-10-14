#!/usr/bin/env python3
"""Write the test vectors of the encoder and decoder testbenches from the reference model (model/fec.py).

usage: gen_vectors.py <out_dir>

Every file is a list of hex words for $readmemh, one per line:
  enc_<code>.hex        {in_bit, sym1, sym0} per input bit, from the encoder model
  dec_<config>.hex      {r1, r0} (soft values, 4 bits each) per symbol
  dec_<config>.exp      one decoded bit per line, from the bit-exact register-exchange model
The decoder configurations cover both codes, hard and 3-bit soft decisions, several survivor depths, error-free
and noisy channels, and a worked K = 3 decoding example: 16 received symbols, padded with zero-input symbols.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fec  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else "build/vectors"
os.makedirs(OUT, exist_ok=True)
rng = random.Random(2026)


def write(name, words):
    with open(os.path.join(OUT, name), "w", newline="\n") as f:
        f.write("\n".join(words) + "\n")


# ---- encoders
for name, code in (("k3", fec.K3), ("lte", fec.LTE)):
    bits = [rng.randint(0, 1) for _ in range(2000)]
    syms = fec.encode(code, bits)
    write(f"enc_{name}.hex", [f"{(b << 2) | (s1 << 1) | s0:x}" for b, (s0, s1) in zip(bits, syms)])

# ---- decoders: (name, code, q, depth, channel)
CONFIGS = [
    ("k3_hard_d16_clean", fec.K3, 1, 16, ("clean",)),
    ("k3_hard_d32_bsc5", fec.K3, 1, 32, ("bsc", 0.05)),
    ("k3_hard_d32_bsc10", fec.K3, 1, 32, ("bsc", 0.10)),
    ("lte_hard_d40_clean", fec.LTE, 1, 40, ("clean",)),
    ("lte_hard_d40_bsc5", fec.LTE, 1, 40, ("bsc", 0.05)),
    ("k3_soft3_d32_awgn2", fec.K3, 3, 32, ("awgn", 2.0)),
    ("lte_soft3_d40_awgn2", fec.LTE, 3, 40, ("awgn", 2.0)),
    ("k3_soft3_d24_awgn0", fec.K3, 3, 24, ("awgn", 0.0)),
]
N = 3000
manifest = []
for name, code, q, depth, ch in CONFIGS:
    bits = [rng.randint(0, 1) for _ in range(N)]
    syms = fec.encode(code, bits)
    maxv = (1 << q) - 1
    if ch[0] == "clean":
        rx = [(s0 * maxv, s1 * maxv) for s0, s1 in syms]
    elif ch[0] == "bsc":
        rx = [(s0 * maxv, s1 * maxv) for s0, s1 in fec.bsc(syms, ch[1], random.Random(7))]
    else:
        rx = fec.awgn_soft(syms, ch[1], q, rng=random.Random(7))
    dec = fec.viterbi_re(code, rx, q, depth)
    write(f"dec_{name}.hex", [f"{(r1 << 4) | r0:02x}" for r0, r1 in rx])
    write(f"dec_{name}.exp", [str(b) for b in dec])
    errors = sum(a != b for a, b in zip(dec, bits))
    manifest.append(f"{name} symbols={len(rx)} decoded={len(dec)} bit_errors_vs_input={errors}")

# ---- a worked example: 16 received K = 3 symbols, then 40 error-free zero-input symbols to flush the survivors
rx = [(int(a), int(b)) for a, b in "00 00 00 11 01 10 01 11 00 11 01 01 00 10 11 00".split()]
state = 0
for i in range(16):                       # follow the encoder through the 16 inputs the ML decoder finds
    state, _ = fec.K3.step(state, fec.viterbi_ml(fec.K3, rx)[i])
pad = fec.encode(fec.K3, [0] * 40, s=state)
allrx = rx + pad
dec = fec.viterbi_re(fec.K3, allrx, 1, 32)
write("dec_k3_worked_example.hex", [f"{(r1 << 4) | r0:02x}" for r0, r1 in allrx])
write("dec_k3_worked_example.exp", [str(b) for b in dec])
manifest.append(f"k3_worked_example decoded first 16 bits = {''.join(map(str, dec[:16]))}")

write("MANIFEST.txt", manifest)
print("\n".join(manifest))
