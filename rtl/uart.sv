// UART (8 data bits, no parity, 1 stop bit, LSB first) for the host link, and the bit-rate tick generator.

// Clock-enable divider: tick is high for one clk cycle every DIV cycles. The design stays in the clk domain; nothing
// is clocked by a divided clock.
module baud_tick #(parameter int DIV = 434) (
  input  logic clk,
  input  logic rst_n,
  output logic tick
);
  localparam int CW = (DIV > 1) ? $clog2(DIV) : 1;
  localparam int LAST_I = DIV - 1;
  logic [CW-1:0] n;
  always_ff @(posedge clk)
    if (!rst_n) begin
      n    <= '0;
      tick <= 1'b0;
    end else begin
      tick <= (n == LAST_I[CW-1:0]);
      n    <= (n == LAST_I[CW-1:0]) ? '0 : n + 1'b1;
    end
endmodule

// Receiver: Moore FSM, binary-encoded. rx passes a 2-flip-flop synchronizer; the start bit is confirmed half a bit
// after its falling edge, and every following bit (data and stop) is sampled one full bit period later, mid-bit.
// A low stop bit is a framing error: no valid pulse, and the receiver waits for an idle line.
module uart_receiver #(parameter int CLKS_PER_BIT = 434) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rx,
  output logic       valid,       // one cycle, with data
  output logic [7:0] data,        // held until the next good frame
  output logic       frame_err    // one cycle, on a bad stop bit
);
  localparam int CW = $clog2(CLKS_PER_BIT);
  localparam int HALF_I = CLKS_PER_BIT / 2 - 2;   // the synchronizer and edge detection add 2 cycles
  localparam int FULL_I = CLKS_PER_BIT - 1;
  localparam logic [CW-1:0] HALF = HALF_I[CW-1:0];
  localparam logic [CW-1:0] FULL = FULL_I[CW-1:0];

  typedef enum logic [2:0] {WAIT_IDLE, IDLE, START, BITS, STOP} state_t;
  (* syn_encoding = "user" *) state_t state;
  logic [1:0]    sync;
  logic          rx_s;
  logic [CW-1:0] count;
  logic [2:0]    index;
  logic [7:0]    shift;

  assign rx_s = sync[1];

  always_ff @(posedge clk)
    if (!rst_n) begin
      sync      <= 2'b11;
      state     <= WAIT_IDLE;
      count     <= '0;
      index     <= '0;
      shift     <= '0;
      data      <= '0;
      valid     <= 1'b0;
      frame_err <= 1'b0;
    end else begin
      sync      <= {sync[0], rx};
      valid     <= 1'b0;
      frame_err <= 1'b0;
      case (state)
        WAIT_IDLE: if (rx_s) state <= IDLE;
        IDLE:      if (!rx_s) begin state <= START; count <= '0; end
        START:
          if (count == HALF) begin
            count <= '0;
            index <= '0;
            state <= rx_s ? IDLE : BITS;       // high again: a glitch, not a start bit
          end else count <= count + 1'b1;
        BITS:
          if (count == FULL) begin
            count <= '0;
            shift <= {rx_s, shift[7:1]};       // LSB first
            index <= index + 1'b1;
            if (index == 3'd7) state <= STOP;
          end else count <= count + 1'b1;
        STOP:
          if (count == FULL) begin
            count <= '0;
            if (rx_s) begin
              data  <= shift;
              valid <= 1'b1;
              state <= IDLE;
            end else begin
              frame_err <= 1'b1;
              state     <= WAIT_IDLE;
            end
          end else count <= count + 1'b1;
        default: state <= WAIT_IDLE;
      endcase
    end
endmodule

// Transmitter: start bit, 8 data bits LSB first, stop bit. Accepts a byte when ready and start are both high.
module uart_transmitter #(parameter int CLKS_PER_BIT = 434) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       start,
  input  logic [7:0] data,
  output logic       ready,
  output logic       tx
);
  localparam int CW = $clog2(CLKS_PER_BIT);
  localparam int FULL_I = CLKS_PER_BIT - 1;
  localparam logic [CW-1:0] FULL = FULL_I[CW-1:0];
  logic [9:0]    frame;   // {stop, data, start}, shifted out LSB first
  logic [3:0]    left;
  logic [CW-1:0] count;

  assign ready = (left == 0);

  always_ff @(posedge clk)
    if (!rst_n) begin
      frame <= '1;
      left  <= '0;
      count <= '0;
      tx    <= 1'b1;
    end else if (ready) begin
      tx <= 1'b1;
      if (start) begin
        frame <= {1'b1, data, 1'b0};
        left  <= 4'd10;
        count <= '0;
      end
    end else begin
      tx <= frame[0];
      if (count == FULL) begin
        count <= '0;
        frame <= {1'b1, frame[9:1]};
        left  <= left - 1'b1;
      end else count <= count + 1'b1;
    end
endmodule
