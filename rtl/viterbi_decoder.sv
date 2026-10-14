// Viterbi decoder for the rate-1/2 codes of conv_encoder (same K, G0, G1, FB parameters), register-exchange survivor
// management, hard or soft decisions.
//
//   in_sym0/in_sym1  received channel symbols for out_sym[0] / out_sym[1] of the encoder, Q bits each: 0 is a sure 0,
//                    2^Q - 1 a sure 1 (Q = 1 is hard decision)
//   out_bit          the decoded input bit of the symbol received D symbols earlier (out_valid marks it)
//
// Trellis: state = encoder register s (K-1 bits). State ns is entered from p0 = {ns[K-3:0], 0} and
// p1 = {ns[K-3:0], 1}; the bit shifted in is w = ns[K-2], and the input that caused the transition is d = w
// (feed-forward) or d = w ^ ^(FB & p) (recursive). Branch labels are computed from the code at elaboration time.
//
// Per symbol, for every state: branch metric = distance of the received symbols to the branch label (sum over the
// two bits of r or MAXV - r), add-compare-select with ties going to p0, and the survivor register of the winner is
// shifted left with the decision's input bit. After D symbols the survivors have merged (D >= 5K is the usual rule),
// and the oldest bit of the best state's survivor is the output.
//
// Path metrics are W-bit and wrap around: a < b is decided by the sign of (a - b), which is exact as long as all
// metrics stay within 2^(W-1) of each other. They do: the spread of a K-state trellis is bounded by about
// 2 * MAXV * (K - 1), and the start-up penalty is 2^(W-3). So no normalization logic is needed.
// model/fec.py implements exactly this algorithm and is the bit-exact reference for the testbenches.
module viterbi_decoder #(
  parameter int K = 3,
  parameter logic [K-1:0] G0 = 'o7,
  parameter logic [K-1:0] G1 = 'o5,
  parameter logic [K-1:0] FB = '0,
  parameter int Q = 1,              // soft-decision bits per symbol
  parameter int D = 32,             // survivor depth (decoding latency in symbols)
  parameter int W = Q + 8           // path metric width
) (
  input  logic         clk,
  input  logic         rst_n,       // synchronous, active low
  input  logic         in_valid,
  input  logic [Q-1:0] in_sym0,
  input  logic [Q-1:0] in_sym1,
  output logic         out_valid,
  output logic         out_bit
);
  localparam int S = 1 << (K - 1);                 // number of states
  localparam int MAXV = (1 << Q) - 1;
  localparam logic [W-1:0] PENALTY = 1 << (W - 3); // start-up cost of every state except 0

  // ---- the trellis, from the code parameters (constant functions, evaluated at elaboration)
  /* verilator lint_off UNUSEDSIGNAL */   // int arguments: only their low bits matter
  function automatic logic [K-2:0] pred(input int ns, input int b);   // predecessor b of state ns
    logic [K-2:0] r;
    r = ns[K-2:0];
    pred = {r[K-3:0], b[0]};
  endfunction

  function automatic logic in_of(input int ns, input int b);          // input bit of the branch pred(ns,b) -> ns
    logic [K-2:0] p;
    logic         w;
    p = pred(ns, b);
    w = ns[K-2];
    in_of = (FB == '0) ? w : w ^ (^(FB[K-2:0] & p));
  endfunction

  function automatic logic [1:0] label(input int ns, input int b);    // encoder output on that branch
    logic [K-2:0] p;
    logic         w;
    p = pred(ns, b);
    w = ns[K-2];
    if (FB == '0) label = {^(G1 & {w, p}), ^(G0 & {w, p})};
    else          label = {^(G1 & {w, p}), in_of(ns, b)};
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic less(input logic [W-1:0] a, input logic [W-1:0] b);   // a < b, modulo 2^W
    logic [W-1:0] diff;
    diff = a - b;
    less = diff[W-1];
  endfunction

  function automatic logic [W-1:0] bm(input logic [1:0] lab, input logic [Q-1:0] r0, input logic [Q-1:0] r1);
    logic [Q:0] d0, d1;
    d0 = lab[0] ? {1'b0, Q'(MAXV)} - {1'b0, r0} : {1'b0, r0};
    d1 = lab[1] ? {1'b0, Q'(MAXV)} - {1'b0, r1} : {1'b0, r1};
    bm = W'(d0) + W'(d1);
  endfunction

  // ---- state
  logic [W-1:0] pm [S];          // path metrics
  logic [D-1:0] surv [S];        // survivor bits, oldest in bit D-1
  logic [W-1:0] pm_n [S];
  logic [D-1:0] surv_n [S];
  localparam int CW = $clog2(D + 1);
  localparam logic [CW-1:0] DCNT = D[CW-1:0];
  logic [CW-1:0] count;          // symbols decoded so far, saturating at D
  logic [K-2:0] best;

  // ---- add-compare-select, one per state
  for (genvar ns = 0; ns < S; ns++) begin : g_acs
    localparam int P0 = int'(pred(ns, 0));
    localparam int P1 = int'(pred(ns, 1));
    localparam logic [1:0] L0 = label(ns, 0);
    localparam logic [1:0] L1 = label(ns, 1);
    localparam logic I0 = in_of(ns, 0);
    localparam logic I1 = in_of(ns, 1);
    logic [W-1:0] c0, c1;
    logic         sel;
    assign c0         = pm[P0] + bm(L0, in_sym0, in_sym1);
    assign c1         = pm[P1] + bm(L1, in_sym0, in_sym1);
    assign sel        = less(c1, c0);                       // ties go to p0
    assign pm_n[ns]   = sel ? c1 : c0;
    assign surv_n[ns] = sel ? {surv[P1][D-2:0], I1} : {surv[P0][D-2:0], I0};
  end

  // ---- the state with the smallest metric (lowest index on ties): a binary tree of comparators, log2(S) levels.
  // Heap order: node n has children 2n+1 (lower state indices) and 2n+2; leaves S-1 .. 2S-2 are states 0 .. S-1.
  // The right child wins only if strictly smaller, so every node keeps the lowest-index minimum of its subtree,
  // the same answer as a linear scan, at log depth instead of S - 1 comparators in series.
  logic [W-1:0] hv [2*S-1] /*verilator split_var*/;   // (split_var: Verilator otherwise sees a false loop)
  logic [K-2:0] hx [2*S-1] /*verilator split_var*/;
  for (genvar i = 0; i < S; i++) begin : g_leaf
    localparam logic [K-2:0] IDX = i;
    assign hv[S-1+i] = pm[i];
    assign hx[S-1+i] = IDX;
  end
  for (genvar n = 0; n < S - 1; n++) begin : g_node
    logic right;
    assign right = less(hv[2*n+2], hv[2*n+1]);
    assign hv[n] = right ? hv[2*n+2] : hv[2*n+1];
    assign hx[n] = right ? hx[2*n+2] : hx[2*n+1];
  end
  assign best = hx[0];

  always_ff @(posedge clk)
    if (!rst_n) begin
      for (int i = 0; i < S; i++) begin
        pm[i]   <= (i == 0) ? '0 : PENALTY;
        surv[i] <= '0;
      end
      count     <= '0;
      out_valid <= 1'b0;
      out_bit   <= 1'b0;
    end else begin
      out_valid <= 1'b0;
      if (in_valid) begin
        for (int i = 0; i < S; i++) begin
          pm[i]   <= pm_n[i];
          surv[i] <= surv_n[i];
        end
        out_bit   <= surv[best][D-1];
        out_valid <= (count == DCNT);
        if (count != DCNT) count <= count + 1'b1;
      end
    end
endmodule
