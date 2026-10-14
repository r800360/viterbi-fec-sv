// Rate-1/2 convolutional encoder, constraint length K: feed-forward or recursive systematic (RSC).
//
// Polynomials are K-bit numbers in the conventional octal notation, most significant bit = D^0:
//   7 = 111 = 1 + D + D^2,   5 = 101 = 1 + D^2,   13 = 1011 = 1 + D^2 + D^3,   15 = 1101 = 1 + D + D^3.
// The register s holds the last K-1 register inputs, newest in s[K-2]; {w, s} lines up with the polynomial bits
// (w is the D^0 term, s[K-2] the D^1 term, ..., s[0] the D^(K-1) term).
//   FB == 0   feed-forward:          w = d,                      out_sym = {^(G1 & {w,s}), ^(G0 & {w,s})}
//   FB != 0   recursive systematic:  w = d ^ ^(FB[K-2:0] & s),   out_sym = {^(G1 & {w,s}), d}
// Examples: G0 = 7, G1 = 5 is the classic K = 3 code; FB = 13, G1 = 15 (K = 4) is the LTE turbo constituent code.
// One symbol per accepted input bit; out_sym and out_valid are registered.
module conv_encoder #(
  parameter int K = 3,
  parameter logic [K-1:0] G0 = 'o7,
  parameter logic [K-1:0] G1 = 'o5,
  parameter logic [K-1:0] FB = '0
) (
  input  logic       clk,
  input  logic       rst_n,      // synchronous, active low: state 0
  input  logic       in_valid,
  input  logic       in_bit,
  output logic       out_valid,
  output logic [1:0] out_sym
);
  logic [K-2:0] s;
  logic         w;
  logic [1:0]   sym;

  always_comb begin
    w = (FB == '0) ? in_bit : in_bit ^ (^(FB[K-2:0] & s));
    if (FB == '0) sym = {^(G1 & {w, s}), ^(G0 & {w, s})};
    else          sym = {^(G1 & {w, s}), in_bit};
  end

  always_ff @(posedge clk)
    if (!rst_n) begin
      s         <= '0;
      out_valid <= 1'b0;
      out_sym   <= '0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        s       <= {w, s[K-2:1]};
        out_sym <= sym;
      end
    end
endmodule
