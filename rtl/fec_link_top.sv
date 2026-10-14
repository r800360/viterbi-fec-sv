// FEC link with a built-in bit-error-rate tester, controlled over a UART.
//
//   PRBS-15 source -> encoder (selected code) -> channel emulator -> decoder (same code) -> PRBS checker
//
// Codes (CTRL.code): 0 uncoded, 1 K = 3 feed-forward code from the run-time programmable encoder (load G_POLY with
// 7 and 5 for the matching decoder), 2 LTE recursive systematic code (K = 4, 13/15), 3 (8,4) extended Hamming
// SEC-DED. All four send one 2-bit symbol per data bit, so the counters compare them at equal channel conditions
// (uncoded sends {0, bit}; its decoder ignores the first symbol bit).
//
// Host protocol (8N1): a command byte {write, address[6:0]}. A write is followed by 4 data bytes, least significant
// first; a read is answered with 4 bytes, least significant first.
//   0x00 CTRL       [0] run  [2:1] code  [3] clear (write 1: restart the datapath, zero the counters)
//   0x01 CH_CFG     [1:0] mode  [3:2] mask  [31:16] threshold          (see bsc_channel)
//   0x02 CH_PATTERN [15:0] period  [31:16] burst length
//   0x03 CH_HOLDOFF [15:0] clean symbols after a restart (default 256)
//   0x04 CH_SEED    channel random seed (0: a fixed default)
//   0x05 G_POLY     [6:0] polynomial, D^0 in bit 6  [9:8] load generator 1 / 0 of the programmable encoder
//   0x10 BITS, 0x11 ERRORS (checker, counted after lock), 0x12 FLIPS (channel), 0x13 STATUS [0] locked [1] run,
//   0x14 HAM_CORRECTED, 0x15 HAM_DOUBLE, 0x16 UART framing errors, 0x7F ID = "FEC1"
module fec_link_top #(
  parameter int CLKS_PER_BIT = 434,   // 115200 baud from 50 MHz
  parameter int D3 = 32,              // survivor depth of the K = 3 decoder
  parameter int D4 = 40               // survivor depth of the K = 4 decoder
) (
  input  logic clk,
  input  logic rst_n,
  input  logic uart_rx_i,
  output logic uart_tx_o,
  output logic locked_o
);
  // ---------------------------------------------------------------- control registers
  logic        run, clear_pulse;
  logic [1:0]  code;
  logic [31:0] ch_cfg, ch_pattern, ch_seed;
  logic [15:0] ch_holdoff;
  logic [6:0]  g_poly;
  logic [1:0]  g_load;
  logic [31:0] bits, errors, flips, ham_corr, ham_double;
  logic        locked;
  logic [31:0] uart_ferr;

  // ---------------------------------------------------------------- host link
  logic       rx_valid, rx_ferr, tx_ready, tx_start;
  logic [7:0] rx_data, tx_data;
  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (.clk, .rst_n, .rx(uart_rx_i), .valid(rx_valid), .data(rx_data),
                                               .frame_err(rx_ferr));
  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (.clk, .rst_n, .start(tx_start), .data(tx_data), .ready(tx_ready),
                                               .tx(uart_tx_o));

  typedef enum logic [1:0] {H_CMD, H_WDATA, H_RDATA} hstate_t;
  hstate_t     hs;
  logic [6:0]  addr;
  logic [1:0]  nbyte;
  logic [23:0] wbuf;
  logic [31:0] rbuf, wword;
  assign wword = {rx_data, wbuf};   // the complete word when the 4th data byte arrives

  function automatic logic [31:0] read_reg(input logic [6:0] a);
    case (a)
      7'h00:   read_reg = {29'd0, code, run};
      7'h01:   read_reg = ch_cfg;
      7'h02:   read_reg = ch_pattern;
      7'h03:   read_reg = {16'd0, ch_holdoff};
      7'h04:   read_reg = ch_seed;
      7'h10:   read_reg = bits;
      7'h11:   read_reg = errors;
      7'h12:   read_reg = flips;
      7'h13:   read_reg = {30'd0, run, locked};
      7'h14:   read_reg = ham_corr;
      7'h15:   read_reg = ham_double;
      7'h16:   read_reg = uart_ferr;
      7'h7F:   read_reg = 32'h3143_4546;   // "FEC1", least significant byte first
      default: read_reg = 32'd0;
    endcase
  endfunction

  always_ff @(posedge clk)
    if (!rst_n) begin
      hs <= H_CMD; addr <= '0; nbyte <= '0; wbuf <= '0; rbuf <= '0;
      run <= 1'b0; code <= 2'd0; clear_pulse <= 1'b0;
      ch_cfg <= '0; ch_pattern <= '0; ch_holdoff <= 16'd256; ch_seed <= '0;
      g_poly <= '0; g_load <= '0;
      tx_start <= 1'b0; tx_data <= '0; uart_ferr <= '0;
    end else begin
      if (rx_ferr) uart_ferr <= uart_ferr + 1'b1;
      clear_pulse <= 1'b0;
      g_load      <= 2'b00;
      tx_start    <= 1'b0;
      case (hs)
        H_CMD:
          if (rx_valid) begin
            addr  <= rx_data[6:0];
            nbyte <= '0;
            if (rx_data[7]) hs <= H_WDATA;
            else begin
              rbuf <= read_reg(rx_data[6:0]);
              hs   <= H_RDATA;
            end
          end
        H_WDATA:
          if (rx_valid) begin
            wbuf  <= wword[31:8];
            nbyte <= nbyte + 1'b1;
            if (nbyte == 2'd3) begin
              hs <= H_CMD;
              case (addr)
                7'h00: begin run <= wword[0]; code <= wword[2:1]; clear_pulse <= wword[3]; end
                7'h01: ch_cfg     <= wword;
                7'h02: ch_pattern <= wword;
                7'h03: ch_holdoff <= wword[15:0];
                7'h04: ch_seed    <= wword;
                7'h05: begin g_poly <= wword[6:0]; g_load <= wword[9:8]; end
                default: ;
              endcase
            end
          end
        H_RDATA:
          if (tx_ready && !tx_start) begin
            tx_data  <= rbuf[7:0];
            tx_start <= 1'b1;
            rbuf     <= {8'd0, rbuf[31:8]};
            nbyte    <= nbyte + 1'b1;
            if (nbyte == 2'd3) hs <= H_CMD;
          end
        default: hs <= H_CMD;
      endcase
    end

  // ---------------------------------------------------------------- datapath (restarted by CTRL.clear)
  logic dp_rst_n;
  assign dp_rst_n = rst_n && !clear_pulse;

  logic src_valid, src_bit;
  prbs_gen #(.N(15)) u_src (.clk, .rst_n(dp_rst_n), .seed(15'h0001), .en(run), .out_valid(src_valid),
                            .out_bit(src_bit));

  // encoders (all fed; the selected one drives the channel)
  logic       e1_v, e2_v, e3_v;
  logic [1:0] e1_s, e2_s, e3_s;
  conv_encoder_prog #(.KMAX(7)) u_enc_k3 (.clk, .rst_n(dp_rst_n), .load(g_load), .g_in(g_poly),
                                          .in_valid(src_valid), .in_bit(src_bit), .out_valid(e1_v), .out_sym(e1_s));
  conv_encoder #(.K(4), .G0(4'o0), .G1(4'o15), .FB(4'o13)) u_enc_lte (.clk, .rst_n(dp_rst_n),
                                          .in_valid(src_valid), .in_bit(src_bit), .out_valid(e2_v), .out_sym(e2_s));
  hamming84_tx u_enc_ham (.clk, .rst_n(dp_rst_n), .in_valid(src_valid), .in_bit(src_bit), .out_valid(e3_v),
                          .out_sym(e3_s));
  logic       e0_v;
  logic [1:0] e0_s;
  always_ff @(posedge clk)
    if (!dp_rst_n) begin e0_v <= 1'b0; e0_s <= '0; end
    else begin e0_v <= src_valid; e0_s <= {1'b0, src_bit}; end

  logic       tx_v;
  logic [1:0] tx_s;
  always_comb
    case (code)
      2'd0:    begin tx_v = e0_v; tx_s = e0_s; end
      2'd1:    begin tx_v = e1_v; tx_s = e1_s; end
      2'd2:    begin tx_v = e2_v; tx_s = e2_s; end
      default: begin tx_v = e3_v; tx_s = e3_s; end
    endcase

  logic       ch_v;
  logic [1:0] ch_s;
  bsc_channel u_ch (.clk, .rst_n(dp_rst_n), .mode(ch_cfg[1:0]), .thresh(ch_cfg[31:16]), .period(ch_pattern[15:0]),
                    .burst(ch_pattern[31:16]), .mask(ch_cfg[3:2]), .holdoff(ch_holdoff), .seed(ch_seed),
                    .in_valid(tx_v), .in_sym(tx_s), .out_valid(ch_v), .out_sym(ch_s), .flips(flips));

  // decoders
  logic d1_v, d1_b, d2_v, d2_b, d3_v, d3_b;
  viterbi_decoder #(.K(3), .G0(3'o7), .G1(3'o5), .Q(1), .D(D3)) u_dec_k3 (.clk, .rst_n(dp_rst_n),
      .in_valid(ch_v && code == 2'd1), .in_sym0(ch_s[0]), .in_sym1(ch_s[1]), .out_valid(d1_v), .out_bit(d1_b));
  viterbi_decoder #(.K(4), .G0(4'o0), .G1(4'o15), .FB(4'o13), .Q(1), .D(D4)) u_dec_lte (.clk, .rst_n(dp_rst_n),
      .in_valid(ch_v && code == 2'd2), .in_sym0(ch_s[0]), .in_sym1(ch_s[1]), .out_valid(d2_v), .out_bit(d2_b));
  hamming84_rx u_dec_ham (.clk, .rst_n(dp_rst_n), .in_valid(ch_v && code == 2'd3), .in_sym(ch_s),
                          .out_valid(d3_v), .out_bit(d3_b), .corrected_count(ham_corr), .double_count(ham_double));

  logic rx_v, rx_b;
  always_comb
    case (code)
      2'd0:    begin rx_v = ch_v; rx_b = ch_s[0]; end
      2'd1:    begin rx_v = d1_v; rx_b = d1_b; end
      2'd2:    begin rx_v = d2_v; rx_b = d2_b; end
      default: begin rx_v = d3_v; rx_b = d3_b; end
    endcase

  prbs_check #(.N(15)) u_chk (.clk, .rst_n(dp_rst_n), .clear(1'b0), .in_valid(rx_v), .in_bit(rx_b),
                              .locked(locked), .bit_count(bits), .err_count(errors));
  assign locked_o = locked;
endmodule
