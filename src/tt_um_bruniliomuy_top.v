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
assign uo_out = {hsync_w, b[0], g[0], r[0], vsync_w, b[1], g[1], r[1]};
assign uio_out = {7'b0, tx_w};
assign uio_oe  = 8'b0000_0001;  // bit 0 como salida, resto como entrada
 // List all unused inputs to prevent warnings
wire _unused = &{uio_in[7:3],uio_in[0], ena, 1'b0};


//fir_filtro
wire signed [7:0] fir_output;
//VGA
wire hsync_w, vsync_w, display_on_w;
wire [9:0] hpos_w, vpos_w;
wire [1:0] r = (display_on_w && pixel_on_w) ? 2'b11 : 2'b00;
wire [1:0] g = r;
wire [1:0] b = r;
//u_wave
wire pixel_on_w;
wire signed [7:0] buffered_sample;

//Timing
//Buffer_timing
localparam integer CLK_HZ  = 25_000_000;
localparam integer SAMPLE_HZ = 8_000; // o el valor que definas
localparam integer DIVIDER = CLK_HZ / SAMPLE_HZ;

reg [11:0] sample_cnt;
wire sample_tick = (sample_cnt == DIVIDER-1);

always @(posedge clk) begin
  if (!rst_n) sample_cnt <= 0;
  else sample_cnt <= sample_tick ? 0 : sample_cnt + 1;
end
//Baud_Rate
localparam integer BAUD = 115200;
localparam integer BAUD_DIVIDER = CLK_HZ / BAUD;

reg [15:0] baud_cnt;
wire baud_tick = (baud_cnt == BAUD_DIVIDER-1);

always @(posedge clk) begin
  if (!rst_n) baud_cnt <= 0;
  else baud_cnt <= baud_tick ? 0 : baud_cnt + 1;
end


filtro_fir u_fir (
  .o_data    (fir_output),      // salida del filtro -> la guardo en este wire
  .i_data    (ui_in),          // entrada del filtro <- viene del pin físico
  .i_filter_sel (uio_in[2:1]), // 2 bits externos eligen el filtro
  .i_en      (sample_tick),           // habilitado siempre
  .i_srst    (!rst_n),         // reset invertido (rst_n es activo en bajo)
  .clk       (clk)
);

hvsync_generator u_vga_timing (
  .clk        (clk),
  .reset      (!rst_n),
  .hsync      (hsync_w),
  .vsync      (vsync_w),
  .display_on (display_on_w),
  .hpos       (hpos_w),
  .vpos       (vpos_w)
);

wave_buffer u_buffer (
  .clk         (clk),
  .rst_n       (rst_n),
  .sample_tick (sample_tick),   // el mismo pulso de tasa de muestreo del FIR
  .sample_in   (fir_output),
  .hpos        (hpos_w),
  .sample_out  (buffered_sample)
);

wave_plot u_wave (
  .sample    (buffered_sample), // antes iba fir_output directo, ahora la versión bufferizada
  .counter_y (vpos_w),
  .pixel_on  (pixel_on_w)
);

wire tx_w, uart_busy_w;
transmitter u_uart (
  .clk       (clk),
  .rst       (!rst_n),
  .wr_en     (sample_tick && !uart_busy_w), // solo si el envío anterior ya terminó
  .baud_tick (baud_tick),
  .data_in   (fir_output),     // la muestra filtrada, sin bufferizar
  .tx        (tx_w),
  .busy      (uart_busy_w)
);
endmodule