#!/bin/bash
# ppa_sweep.sh - area and speed of viterbi_decoder on an iCE40 HX8K across the design space.
# For each configuration: yosys synth_ice40 (decoder as top), nextpnr-ice40 --hx8k --package ct256 --seed 1 (timing
# target 48 MHz; a configuration that misses it is reported, not an error), and the
# utilization / Fmax from nextpnr's JSON report. Writes results/ppa.csv and results/ppa/<config>.pnr.log.
# Run from the repository root: bash tools/ppa_sweep.sh
set -euo pipefail
OUT=results; B=build/ppa
mkdir -p $OUT/ppa $B
echo "config,K,Q,D,states,LCs,flipflops,fmax_mhz" > $OUT/ppa.csv
# config K G0 G1 FB Q D   (polynomials in octal, D^0 in the most significant bit)
while read -r name k g0 g1 fb q d; do
  [ -z "$name" ] && continue
  yosys -q -l $B/$name.yosys.log -p "read_verilog -sv rtl/viterbi_decoder.sv;
    chparam -set K $k -set G0 $((8#$g0)) -set G1 $((8#$g1)) -set FB $((8#$fb)) -set Q $q -set D $d viterbi_decoder;
    synth_ice40 -top viterbi_decoder; delete t:\$scopeinfo; write_json $B/$name.json; tee -q -o $B/$name.stat stat" \
    < /dev/null > /dev/null
  nextpnr-ice40 --hx8k --package ct256 --json $B/$name.json --asc $B/$name.asc --seed 1 --freq 48 --timing-allow-fail \
    --report $B/$name.report.json < /dev/null > $B/$name.pnr.raw 2>&1
  python3 tools/pnr_summary.py $B/$name.report.json < /dev/null > $OUT/ppa/$name.pnr.log
  lcs=$(sed -n 's/.*ICESTORM_LC \([0-9]*\)\/.*/\1/p' $OUT/ppa/$name.pnr.log)
  ffs=$(awk '/SB_DFF/ {s += $2} END {print s + 0}' $B/$name.stat)
  fmax=$(sed -n 's/^Fmax clk: \([0-9.]*\) MHz.*/\1/p' $OUT/ppa/$name.pnr.log)
  echo "$name,$k,$q,$d,$((1 << (k - 1))),$lcs,$ffs,$fmax" >> $OUT/ppa.csv
  echo "$name: $lcs LCs, $ffs FFs, $fmax MHz"
done <<'EOF'
k3_hard_d8    3 7   5   0  1 8
k3_hard_d16   3 7   5   0  1 16
k3_hard_d32   3 7   5   0  1 32
k3_hard_d64   3 7   5   0  1 64
k3_soft3_d32  3 7   5   0  3 32
lte_hard_d40  4 0   15  13 1 40
lte_soft3_d40 4 0   15  13 3 40
k5_hard_d25   5 23  35  0  1 25
k6_hard_d30   6 53  75  0  1 30
k7_hard_d35   7 171 133 0  1 35
EOF
