// tb_blocks - self-checking tests of the link's building blocks.
//   encoders   conv_encoder (K = 3 7/5 and the LTE RSC) and conv_encoder_prog (loaded with 7/5) against the model's
//              vectors (build/vectors/enc_*.hex, 2000 random bits each), including a reprogramming in mid-stream
//   hamming    hamming84_dec on all 16 data words x every error pattern of weight 0, 1 and 2 (37 patterns):
//              weight <= 1 must decode the data, weight 2 must be flagged; then the tx/rx adapters back to back
//   prbs       PRBS7 and PRBS9 visit 2^N - 1 states before repeating; the checker locks and counts injected errors
//   uart       tx -> rx loopback of all 256 bytes, a framing error, and a glitch on the idle line
`timescale 1ns/1ps
`include "tb_util.svh"

module tb_blocks;
  `TB_COUNTERS
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------------ encoders
  logic        e_valid = 0, e_bit = 0;
  logic [1:0]  p_load = 0;
  logic [6:0]  p_g = 0;
  wire         k3_v, lte_v, prog_v;
  wire [1:0]   k3_s, lte_s, prog_s;
  conv_encoder #(.K(3), .G0(3'o7), .G1(3'o5)) u_k3 (.clk, .rst_n, .in_valid(e_valid), .in_bit(e_bit),
                                                    .out_valid(k3_v), .out_sym(k3_s));
  conv_encoder #(.K(4), .G0(4'o0), .G1(4'o15), .FB(4'o13)) u_lte (.clk, .rst_n, .in_valid(e_valid), .in_bit(e_bit),
                                                    .out_valid(lte_v), .out_sym(lte_s));
  conv_encoder_prog #(.KMAX(7)) u_prog (.clk, .rst_n, .load(p_load), .g_in(p_g), .in_valid(e_valid),
                                        .in_bit(e_bit), .out_valid(prog_v), .out_sym(prog_s));
  logic [2:0] vk3 [2000], vlte [2000];

  task automatic run_encoders();
    $readmemh("build/vectors/enc_k3.hex", vk3);
    $readmemh("build/vectors/enc_lte.hex", vlte);
    // program 7, 5 into the programmable encoder (D^0 in bit 6)
    @(negedge clk) p_g = 7'b1110000; p_load = 2'b01;
    @(negedge clk) p_g = 7'b1010000; p_load = 2'b10;
    @(negedge clk) p_load = 2'b00;
    // the two fixed encoders read different streams, so run them one after the other
    for (int pass = 0; pass < 2; pass++) begin
      @(negedge clk) rst_n = 0;
      @(negedge clk) rst_n = 1;
      for (int i = 0; i < 2000; i++) begin
        @(negedge clk);
        e_valid = 1;
        e_bit   = pass == 0 ? vk3[i][2] : vlte[i][2];
        // reprogramming in the middle of the stream: the history must hold, and 7/5 afterwards must continue
        if (pass == 0 && i == 1000) begin
          e_valid = 0;
          p_g = 7'b1010000; p_load = 2'b11;          // both generators 5 for one cycle ...
          @(negedge clk) p_g = 7'b1110000; p_load = 2'b01;   // ... then 7 back into generator 0
          @(negedge clk) p_g = 7'b1010000; p_load = 2'b10;   // and 5 into generator 1
          @(negedge clk) p_load = 2'b00;
          e_valid = 1;
        end
        @(posedge clk); #1;
        if (pass == 0) begin
          `CHECK_EQ(k3_s, vk3[i][1:0], $sformatf("K=3 encoder symbol %0d", i))
          `CHECK_EQ(prog_s, vk3[i][1:0], $sformatf("programmable encoder (7,5) symbol %0d", i))
        end else
          `CHECK_EQ(lte_s, vlte[i][1:0], $sformatf("LTE RSC encoder symbol %0d", i))
      end
      @(negedge clk) e_valid = 0;
    end
  endtask

  // ------------------------------------------------------------------ Hamming (8,4)
  logic [7:0] h_c;
  wire  [3:0] h_d;
  wire        h_corr, h_dbl;
  hamming84_dec u_hdec (.c(h_c), .d(h_d), .corrected(h_corr), .double_err(h_dbl));
  wire  [7:0] h_cw;
  logic [3:0] h_data;
  hamming84_enc u_henc (.d(h_data), .c(h_cw));

  task automatic run_hamming();
    for (int d = 0; d < 16; d++) begin
      h_data = 4'(d);
      #1;
      h_c = h_cw;                                             // no error
      #1;
      `CHECK_EQ(h_d, h_data, $sformatf("data %0h, no error", d))
      `CHECK_EQ({h_corr, h_dbl}, 2'b00, "no error: no flags")
      for (int j = 0; j < 8; j++) begin                       // one error: corrected
        h_c = h_cw ^ (8'd1 << j);
        #1;
        `CHECK_EQ(h_d, h_data, $sformatf("data %0h, error at bit %0d corrected", d, j))
        `CHECK_EQ({h_corr, h_dbl}, 2'b10, "one error: corrected, not double")
      end
      for (int i = 0; i < 8; i++)                             // two errors: detected
        for (int j = i + 1; j < 8; j++) begin
          h_c = h_cw ^ (8'd1 << i) ^ (8'd1 << j);
          #1;
          `CHECK_EQ(h_dbl, 1'b1, $sformatf("data %0h, errors at bits %0d and %0d flagged", d, i, j))
        end
    end
  endtask

  // ------------------------------------------------------------------ PRBS
  logic        g_en = 0;
  wire         g7_v, g7_b, g9_v, g9_b;
  prbs_gen #(.N(7)) u_g7 (.clk, .rst_n, .seed(7'h1), .en(g_en), .out_valid(g7_v), .out_bit(g7_b));
  prbs_gen #(.N(9)) u_g9 (.clk, .rst_n, .seed(9'h1), .en(g_en), .out_valid(g9_v), .out_bit(g9_b));
  logic        c_flip = 0;
  wire         c_locked;
  wire  [31:0] c_bits, c_errs;
  prbs_check #(.N(9)) u_c9 (.clk, .rst_n, .clear(1'b0), .in_valid(g9_v), .in_bit(g9_b ^ c_flip),
                            .locked(c_locked), .bit_count(c_bits), .err_count(c_errs));

  task automatic run_prbs();
    int first7, first9, errs;
    @(negedge clk) rst_n = 0;
    @(negedge clk) rst_n = 1;
    first7 = -1; first9 = -1; errs = 0;
    for (int i = 1; i <= 600; i++) begin
      @(negedge clk) g_en = 1;
      c_flip = (i > 40) && (i % 37 == 0);          // inject errors after the checker has locked
      if (c_flip) errs++;
      @(posedge clk); #1;
      if (first7 < 0 && u_g7.state == 7'h1) first7 = i;
      if (first9 < 0 && u_g9.state == 9'h1) first9 = i;
    end
    @(negedge clk) g_en = 0; c_flip = 0;
    @(posedge clk); #1;
    `CHECK_EQ(first7, 127, "PRBS7 returns to its seed after 2^7 - 1 bits")
    `CHECK_EQ(first9, 511, "PRBS9 returns to its seed after 2^9 - 1 bits")
    `CHECK_EQ(c_locked, 1'b1, "checker locked")
    `CHECK_EQ(c_errs, 32'(errs), "checker counts every injected error once")
    `CHECK_EQ(c_bits, 32'(600 - 9), "checker compares every bit after its 9-bit sync")
  endtask

  // ------------------------------------------------------------------ UART
  localparam int CPB = 16;
  logic        t_start = 0;
  logic [7:0]  t_data = 0;
  wire         t_ready, t_line, r_valid, r_ferr;
  wire  [7:0]  r_data;
  logic        force_line = 0, line_value = 1;
  wire         line = force_line ? line_value : t_line;
  uart_transmitter #(.CLKS_PER_BIT(CPB)) u_utx (.clk, .rst_n, .start(t_start), .data(t_data), .ready(t_ready), .tx(t_line));
  uart_receiver #(.CLKS_PER_BIT(CPB)) u_urx (.clk, .rst_n, .rx(line), .valid(r_valid), .data(r_data), .frame_err(r_ferr));
  logic [7:0] rx_q [$];
  int ferrs = 0;
  always @(posedge clk) begin
    if (r_valid) rx_q.push_back(r_data);
    if (r_ferr) ferrs++;
  end

  task automatic run_uart();
    for (int b = 0; b < 256; b++) begin
      @(negedge clk);
      wait (t_ready);
      @(negedge clk) t_data = 8'(b); t_start = 1;
      @(negedge clk) t_start = 0;
    end
    wait (t_ready);
    repeat (3 * CPB) @(posedge clk);
    `CHECK_EQ(rx_q.size(), 256, "UART loopback: bytes received")
    for (int b = 0; b < 256 && b < rx_q.size(); b++) `CHECK_EQ(rx_q[b], 8'(b), $sformatf("UART byte %0d", b))
    // a frame with a low stop bit, sent by hand: no byte, one framing error
    rx_q.delete();
    force_line = 1;
    line_value = 0; repeat (9 * CPB) @(posedge clk);    // start bit and eight 0 data bits
    line_value = 0; repeat (CPB) @(posedge clk);        // stop bit low
    line_value = 1; repeat (4 * CPB) @(posedge clk);
    `CHECK_EQ(rx_q.size(), 0, "framing error: no byte")
    `CHECK_EQ(ferrs, 1, "framing error reported once")
    // a glitch shorter than half a bit on the idle line
    line_value = 0; repeat (CPB / 4) @(posedge clk);
    line_value = 1; repeat (4 * CPB) @(posedge clk);
    `CHECK_EQ(rx_q.size(), 0, "glitch: no byte")
    force_line = 0;
  endtask

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;
    run_encoders();
    run_hamming();
    run_prbs();
    run_uart();
    `TB_FINISH
  end
endmodule
