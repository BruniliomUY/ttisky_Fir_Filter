`default_nettype none
`timescale 1ns / 1ps

/* This testbench just instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.
*/
module tb ();

  // Dump the signals to a FST file. You can view it with gtkwave or surfer.
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

`ifdef GL_TEST
  // FIX: en simulacion gate-level, las celdas estandar de sky130 (compiladas
  // con USE_POWER_PINS) tienen puertos VPWR/VGND que deben quedar atados a
  // 1/0. Sin esto, esos nodos de alimentacion quedan flotando en X y esa X
  // se propaga a traves de CADA celda del diseño, contaminando toda salida
  // (uo_out, uio_out) incluso despues del reset.
  supply1 VPWR;
  supply0 VGND;
`endif

  tt_um_bruniliomuy_top fir_filter (
`ifdef GL_TEST
      // FIX: en gate-level, el netlist sintetizado con USE_POWER_PINS
      // expone VPWR/VGND como PUERTOS reales del modulo top (el RTL
      // original no los tiene). Hay que conectarlos explicitamente aca:
      // declarar `supply1 VPWR;` sola, sin conectarla como puerto, NO
      // alcanza, porque cada modulo tiene su propio namespace en Verilog.
      .VPWR   (VPWR),
      .VGND   (VGND),
`endif
      .ui_in  (ui_in),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

endmodule