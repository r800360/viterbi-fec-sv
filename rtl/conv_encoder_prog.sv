// Run-time programmable rate-1/2 feed-forward convolutional encoder (constraint length up to KMAX).
//
// The two generator polynomials are registers, loaded from g_in while load[0] (G0) or load[1] (G1) is high; the bits
// act independently, so load = 11 loads both. Polynomials use the notation of conv_encoder with D^0 in bit KMAX-1:
// a code with K < KMAX occupies the top K bits and leaves zeros below. Example, KMAX = 7 and the K = 3 code (7, 5):
// g0 = 7'b111_0000, g1 = 7'b101_0000.
// The history register holds the last KMAX-1 input bits and advances only on in_valid while no polynomial is being
// loaded, so reprogramming never shifts the history. rst_n clears the history but keeps the polynomials.
module conv_encoder_prog #(
  parameter int KMAX = 7
) (
  input  logic            clk,
  input  logic            rst_n,      // synchronous, active low
  input  logic [1:0]      load,       // bit k loads generator k from g_in
  input  logic [KMAX-1:0] g_in,
  input  logic            in_valid,
  input  logic            in_bit,
  output logic            out_valid,
  output logic [1:0]      out_sym
);
  logic [KMAX-1:0] g0, g1;
  logic [KMAX-2:0] hist;

  always_ff @(posedge clk) begin
    if (load[0]) g0 <= g_in;
    if (load[1]) g1 <= g_in;
  end

  always_ff @(posedge clk)
    if (!rst_n) begin
      hist      <= '0;
      out_valid <= 1'b0;
      out_sym   <= '0;
    end else begin
      out_valid <= in_valid && load == 2'b00;
      if (in_valid && load == 2'b00) begin
        hist    <= {in_bit, hist[KMAX-2:1]};
        out_sym <= {^(g1 & {in_bit, hist}), ^(g0 & {in_bit, hist})};
      end
    end
endmodule
