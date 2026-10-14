// PRBS generator and checker: maximal-length Fibonacci LFSRs with the ITU-T O.150 polynomials
// (PRBS7 x^7+x^6+1, PRBS9 x^9+x^5+1, PRBS15 x^15+x^14+1, PRBS23 x^23+x^18+1, PRBS31 x^31+x^28+1).
// The register shifts left and the XOR of the two taps enters bit 0; that bit is the output, so a run of the
// generator produces the whole 2^N - 1 sequence before repeating.

// Taps of a PRBS polynomial, one bit per tap (bit t-1 for the term x^t)
package prbs_pkg;
  function automatic logic [31:0] taps(input int n);
    case (n)
      7:       taps = 32'h0000_0060;   // x^7 + x^6
      9:       taps = 32'h0000_0110;   // x^9 + x^5
      15:      taps = 32'h0000_6000;   // x^15 + x^14
      23:      taps = 32'h0042_0000;   // x^23 + x^18
      default: taps = 32'h4800_0000;   // x^31 + x^28
    endcase
  endfunction
endpackage

module prbs_gen #(parameter int N = 15) (
  input  logic         clk,
  input  logic         rst_n,     // synchronous: state <= seed (a zero seed is replaced by 1)
  input  logic [N-1:0] seed,
  input  logic         en,        // produce one bit
  output logic         out_valid,
  output logic         out_bit
);
  localparam logic [31:0] TAPS32 = prbs_pkg::taps(N);
  localparam logic [N-1:0] TAPS = TAPS32[N-1:0];
  logic [N-1:0] state;
  logic         fb;
  assign fb = ^(state & TAPS);

  always_ff @(posedge clk)
    if (!rst_n) begin
      state     <= (seed == '0) ? N'(1) : seed;
      out_valid <= 1'b0;
      out_bit   <= 1'b0;
    end else begin
      out_valid <= en;
      if (en) begin
        state   <= {state[N-2:0], fb};
        out_bit <= fb;
      end
    end
endmodule

// Checker: the first N received bits are loaded into a local LFSR (sync). From then on the LFSR runs freely and
// predicts every bit; each mismatch is one bit error. Because the prediction no longer depends on the received bits,
// an error is counted exactly once (a self-synchronizing checker would count it once per tap, plus one).
module prbs_check #(parameter int N = 15) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        clear,      // restart: resync and zero the counters
  input  logic        in_valid,
  input  logic        in_bit,
  output logic        locked,
  output logic [31:0] bit_count,  // bits compared since lock
  output logic [31:0] err_count   // mismatches since lock
);
  localparam logic [31:0] TAPS32 = prbs_pkg::taps(N);
  localparam logic [N-1:0] TAPS = TAPS32[N-1:0];
  logic [N-1:0] state;
  localparam int FW = $clog2(N + 1);
  localparam int LAST_I = N - 1;
  logic [FW-1:0] fill;
  logic predicted;
  assign predicted = ^(state & TAPS);

  always_ff @(posedge clk)
    if (!rst_n || clear) begin
      state     <= '0;
      fill      <= '0;
      locked    <= 1'b0;
      bit_count <= '0;
      err_count <= '0;
    end else if (in_valid) begin
      if (!locked) begin
        state <= {state[N-2:0], in_bit};
        fill  <= fill + 1'b1;
        if (fill == LAST_I[FW-1:0]) locked <= 1'b1;
      end else begin
        state     <= {state[N-2:0], predicted};
        bit_count <= bit_count + 1'b1;
        if (predicted != in_bit) err_count <= err_count + 1'b1;
      end
    end
endmodule
