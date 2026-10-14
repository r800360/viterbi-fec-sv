// Channel emulator: flips bits of the 2-bit symbols between encoder and decoder.
//
//   mode 0  clean
//   mode 1  binary symmetric channel: each symbol bit flips with probability thresh / 65536. One xorshift32 draw per
//           symbol; its low half decides bit 0 and its high half bit 1 (model/fec.py Xorshift32 mirrors it)
//   mode 2  periodic: in every block of `period` symbols, the first `burst` symbols get `mask` XORed in
//           (isolated errors, bursts, one or both bits)
// No error is injected during the first `holdoff` symbols after reset, so the receiver's PRBS checker can lock on
// an error-free stretch, as a real link would during its preamble. flips counts every inverted bit.
module bsc_channel (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [1:0]  mode,
  input  logic [15:0] thresh,
  input  logic [15:0] period,
  input  logic [15:0] burst,
  input  logic [1:0]  mask,
  input  logic [15:0] holdoff,
  input  logic [31:0] seed,
  input  logic        in_valid,
  input  logic [1:0]  in_sym,
  output logic        out_valid,
  output logic [1:0]  out_sym,
  output logic [31:0] flips
);
  logic [31:0] x, x1, x2, x3;
  logic [15:0] phase, seen;
  logic [1:0]  err;
  logic        hit0, hit1;

  // one xorshift32 step
  assign x1 = x ^ (x << 13);
  assign x2 = x1 ^ (x1 >> 17);
  assign x3 = x2 ^ (x2 << 5);
  assign hit0 = x3[15:0] < thresh;    // low half decides bit 0
  assign hit1 = x3[31:16] < thresh;   // high half decides bit 1

  always_comb begin
    case (mode)
      2'd1:    err = {hit1, hit0};
      2'd2:    err = (phase < burst) ? mask : 2'b00;
      default: err = 2'b00;
    endcase
    if (seen < holdoff) err = 2'b00;
  end

  always_ff @(posedge clk)
    if (!rst_n) begin
      x         <= (seed == '0) ? 32'h2545_F491 : seed;
      phase     <= '0;
      seen      <= '0;
      flips     <= '0;
      out_valid <= 1'b0;
      out_sym   <= '0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        x       <= x3;
        phase   <= (phase + 1'b1 == period) ? '0 : phase + 1'b1;
        if (seen != 16'hFFFF) seen <= seen + 1'b1;
        out_sym <= in_sym ^ err;
        flips   <= flips + 32'(err[0]) + 32'(err[1]);
      end
    end
endmodule
