#!/bin/bash
# flow.sh <stage>... : the verification and implementation flow. Run from the repository root (see the Makefile).
#   lint     verilator --lint-only -Wall on the whole design
#   sim      every testbench in Icarus Verilog and Verilator, and the link counters against the model
#   formal   every SymbiYosys task, each with its expected outcome
#   ber      BER curves from the bit-exact model
#   ppa      area and speed on iCE40 (yosys + nextpnr)
#   figures  charts, trellis diagrams, block diagram and timing diagrams
# Every check records "<name> expected X got Y ok|UNEXPECTED" in results/SUMMARY.txt; the script fails if any
# outcome is unexpected. Logs are normalized (no run times, paths or tool banners) so reruns are byte-identical.
set -euo pipefail
[ -f "$HOME/eda-env.sh" ] && . "$HOME/eda-env.sh"   # local tool installs (CI installs them with apt)

RTL="rtl/prbs.sv rtl/conv_encoder.sv rtl/conv_encoder_prog.sv rtl/viterbi_decoder.sv rtl/bsc_channel.sv rtl/hamming84.sv rtl/uart.sv rtl/fec_link_top.sv"
RES=results; FIG=figures; B=build
mkdir -p $RES/sim $RES/formal $RES/summary $FIG $B
FAILURES=0
STAGE=none

record() {   # record <name> <expected> <actual>
  local ok=ok
  [ "$2" = "$3" ] || { ok=UNEXPECTED; FAILURES=$((FAILURES + 1)); echo "!! $1: expected $2, got $3" >&2; }
  printf '%-58s expected %-6s got %-6s %s\n' "$1" "$2" "$3" "$ok" >> $RES/summary/$STAGE.txt
}
normalize() {
  sed -E -e "s#$PWD/##g" -e '/^- (V e r i l a t i o n|S i m u l a t i o n|Verilator:)/d' -e '/\$finish called|\$stop called/d' \
         -e '/^VCD info/d' -e '/^ *$/d'
}
verdict() { grep -q '^RESULT: PASS' "$1" && echo PASS || echo FAIL; }

