// tb_link - the whole FEC link, driven only through its UART, as a host would.
// For each scenario: program the channel (and the programmable encoder's polynomials), restart the datapath, run
// for a fixed time, stop, and read the counters back over the UART. Each scenario prints one LINK line with the
// number of source bits and every counter; tools/check_link.py compares them with model/link_model.py, which predicts
// them exactly. The testbench itself checks the protocol (ID register, register read-back) and that each code
// locks and runs.
`timescale 1ns/1ps
`include "tb_util.svh"

module tb_link;
  localparam int CPB = 16;           // UART clocks per bit (fast simulation)
  `TB_COUNTERS
  logic clk = 0, rst_n = 0, host_tx = 1;
  wire  dut_tx, locked;
  always #10 clk = ~clk;             // 50 MHz

  fec_link_top #(.CLKS_PER_BIT(CPB)) dut (.clk(clk), .rst_n(rst_n), .uart_rx_i(host_tx), .uart_tx_o(dut_tx),
                                          .locked_o(locked));

  // host-side receiver (the RTL receiver, tested on its own in tb_blocks)
  wire       h_valid, h_ferr;
  wire [7:0] h_data;
  uart_rx #(.CLKS_PER_BIT(CPB)) host_rx (.clk(clk), .rst_n(rst_n), .rx(dut_tx), .valid(h_valid), .data(h_data),
                                         .frame_err(h_ferr));
  byte unsigned rxq [$];
  always @(posedge clk) if (h_valid) rxq.push_back(h_data);

  // count the source bits (the model needs that number)
  int nsrc = 0;
  always @(posedge clk) if (dut.src_valid) nsrc++;

  task automatic send_byte(input byte unsigned b);
    host_tx = 0; repeat (CPB) @(posedge clk);
    for (int i = 0; i < 8; i++) begin host_tx = b[i]; repeat (CPB) @(posedge clk); end
    host_tx = 1; repeat (2 * CPB) @(posedge clk);
  endtask

  task automatic write_reg(input byte unsigned a, input logic [31:0] v);
    send_byte(8'h80 | a);
    for (int i = 0; i < 4; i++) send_byte(v[8 * i +: 8]);
  endtask

  task automatic read_reg(input byte unsigned a, output logic [31:0] v);
    rxq.delete();
    send_byte(a);
    while (rxq.size() < 4) @(posedge clk);
    v = {rxq[3], rxq[2], rxq[1], rxq[0]};
  endtask

  task automatic scenario(input string name, input int code, input logic [31:0] cfg, input logic [31:0] pattern,
                          input int cycles);
    logic [31:0] b, e, f, hc, hd, st;
    write_reg(8'h01, cfg);
    write_reg(8'h02, pattern);
    write_reg(8'h00, {28'd0, 1'b1, 2'(code), 1'b0});   // clear (datapath restart), stopped
    nsrc = 0;
    write_reg(8'h00, {28'd0, 1'b0, 2'(code), 1'b1});   // run
    repeat (cycles) @(posedge clk);
    write_reg(8'h00, {28'd0, 1'b0, 2'(code), 1'b0});   // stop
    read_reg(8'h10, b);
    read_reg(8'h11, e);
    read_reg(8'h12, f);
    read_reg(8'h14, hc);
    read_reg(8'h15, hd);
    read_reg(8'h13, st);
    `CHECK_EQ(st[0], 1'b1, {name, ": PRBS checker locked"})
    `CHECK(b > 1000, {name, ": checker compared bits"})
    $display("LINK %s code=%0d mode=%0d thresh=%0d mask=%0d period=%0d burst=%0d nsrc=%0d bits=%0d errors=%0d flips=%0d ham_corrected=%0d ham_double=%0d",
             name, code, cfg[1:0], cfg[31:16], cfg[3:2], pattern[15:0], pattern[31:16], nsrc, b, e, f, hc, hd);
  endtask

  logic [31:0] v;
  initial if ($test$plusargs("VCD")) begin
    $dumpfile("tb_link.vcd");
    $dumpvars(1, tb_link);
    $dumpvars(1, tb_link.dut);
    #20000 $dumpoff;          // the first 20 us: the ID read in the timing diagram
  end
  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    read_reg(8'h7F, v);
    `CHECK_EQ(v, 32'h3143_4546, "ID register reads FEC1")
    write_reg(8'h04, 32'h0);              // default channel seed
    read_reg(8'h03, v);
    `CHECK_EQ(v, 32'd256, "holdoff default 256")
    // programmable encoder: generators 7 and 5 (D^0 in bit 6), loaded one at a time
    write_reg(8'h05, {22'd0, 2'b01, 1'b0, 7'b1110000});
    write_reg(8'h05, {22'd0, 2'b10, 1'b0, 7'b1010000});
    // the four codes on the same random channel, p = 1311/65536 = 2 % per bit
    scenario("uncoded_p2",  0, {16'd1311, 12'd0, 2'b00, 2'd1}, 32'd0, 25000);
    scenario("k3_p2",       1, {16'd1311, 12'd0, 2'b00, 2'd1}, 32'd0, 25000);
    scenario("lte_p2",      2, {16'd1311, 12'd0, 2'b00, 2'd1}, 32'd0, 25000);
    scenario("hamming_p2",  3, {16'd1311, 12'd0, 2'b00, 2'd1}, 32'd0, 25000);
    // a harsher channel, p = 5 %
    scenario("k3_p5",       1, {16'd3277, 12'd0, 2'b00, 2'd1}, 32'd0, 25000);
    scenario("lte_p5",      2, {16'd3277, 12'd0, 2'b00, 2'd1}, 32'd0, 25000);
    // fixed patterns: two bad bit[0]s every 16 symbols; four bad bit[1]s every 32; both bits twice every 32
    scenario("k3_pair_b0",  1, {16'd0, 12'd0, 2'b01, 2'd2}, {16'd2, 16'd16}, 20000);
    scenario("lte_burst4_b1", 2, {16'd0, 12'd0, 2'b10, 2'd2}, {16'd4, 16'd32}, 20000);
    scenario("lte_pair_b10",  2, {16'd0, 12'd0, 2'b11, 2'd2}, {16'd2, 16'd32}, 20000);
    scenario("hamming_pair_b10", 3, {16'd0, 12'd0, 2'b11, 2'd2}, {16'd2, 16'd32}, 20000);
    `TB_FINISH
  end
endmodule
