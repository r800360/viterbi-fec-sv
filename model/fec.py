"""Reference model of the FEC link, bit-exact with the RTL where the RTL is deterministic.

Codes use the conventional octal polynomial notation (most significant bit = D^0), exactly as rtl/conv_encoder.sv:
    Code(3, 0o7, 0o5)              the classic K = 3 feed-forward code
    Code(4, 0, 0o15, fb=0o13)      the LTE turbo constituent code (recursive systematic; G0 unused)

    encode(code, bits)                          -> list of (sym0, sym1)
    viterbi_re(code, syms, q, depth, w)         -> decoded bits, exactly as rtl/viterbi_decoder.sv
    viterbi_ml(code, syms, q)                   -> full maximum-likelihood decoding (trace back from the best end state)
    hamming84_encode / hamming84_decode         -> the (8,4) extended Hamming SEC-DED code of rtl/hamming84.sv
    Prbs, Xorshift32                            -> the bit sources of rtl/prbs.sv and rtl/bsc_channel.sv

Pure Python (no numpy), so it runs anywhere the simulators do.
"""
import math
import random


def parity(x):
    return bin(x).count("1") & 1


class Code:
    def __init__(self, k, g0, g1, fb=0):
        self.k, self.g0, self.g1, self.fb = k, g0, g1, fb
        self.s = 1 << (k - 1)
        self.fb_low = fb & ((1 << (k - 1)) - 1)

    def step(self, s, d):
        """One encoder step from state s with input d: (next state, (sym0, sym1))."""
        k = self.k
        w = d if self.fb == 0 else d ^ parity(self.fb_low & s)
        ws = (w << (k - 1)) | s
        sym1 = parity(self.g1 & ws)
        sym0 = parity(self.g0 & ws) if self.fb == 0 else d
        return (w << (k - 2)) | (s >> 1), (sym0, sym1)

    def branches(self, ns):
        """The two branches into state ns: [(predecessor, input bit, (sym0, sym1))] for b = 0, 1."""
        k = self.k
        out = []
        for b in (0, 1):
            p = ((ns & ((1 << (k - 2)) - 1)) << 1) | b
            w = (ns >> (k - 2)) & 1
            d = w if self.fb == 0 else w ^ parity(self.fb_low & p)
            nxt, lab = self.step(p, d)
            assert nxt == ns
            out.append((p, d, lab))
        return out

    def __repr__(self):
        if self.fb:
            return f"RSC K={self.k} (fb {self.fb:o}, parity {self.g1:o})"
        return f"K={self.k} ({self.g0:o}, {self.g1:o})"


K3 = Code(3, 0o7, 0o5)
LTE = Code(4, 0, 0o15, fb=0o13)


def encode(code, bits, s=0):
    out = []
    for d in bits:
        s, sym = code.step(s, d)
        out.append(sym)
    return out


# ---------------------------------------------------------------- decoders
def _bm(lab, r, maxv):
    return sum((maxv - ri) if li else ri for li, ri in zip(lab, r))


def viterbi_re(code, syms, q=1, depth=32, w=None):
    """Register-exchange Viterbi decoder, bit-exact with rtl/viterbi_decoder.sv.

    syms: list of (r0, r1), each 0 .. 2^q - 1. Returns the decoded bits: one per symbol after the first `depth`,
    the bit for symbol t - depth when symbol t arrives.
    """
    w = q + 8 if w is None else w
    mask, half = (1 << w) - 1, 1 << (w - 1)
    maxv = (1 << q) - 1
    S = code.s
    br = [code.branches(ns) for ns in range(S)]

    def less(a, b):
        return ((a - b) & mask) >= half

    pm = [0] + [1 << (w - 3)] * (S - 1)
    surv = [0] * S
    dmask = (1 << depth) - 1
    count, out = 0, []
    for r in syms:
        best = 0
        for i in range(1, S):
            if less(pm[i], pm[best]):
                best = i
        if count == depth:
            out.append((surv[best] >> (depth - 1)) & 1)
        npm, nsurv = [0] * S, [0] * S
        for ns in range(S):
            (p0, d0, l0), (p1, d1, l1) = br[ns]
            c0 = (pm[p0] + _bm(l0, r, maxv)) & mask
            c1 = (pm[p1] + _bm(l1, r, maxv)) & mask
            if less(c1, c0):
                npm[ns], nsurv[ns] = c1, ((surv[p1] << 1) | d1) & dmask
            else:
                npm[ns], nsurv[ns] = c0, ((surv[p0] << 1) | d0) & dmask
        pm, surv = npm, nsurv
        count = min(count + 1, depth)
    return out


