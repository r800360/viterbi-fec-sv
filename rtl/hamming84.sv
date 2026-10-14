// (8,4) extended Hamming code, single-error correction and double-error detection (SEC-DED), rate 1/2.
//   data d = {D4, D3, D2, D1};  P4 = D4^D3^D2,  P2 = D4^D3^D1,  P1 = D4^D2^D1;  P0 = XOR of all seven bits
//   codeword {D4, D3, D2, D1, P4, P2, P1, P0}
// Decoding: the syndrome {s4, s2, s1} (received parity XOR recomputed parity) names a single wrong bit; the overall
// parity tells one error (odd) from two (even). Two errors are detected but not corrected.

module hamming84_enc (
  input  logic [3:0] d,
  output logic [7:0] c
);
  logic p4, p2, p1;
  assign p4 = d[3] ^ d[2] ^ d[1];
  assign p2 = d[3] ^ d[2] ^ d[0];
  assign p1 = d[3] ^ d[1] ^ d[0];
  assign c  = {d, p4, p2, p1, ^{d, p4, p2, p1}};
endmodule

module hamming84_dec (
  input  logic [7:0] c,
  output logic [3:0] d,
  output logic       corrected,   // one error, fixed (or only P0 wrong)
  output logic       double_err   // two errors: d is the uncorrected data
);
  logic [2:0] syn;
  logic       odd;
  always_comb begin
    syn = c[3:1] ^ {c[7] ^ c[6] ^ c[5], c[7] ^ c[6] ^ c[4], c[7] ^ c[5] ^ c[4]};
    odd = ^c;
    d   = c[7:4];
    corrected  = 1'b0;
    double_err = 1'b0;
    if (syn != 3'b000 && !odd) double_err = 1'b1;
    else if (syn != 3'b000 || odd) begin
      corrected = 1'b1;
      case (syn)
        3'b111: d[3] = ~c[7];
        3'b110: d[2] = ~c[6];
        3'b101: d[1] = ~c[5];
        3'b011: d[0] = ~c[4];
        default: ;   // a parity bit was wrong; the data is fine
      endcase
    end
  end
endmodule

// Link adapter, transmit side: gathers 4 data bits and sends their codeword as 4 two-bit symbols
// ({D4,D3}, {D2,D1}, {P4,P2}, {P1,P0}; D4 is the first data bit), one symbol per accepted data bit (rate 1/2).
// While one codeword is sent the next is gathered, so the stream starts one block (4 bits) late.
module hamming84_tx (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       in_valid,
  input  logic       in_bit,
  output logic       out_valid,
  output logic [1:0] out_sym
);
  logic [2:0] gather;
  logic [1:0] n;
  logic [7:0] word, cw;
  logic       primed;
  hamming84_enc u_enc (.d({gather, in_bit}), .c(cw));

  always_ff @(posedge clk)
    if (!rst_n) begin
      gather    <= '0;
      n         <= '0;
      word      <= '0;
      primed    <= 1'b0;
      out_valid <= 1'b0;
      out_sym   <= '0;
    end else begin
      out_valid <= in_valid && primed;
      if (in_valid) begin
        gather  <= {gather[1:0], in_bit};
        n       <= n + 1'b1;
        out_sym <= word[7 - 2 * n -: 2];
        if (n == 2'd3) begin
          word   <= cw;
          primed <= 1'b1;
        end
      end
    end
endmodule

// Link adapter, receive side: gathers 4 symbols, decodes the codeword and delivers its 4 data bits, one per symbol.
module hamming84_rx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [1:0]  in_sym,
  output logic        out_valid,
  output logic        out_bit,
  output logic [31:0] corrected_count,
  output logic [31:0] double_count
);
  logic [5:0] gather;
  logic [1:0] n;
  logic [3:0] data;
  logic [3:0] d;
  logic       corr, dbl, primed;
  hamming84_dec u_dec (.c({gather, in_sym}), .d(d), .corrected(corr), .double_err(dbl));

  always_ff @(posedge clk)
    if (!rst_n) begin
      gather <= '0;
      n      <= '0;
      data   <= '0;
      primed <= 1'b0;
      out_valid <= 1'b0;
      out_bit   <= 1'b0;
      corrected_count <= '0;
      double_count    <= '0;
    end else begin
      out_valid <= in_valid && primed;
      if (in_valid) begin
        gather  <= {gather[3:0], in_sym};
        n       <= n + 1'b1;
        out_bit <= data[3 - n];
        if (n == 2'd3) begin
          data   <= d;
          primed <= 1'b1;
          corrected_count <= corrected_count + 32'(corr);
          double_count    <= double_count + 32'(dbl);
        end
      end
    end
endmodule
