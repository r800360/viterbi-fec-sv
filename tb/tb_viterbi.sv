// tb_viterbi - streams received symbols from a vector file into viterbi_decoder and compares every decoded bit with
// the bit-exact reference model's output (model/gen_vectors.py).
//   parameters K, G0, G1, FB, Q, D: the decoder configuration (set with -P / -G)
//   +VEC=<path>   vector files <path>.hex (symbols {r1, r0}, 4 bits each) and <path>.exp (expected bits)
//   +N=<n>        number of symbols;  +GAPS  insert random idle cycles between symbols (in_valid low)
`timescale 1ns/1ps
`include "tb_util.svh"

module tb_viterbi;
  parameter int K = 3;
  parameter logic [K-1:0] G0 = 'o7;
  parameter logic [K-1:0] G1 = 'o5;
  parameter logic [K-1:0] FB = '0;
  parameter int Q = 1;
  parameter int D = 32;
  localparam int MAXN = 4096;
  `TB_COUNTERS

  logic clk = 0, rst_n = 0, in_valid = 0;
  logic [Q-1:0] r0 = '0, r1 = '0;
  wire out_valid, out_bit;
  viterbi_decoder #(.K(K), .G0(G0), .G1(G1), .FB(FB), .Q(Q), .D(D)) dut (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_sym0(r0), .in_sym1(r1),
    .out_valid(out_valid), .out_bit(out_bit));
  always #5 clk = ~clk;

  logic [7:0] sym [MAXN];
  logic       expb [MAXN];
  int n, nexp, got;
  string vec;
  logic [31:0] lfsr = 32'h1;

  // path metrics of states 0-3, as plain signals for the timing diagram (VCD dumps skip unpacked arrays)
  wire [15:0] pm0 = 16'(dut.pm[0]), pm1 = 16'(dut.pm[1]), pm2 = 16'(dut.pm[2]), pm3 = 16'(dut.pm[3]);
  initial if ($test$plusargs("VCD")) begin
    $dumpfile("tb_viterbi.vcd");
    $dumpvars(0, tb_viterbi);
  end

  always @(posedge clk) if (rst_n && out_valid) begin
    if (got < nexp) `CHECK_EQ(out_bit, expb[got], $sformatf("decoded bit %0d", got))
    got++;
  end

  initial begin
    if (!$value$plusargs("VEC=%s", vec)) $fatal(1, "+VEC=<path> is required");
    if (!$value$plusargs("N=%d", n)) n = 3000;
    $readmemh({vec, ".hex"}, sym, 0, n - 1);
    nexp = n - D;
    $readmemb({vec, ".exp"}, expb, 0, nexp - 1);
    got = 0;
    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;
    for (int i = 0; i < n; i++) begin
      if ($test$plusargs("GAPS")) begin
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        repeat (lfsr[1:0]) begin @(negedge clk) in_valid = 0; end
      end
      @(negedge clk);
      in_valid = 1;
      r0 = sym[i][Q-1:0];
      r1 = sym[i][4 +: Q];
    end
    @(negedge clk) in_valid = 0;
    repeat (5) @(posedge clk);
    `CHECK_EQ(got, nexp, "number of decoded bits")
    $display("decoded %0d bits, K=%0d Q=%0d D=%0d, vectors %s", got, K, Q, D, vec);
    `TB_FINISH
  end
endmodule