def viterbi_ml(code, syms, q=1):
    """Maximum-likelihood sequence decoding (unbounded metrics, trace back from the best final state)."""
    maxv = (1 << q) - 1
    S = code.s
    br = [code.branches(ns) for ns in range(S)]
    inf = float("inf")
    pm = [0] + [inf] * (S - 1)
    hist = []
    for r in syms:
        npm, dec = [inf] * S, [None] * S
        for ns in range(S):
            (p0, d0, l0), (p1, d1, l1) = br[ns]
            c0, c1 = pm[p0] + _bm(l0, r, maxv), pm[p1] + _bm(l1, r, maxv)
            npm[ns], dec[ns] = (c1, (p1, d1)) if c1 < c0 else (c0, (p0, d0))
        pm = npm
        hist.append(dec)
    s = min(range(S), key=lambda i: pm[i])
    bits = []
    for dec in reversed(hist):
        p, d = dec[s]
        bits.append(d)
        s = p
    return bits[::-1]


# ---------------------------------------------------------------- (8,4) extended Hamming, SEC-DED
def hamming84_encode(d):
    """d = (D4, D3, D2, D1) -> 8 bits (D4, D3, D2, D1, P4, P2, P1, P0)."""
    d4, d3, d2, d1 = d
    p4, p2, p1 = d4 ^ d3 ^ d2, d4 ^ d3 ^ d1, d4 ^ d2 ^ d1
    p0 = d4 ^ d3 ^ d2 ^ d1 ^ p4 ^ p2 ^ p1
    return (d4, d3, d2, d1, p4, p2, p1, p0)


SYNDROME_BIT = {0b111: 0, 0b110: 1, 0b101: 2, 0b011: 3}   # syndrome {s4, s2, s1} -> data bit index (D4..D1)


def hamming84_decode(c):
    """8 received bits -> (data (D4..D1), errors 0 / 1 / 2). With 2 errors the data is returned uncorrected."""
    d = list(c[:4])
    p4, p2, p1, p0 = c[4:]
    e4, e2, e1, _ = hamming84_encode(tuple(d))[4:]
    syn = ((p4 ^ e4) << 2) | ((p2 ^ e2) << 1) | (p1 ^ e1)
    overall = parity(int("".join(map(str, c)), 2))
    if syn == 0:
        return tuple(d), (1 if overall else 0)
    if not overall:
        return tuple(d), 2
    if syn in SYNDROME_BIT:
        d[SYNDROME_BIT[syn]] ^= 1
    return tuple(d), 1


# ---------------------------------------------------------------- bit sources
PRBS_TAPS = {7: (7, 6), 9: (9, 5), 15: (15, 14), 23: (23, 18), 31: (31, 28)}


class Prbs:
    """Fibonacci LFSR as rtl/prbs.sv: shift left, the XOR of the two taps enters bit 0, which is the output."""

    def __init__(self, n=15, seed=1):
        self.n, self.state = n, seed
        self.t1, self.t2 = PRBS_TAPS[n]

    def next(self):
        fb = ((self.state >> (self.t1 - 1)) ^ (self.state >> (self.t2 - 1))) & 1
        self.state = ((self.state << 1) | fb) & ((1 << self.n) - 1)
        return fb


class Xorshift32:
    """rtl/bsc_channel.sv's random source: x ^= x << 13; x ^= x >> 17; x ^= x << 5 (32 bits)."""

    def __init__(self, seed=0x2545F491):
        self.x = seed

    def next(self):
        x = self.x
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.x = x
        return x


# ---------------------------------------------------------------- channels
def bsc(syms, p, rng=None):
    """Binary symmetric channel on hard symbols."""
    rng = rng or random.Random(1)
    return [tuple(b ^ (rng.random() < p) for b in s) for s in syms]


def awgn_soft(syms, ebn0_db, q, rate=0.5, rng=None, clip=1.0):
    """BPSK over AWGN, received values quantized to q bits over [-clip, +clip] (0 = sure 0, 2^q - 1 = sure 1)."""
    rng = rng or random.Random(1)
    sigma = math.sqrt(1.0 / (2.0 * rate * 10 ** (ebn0_db / 10.0)))
    levels = 1 << q
    out = []
    for s in syms:
        r = []
        for b in s:
            y = (2 * b - 1) + rng.gauss(0.0, sigma)
            if q == 1:
                r.append(1 if y > 0 else 0)
            else:
                v = int(math.floor((y + clip) / (2 * clip) * levels))
                r.append(min(max(v, 0), levels - 1))
        out.append(tuple(r))
    return out


def q_function(x):
    return 0.5 * math.erfc(x / math.sqrt(2.0))
