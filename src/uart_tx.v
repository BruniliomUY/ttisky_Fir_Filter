module transmitter (
  input            clk,
  input            rst,
  input            wr_en,     // pulso: "transmití data_in ahora"
  input            baud_tick, // pulso a la tasa de baudios, avanza 1 bit
  input      [7:0] data_in,
  output reg       tx,
  output           busy
);
  localparam IDLE = 2'b00, START = 2'b01, DATA = 2'b10, STOP = 2'b11;

  reg [1:0] state;
  reg [7:0] data;
  reg [2:0] bit_idx;

  always @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      tx    <= 1'b1;
    end else begin
      
        IDLE: begin
          tx <= 1'b1;
          if (wr_en) begin
            data    <= data_in;
            bit_idx <= 3'd0;
            state   <= START;
          end
        end
        START: if (baud_tick) begin
          tx    <= 1'b0;      // bit de start
          state <= DATA;
        end
        DATA: if (baud_tick) begin
          tx <= data[bit_idx];
          if (bit_idx == 3'd7)
            state <= STOP;
          else
            bit_idx <= bit_idx + 3'd1;
        end
        STOP: if (baud_tick) begin
          tx    <= 1'b1;      // bit de stop
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end

  assign busy = (state != IDLE);
endmodule