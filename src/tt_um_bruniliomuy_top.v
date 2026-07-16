/*
 * Copyright (c) 2024 Bruno_Moreira
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_bruniliomuy_top (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

// VGA removido por area (ver notas del proyecto). Solo queda FIR + UART.
// uo_out ahora expone directamente la muestra filtrada (8 bits), por si alguien
// quiere leerla con un logic analyzer sin pasar por UART.
assign uo_out  = fir_output;
assign uio_out = {7'b0, tx_w};
assign uio_oe  = 8'b0000_0001;  // bit 0 como salida, resto como entrada

// List all unused inputs to prevent warnings
wire _unused = &{uio_in[7:3], uio_in[0], ena, 1'b0};

//fir_filtro
wire signed [7:0] fir_output;

//Timing
//Buffer_timing
localparam integer CLK_HZ    = 25_000_000;
localparam integer SAMPLE_HZ = 8_000; // debe coincidir con lo asumido en filtro_fir/testbenches
localparam [11:0]  DIVIDER   = CLK_HZ / SAMPLE_HZ;

reg [11:0] sample_cnt;
wire sample_tick = (sample_cnt == DIVIDER-12'd1);

always @(posedge clk) begin
  if (!rst_n) sample_cnt <= 0;
  else sample_cnt <= sample_tick ? 0 : sample_cnt + 1;
end

//Baud_Rate
localparam integer BAUD         = 115200;
localparam [15:0]  BAUD_DIVIDER = CLK_HZ / BAUD;

reg [15:0] baud_cnt;
wire baud_tick = (baud_cnt == BAUD_DIVIDER-16'd1);

always @(posedge clk) begin
  if (!rst_n) baud_cnt <= 0;
  else baud_cnt <= baud_tick ? 0 : baud_cnt + 1;
end

filtro_fir u_fir (
  .o_data       (fir_output),      // salida del filtro
  .i_data       (ui_in),           // entrada del filtro <- viene del pin fisico
  .i_filter_sel (uio_in[2:1]),     // 2 bits externos eligen el banco de filtro
  .i_en         (sample_tick),
  .i_srst       (!rst_n),          // reset invertido (rst_n es activo en bajo)
  .clk          (clk)
);

wire tx_w, uart_busy_w;
transmitter u_uart (
  .clk       (clk),
  .rst       (!rst_n),
  .wr_en     (sample_tick && !uart_busy_w), // solo si el envio anterior ya termino
  .baud_tick (baud_tick),
  .data_in   (fir_output),         // la muestra filtrada
  .tx        (tx_w),
  .busy      (uart_busy_w)
);

endmodule