sim_iv() {   # sim_iv <name> <top> <flags> <files...> -- <plusargs>
  local name=$1 top=$2 flags=$3; shift 3
  local files=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do files+=("$1"); shift; done
  [ $# -gt 0 ] && shift && args=("$@")
  iverilog -g2012 -Itb -Wno-timescale $flags -s $top -o $B/$name.vvp "${files[@]}" 2> >(grep -v 'sorry: constant selects' >&2)
  vvp -n $B/$name.vvp "${args[@]}" | normalize > $RES/sim/$name.icarus.log
  record "$name (icarus)" PASS "$(verdict $RES/sim/$name.icarus.log)"
}
sim_vl() {   # sim_vl <name> <top> <flags> <files...> -- <plusargs>
  local name=$1 top=$2 flags=$3; shift 3
  local files=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do files+=("$1"); shift; done
  [ $# -gt 0 ] && shift && args=("$@")
  verilator --binary --timing -Itb -Wno-fatal -Wno-lint -Wno-style $flags --top-module $top -Mdir $B/obj_$name -o sim \
    "${files[@]}" > $B/obj_$name.build.log 2>&1
  $B/obj_$name/sim "${args[@]}" | normalize > $RES/sim/$name.verilator.log
  record "$name (verilator)" PASS "$(verdict $RES/sim/$name.verilator.log)"
}

stage_lint() {
  verilator --lint-only -Wall -Wno-DECLFILENAME --top-module fec_link_top $RTL > $B/lint.raw 2>&1 || true
  normalize < $B/lint.raw > $RES/lint.log
  if [ -s $RES/lint.log ]; then record "lint -Wall (whole design)" CLEAN WARN; else
    echo "verilator --lint-only -Wall: no warnings" > $RES/lint.log; record "lint -Wall (whole design)" CLEAN CLEAN; fi
}

stage_sim() {
  python3 model/gen_vectors.py $B/vectors > $RES/vectors_manifest.txt
  # decoder configurations: name K G0 G1 FB (decimal) Q D N
  while read -r name k g0 g1 fb q d n; do
    [ -z "$name" ] && continue
    P="-Ptb_viterbi.K=$k -Ptb_viterbi.G0=$g0 -Ptb_viterbi.G1=$g1 -Ptb_viterbi.FB=$fb -Ptb_viterbi.Q=$q -Ptb_viterbi.D=$d"
    G="-GK=$k -GG0=$g0 -GG1=$g1 -GFB=$fb -GQ=$q -GD=$d"
    sim_iv viterbi_$name tb_viterbi "$P" tb/tb_viterbi.sv rtl/viterbi_decoder.sv -- +VEC=$B/vectors/dec_$name +N=$n +GAPS < /dev/null
    sim_vl viterbi_$name tb_viterbi "$G" tb/tb_viterbi.sv rtl/viterbi_decoder.sv -- +VEC=$B/vectors/dec_$name +N=$n < /dev/null
  done <<'EOF'
k3_hard_d16_clean    3 7 5 0  1 16 3000
k3_hard_d32_bsc5     3 7 5 0  1 32 3000
k3_hard_d32_bsc10    3 7 5 0  1 32 3000
lte_hard_d40_clean   4 0 13 11 1 40 3000
lte_hard_d40_bsc5    4 0 13 11 1 40 3000
k3_soft3_d32_awgn2   3 7 5 0  3 32 3000
lte_soft3_d40_awgn2  4 0 13 11 3 40 3000
k3_soft3_d24_awgn0   3 7 5 0  3 24 3000
k3_worked_example    3 7 5 0  1 32 56
EOF
  BLOCKS="tb/tb_blocks.sv rtl/prbs.sv rtl/conv_encoder.sv rtl/conv_encoder_prog.sv rtl/hamming84.sv rtl/uart.sv"
  sim_iv blocks tb_blocks "" $BLOCKS
  sim_vl blocks tb_blocks "" $BLOCKS
  sim_iv link tb_link "" tb/tb_link.sv $RTL -- +VCD
  sim_vl link tb_link "" tb/tb_link.sv $RTL
  for s in icarus verilator; do
    python3 tools/check_link.py $RES/sim/link.$s.log $RES/link_$s.md > $B/check_link_$s.log || true
    record "link counters = model ($s)" PASS "$(grep -q '^RESULT: PASS' $B/check_link_$s.log && echo PASS || echo FAIL)"
  done
  mv -f tb_link.vcd $B/ 2>/dev/null || true
  # a short clean run with a waveform dump for the timing diagram
  vvp -n $B/viterbi_k3_hard_d16_clean.vvp +VEC=$B/vectors/dec_k3_hard_d16_clean +N=40 +VCD > /dev/null
  mv -f tb_viterbi.vcd $B/
}

stage_formal() {
  # task expected-outcome
  while read -r task want; do
    [ -z "$task" ] && continue
    (cd formal && sby -f fec.sby $task > /dev/null 2>&1) && got=PASS || got=FAIL
    grep -E 'summary|DONE' formal/fec_$task/logfile.txt | grep -v 'Elapsed' | sed -E 's/^SBY +[0-9:]+ +//; s/ +$//' > $RES/formal/$task.log
    record "formal $task" $want $got
  done <<'EOF'
hamming PASS
encoder PASS
viterbi PASS
viterbi_offbyone FAIL
prbs7 PASS
uart PASS
uart_cover PASS
EOF
}

stage_ber() { python3 model/ber_sweep.py $RES > /dev/null; record "BER sweep written" yes "$( [ -s $RES/ber_awgn.csv ] && echo yes || echo no)"; }
stage_ppa() { bash tools/ppa_sweep.sh > /dev/null; record "PPA sweep: 10 configurations" 10 "$(($(wc -l < $RES/ppa.csv) - 1))"; }

stage_figures() {
  python3 tools/figures.py $RES $FIG $B/fig > /dev/null
  dot -Tsvg docs/block_diagram.dot | sed -E '/^<!-- Generated by graphviz/,/-->/d; s/<title>[^<]*<\/title>//;
    s/font-family="DejaVu Sans"/font-family="DejaVu Sans, Arial, sans-serif"/g;
    s/font-family="DejaVu Sans Mono"/font-family="DejaVu Sans Mono, Consolas, monospace"/g' > $FIG/block_diagram.svg
  for w in docs/waves/*.json; do python3 tools/vcd2svg.py $w $FIG/$(basename $w .json).svg; done
}

for st in "$@"; do
  STAGE=$st
  : > $RES/summary/$st.txt
  "stage_$st"
done
cat $RES/summary/*.txt > $RES/SUMMARY.txt   # every stage's checks, including stages not rerun now
echo "== $*: $FAILURES unexpected; $(grep -c ' ok$' $RES/SUMMARY.txt) checks ok in results/SUMMARY.txt"
[ "$FAILURES" -eq 0 ]
