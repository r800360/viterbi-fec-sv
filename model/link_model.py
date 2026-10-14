"""Cycle-free model of rtl/fec_link_top.sv's datapath: predicts the BER tester's counters exactly.

Every stage handles one item per valid cycle and keeps no timing-dependent state, so the counters depend only on the
number of source bits, the code and the channel settings. tb_link prints what the hardware counted; check_link.py
compares it with predict().
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fec  # noqa: E402

D3, D4 = 32, 40


def channel(syms, mode, thresh=0, period=0, burst=0, mask=0, holdoff=256, seed=0):
    """rtl/bsc_channel.sv: returns (received symbols, number of flipped bits)."""
    rng = fec.Xorshift32(seed if seed else 0x2545F491)
    phase, seen, flips, out = 0, 0, 0, []
    for s0, s1 in syms:
        x = rng.next()
        if mode == 1:
            err = ((x >> 16) < thresh, (x & 0xFFFF) < thresh)        # (bit 1, bit 0)
            e1, e0 = int(err[0]), int(err[1])
        elif mode == 2:
            e1, e0 = ((mask >> 1) & 1, mask & 1) if phase < burst else (0, 0)
        else:
            e1 = e0 = 0
        if seen < holdoff:
            e1 = e0 = 0
        nxt = (phase + 1) & 0xFFFF
        phase = 0 if nxt == period else nxt
        seen = min(seen + 1, 0xFFFF)
        flips += e0 + e1
        out.append((s0 ^ e0, s1 ^ e1))
    return out, flips


def hamming_tx(bits):
    """rtl/hamming84_tx: symbols start after the first 4 bits; codeword k is sent during the bits of block k+1."""
    syms = []
    for k in range(len(bits) - 4):
        block = k // 4
        c = fec.hamming84_encode(tuple(bits[4 * block:4 * block + 4]))
        i = k % 4
        syms.append((c[2 * i + 1], c[2 * i]))          # (sym0, sym1) = (low bit, high bit) of the symbol pair
    return syms


def hamming_rx(syms):
    """rtl/hamming84_rx: returns (bits, corrected, double)."""
    bits, corr, dbl = [], 0, 0
    data = None
    for k, _ in enumerate(syms):
        if k % 4 == 3:
            c = []
            for s0, s1 in syms[k - 3:k + 1]:
                c += [s1, s0]
            if data is not None:
                pass
            d, n = fec.hamming84_decode(tuple(c))
            corr += n == 1
            dbl += n == 2
            new_data = d
        if k >= 4:                                     # primed after the first codeword
            bits.append(data[k % 4])
        if k % 4 == 3:
            data = new_data
    return bits, corr, dbl


def checker(bits, n=15):
    """rtl/prbs_check: sync on the first n bits, then count mismatches against the free-running prediction."""
    if len(bits) < n:
        return 0, 0
    taps = fec.PRBS_TAPS[n]
    state = 0
    for b in bits[:n]:
        state = ((state << 1) | b) & ((1 << n) - 1)
    errs = 0
    for b in bits[n:]:
        pred = ((state >> (taps[0] - 1)) ^ (state >> (taps[1] - 1))) & 1
        errs += pred != b
        state = ((state << 1) | pred) & ((1 << n) - 1)
    return len(bits) - n, errs


def predict(code, n_bits, **ch):
    src = fec.Prbs(15, 1)
    bits = [src.next() for _ in range(n_bits)]
    ham = (0, 0)
    if code == 0:
        syms = [(b, 0) for b in bits]
    elif code == 1:
        syms = fec.encode(fec.K3, bits)
    elif code == 2:
        syms = fec.encode(fec.LTE, bits)
    else:
        syms = hamming_tx(bits)
    rx, flips = channel(syms, **ch)
    if code == 0:
        out = [s0 for s0, _ in rx]
    elif code == 1:
        out = fec.viterbi_re(fec.K3, rx, 1, D3)
    elif code == 2:
        out = fec.viterbi_re(fec.LTE, rx, 1, D4)
    else:
        out, c, d = hamming_rx(rx)
        ham = (c, d)
    nb, ne = checker(out)
    return {"bits": nb, "errors": ne, "flips": flips, "ham_corrected": ham[0], "ham_double": ham[1]}
