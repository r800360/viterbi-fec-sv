// Formal harnesses (SymbiYosys tasks in fec.sby).

// hamming_props: for every 4-bit data word and every error pattern of weight <= 2 (inputs are free), the decoder
// returns the data for weight 0 and 1 and flags weight 2. Combinational, so one SAT call covers all 16 * 256 cases.
module hamming_props (input logic [3:0] d, input logic [7:0] e);
  logic [7:0] c;
  logic [3:0] dout;
  logic       corr, dbl;
  int         w;
  hamming84_enc u_enc (.d(d), .c(c));
  hamming84_dec u_dec (.c(c ^ e), .d(dout), .corrected(corr), .double_err(dbl));
  always_comb begin
    w = 0;
    for (int i = 0; i < 8; i++) w += int'(e[i]);
    if (w <= 1) assert (dout == d && !dbl);
    if (w == 1) assert (corr);
    if (w == 2) assert (dbl);
  end
endmodule

// encoder_spec: conv_encoder against the textbook equations written independently, for the K = 3 (7,5) code
// (outputs in ^ q1 ^ q2 and in ^ q2 over the last two inputs) and the LTE constituent code (w = d ^ s1 ^ s0 with
// state {s2, s1, s0}; parity d ^ s2 ^ s1, the form the code is often tabulated in). Unbounded (k-induction).
module encoder_spec (input logic clk, rst_n, in_valid, in_bit);
  wire       v3, vl;
  wire [1:0] y3, yl;
  conv_encoder #(.K(3), .G0(3'o7), .G1(3'o5)) u_k3 (.clk, .rst_n, .in_valid, .in_bit, .out_valid(v3), .out_sym(y3));
  conv_encoder #(.K(4), .G0(4'o0), .G1(4'o15), .FB(4'o13)) u_lte (.clk, .rst_n, .in_valid, .in_bit, .out_valid(vl),
                                                                   .out_sym(yl));
  logic       q1 = 0, q2 = 0, s2 = 0, s1 = 0, s0 = 0;
  logic [1:0] r3 = '0, rl = '0;
  logic       past = 1'b0;
  initial assume (!rst_n);
  always_ff @(posedge clk) begin
    past <= 1'b1;
    if (!rst_n) begin
      q1 <= 0; q2 <= 0; s2 <= 0; s1 <= 0; s0 <= 0; r3 <= '0; rl <= '0;
    end else if (in_valid) begin
      r3 <= {in_bit ^ q2, in_bit ^ q1 ^ q2};
      q1 <= in_bit; q2 <= q1;
      rl <= {in_bit ^ s2 ^ s1, in_bit};
      {s2, s1, s0} <= {in_bit ^ s1 ^ s0, s2, s1};
    end
  end
  always_comb if (past) begin
    assert (y3 == r3);
    assert (yl == rl);
  end
endmodule

// viterbi_clean: encoder -> decoder with no channel errors, K = 3, survivor depth 8, input valid on every cycle after
// reset. For any input sequence, every decoded bit equals the encoder input D + 1 accepted bits earlier (the encoder
// registers its output, so the decoder sees symbol t one cycle after input t). Bounded: 40 cycles, five survivor
// depths.
module viterbi_clean (input logic clk, rst_n, in_bit);
  localparam int D = 8;
  wire       ev, dv, db;
  wire [1:0] es;
  logic      past = 1'b0;
  conv_encoder #(.K(3), .G0(3'o7), .G1(3'o5)) u_enc (.clk, .rst_n, .in_valid(1'b1), .in_bit, .out_valid(ev),
                                                     .out_sym(es));
  viterbi_decoder #(.K(3), .G0(3'o7), .G1(3'o5), .Q(1), .D(D)) u_dec (.clk, .rst_n, .in_valid(ev),
      .in_sym0(es[0]), .in_sym1(es[1]), .out_valid(dv), .out_bit(db));
  logic [D+1:0] hist = '0;   // accepted input bits, newest in bit 0
  initial assume (!rst_n);
  always_ff @(posedge clk) past <= 1'b1;
  always_comb if (past) assume (rst_n);
  always_ff @(posedge clk) if (rst_n) hist <= {hist[D:0], in_bit};
`ifndef OFF_BY_ONE
  always_comb if (rst_n && dv) assert (db == hist[D+1]);
`else
  always_comb if (rst_n && dv) assert (db == hist[D]);    // deliberately wrong alignment: must fail
`endif
endmodule

// prbs7_period: from seed 1 the PRBS7 generator returns to state 1 after exactly 127 bits and not before (bounded,
// 130 steps). The harness rebuilds the state from the output bits (the last 7 outputs are the register), because
// Yosys cannot read u_g.state by hierarchical name.
module prbs7_period (input logic clk);
  logic       rst_n = 1'b0;
  wire        v, b;
  logic [6:0] st = '0;
  logic [7:0] n = '0;
  prbs_gen #(.N(7)) u_g (.clk, .rst_n, .seed(7'h01), .en(1'b1), .out_valid(v), .out_bit(b));
  always_ff @(posedge clk) begin
    rst_n <= 1'b1;
    if (rst_n && v) begin   // (before the first reset edge the generator's outputs are unknown)
      st <= {st[5:0], b};
      n  <= n + 1'b1;
    end
  end
  // n outputs seen; from 7 on, st is the generator's register
  always_comb if (n >= 7 && n < 127) assert (st != 7'h01);
  always_comb if (n == 127) assert (st == 7'h01);
endmodule

// uart_props: the receiver, for any line waveform. valid lasts one cycle; data changes only when valid rises (or at
// reset); valid and frame_err are never high together. Unbounded (k-induction).
module uart_props (input logic clk, rst_n, rx);
  wire       valid, ferr;
  wire [7:0] data;
  logic      past = 1'b0;
  uart_receiver #(.CLKS_PER_BIT(4)) u_rx (.clk, .rst_n, .rx, .valid, .data, .frame_err(ferr));   // 4 clocks per bit keeps the cover trace short
  initial assume (!rst_n);
  always_ff @(posedge clk) past <= 1'b1;
  always_ff @(posedge clk) if (past) begin
    if ($past(valid)) assert (!valid);
    if ($past(rst_n) && rst_n && !valid) assert (data == $past(data));
  end
  always_comb if (past) assert (!(valid && ferr));
  always_comb if (past) cover (valid && data == 8'hA5);
endmodule
