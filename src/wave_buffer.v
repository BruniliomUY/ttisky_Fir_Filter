module wave_buffer #(
  parameter DEPTH = 90,   // 1 entrada cada 4 columnas de pantalla (640/4)
  parameter WIDTH = 8
)(
  input                     clk,
  input                     rst_n,
  input                     sample_tick,   // pulso a la tasa de muestreo (i_en del FIR)
  input  signed [WIDTH-1:0] sample_in,     // o_os_data del FIR
  input  [9:0]              hpos,          // columna actual (0..639)
  output signed [WIDTH-1:0] sample_out
);
  reg signed [WIDTH-1:0] mem [0:DEPTH-1];
  reg [7:0] wr_ptr;   // 0..159, cabe en 8 bits

  always @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr <= 0;
    end else if (sample_tick) begin
      mem[wr_ptr] <= sample_in;
      wr_ptr      <= (wr_ptr == DEPTH-1) ? 0 : wr_ptr + 1;
    end
  end

  wire [7:0] col_index  = hpos[9:2];                   // hpos/4 -> 0..159
  wire [8:0] rd_addr_raw = wr_ptr + col_index;
  wire [7:0] rd_addr     = (rd_addr_raw >= DEPTH) ? (rd_addr_raw - DEPTH) : rd_addr_raw[7:0];

  assign sample_out = mem[rd_addr];
endmodule