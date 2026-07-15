//! @title FIR Filter - 4 taps con selector de coeficientes
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit03 - 4 taps + pipeline + i_filter_sel (vuelta a 4 taps por area)
//!
//! - FIR de 4 coeficientes, pipeline de sumador en 2 niveles.
//! - i_filter_sel[1:0] elige entre 4 bancos de coeficientes (Q1.7, fs = 8000 Hz):
//!     00 -> Pasa-altos   : rechazo 0-1000 Hz    / paso 1500-4000 Hz
//!     01 -> Pasa-bajos   : paso    0-1000 Hz    / rechazo 1500-4000 Hz
//!     10 -> Pasa-todo    : delay/eco con ganancia ~1 (0.99219)
//!     11 -> Notch ~2000Hz: paso 0-1000 y 3000-4000 Hz / rechazo 1500-2500 Hz
//! - Coeficientes generados con scipy.signal.remez (ver design_coeffs.py).
//! - **i_srst** es el reset del sistema.
//! - **i_en** habilita (1) el corrimiento del FIR. En (0) el filtro se detiene sin
//!   modificar el estado actual.

module filtro_fir
  #(
    parameter WW_INPUT  = 8,
    parameter WW_OUTPUT = 8
    )
   (
    input                          clk,
    input                          i_en,
    input                          i_srst,
    input      [1:0]               i_filter_sel, //! Selector de banco de coeficientes
    // Input Stream
    input  signed [WW_INPUT -1:0]  i_data,
    // Output Stream
    output signed [WW_OUTPUT-1:0]  o_data
    );

  // Local Params
  localparam WW_COEFF = 8;

  // Internal Signals
   reg  signed [WW_INPUT           -1:0] register [3:1];
   wire signed [         WW_COEFF  -1:0] coeff    [3:0];
   wire signed [WW_INPUT+WW_COEFF  -1:0] prod     [3:0];
   reg  signed [WW_INPUT+WW_COEFF  -1:0] prod_d   [3:0];
   wire signed [WW_INPUT+WW_COEFF+1-1:0] sum      [2:1];
   reg  signed [WW_INPUT+WW_COEFF+1-1:0] sum_d    [2:1];
   wire signed [WW_INPUT+WW_COEFF+2-1:0] sum2;
   reg  signed [WW_INPUT+WW_COEFF+2-1:0] sum2_d;

  //=======================================================
  //  Bancos de coeficientes (Q1.7), 4 taps, fs = 8000 Hz
  //=======================================================

  // Banco 0: Pasa-altos [-0.70984  0.33019  0.33019 -0.70984]
  wire signed [WW_COEFF-1:0] bank0 [3:0];
  assign bank0[0] = 8'hA5;   // -0.70984
  assign bank0[1] = 8'h2A;   // +0.33019
  assign bank0[2] = 8'h2A;   // +0.33019
  assign bank0[3] = 8'hA5;   // -0.70984

  // Banco 1: Pasa-bajos [0.27593 0.25535 0.25535 0.27593]
  wire signed [WW_COEFF-1:0] bank1 [3:0];
  assign bank1[0] = 8'h23;   // +0.27593
  assign bank1[1] = 8'h21;   // +0.25535
  assign bank1[2] = 8'h21;   // +0.25535
  assign bank1[3] = 8'h23;   // +0.27593

  // Banco 2: Pasa-todo (delay/eco), ganancia ~1: [0.99219 0 0 0]
  wire signed [WW_COEFF-1:0] bank2 [3:0];
  assign bank2[0] = 8'h7F;   // +0.99219
  assign bank2[1] = 8'h00;
  assign bank2[2] = 8'h00;
  assign bank2[3] = 8'h00;

  // Banco 3: Notch ~2000 Hz [-0.26798 0.32316 0.32316 -0.26798]
  wire signed [WW_COEFF-1:0] bank3 [3:0];
  assign bank3[0] = 8'hDE;   // -0.26798
  assign bank3[1] = 8'h29;   // +0.32316
  assign bank3[2] = 8'h29;   // +0.32316
  assign bank3[3] = 8'hDE;   // -0.26798

  // Multiplexado del banco activo segun i_filter_sel
  genvar gc;
  generate
    for (gc = 0; gc < 4; gc = gc + 1) begin : g_sel_coeff
      assign coeff[gc] =
       (i_filter_sel == 2'd0) ? bank0[gc] :
       (i_filter_sel == 2'd1) ? bank1[gc] :
       (i_filter_sel == 2'd2) ? bank2[gc] :
                                bank3[gc];
    end
  endgenerate

  //=======================================================
  //  Datapath (4 taps, pipeline en 2 niveles de suma)
  //=======================================================

  // Shift Register: x[n-1], x[n-2], x[n-3]
  always @(posedge clk) begin
    if (i_srst == 1'b1) begin
      register[1] <= {WW_INPUT{1'b0}};
      register[2] <= {WW_INPUT{1'b0}};
      register[3] <= {WW_INPUT{1'b0}};
    end else begin
      if (i_en == 1'b1) begin
        register[1] <= i_data;
        register[2] <= register[1];
        register[3] <= register[2];
      end
    end
  end

  // Products: coeff[0]*x[n] + coeff[1]*x[n-1] + coeff[2]*x[n-2] + coeff[3]*x[n-3]
  assign prod[0] = coeff[0] * i_data;
  assign prod[1] = coeff[1] * register[1];
  assign prod[2] = coeff[2] * register[2];
  assign prod[3] = coeff[3] * register[3];

  always @(posedge clk) begin
    prod_d[0] <= prod[0];
    prod_d[1] <= prod[1];
    prod_d[2] <= prod[2];
    prod_d[3] <= prod[3];
  end

  // Nivel 1 de suma: 16.12 + 16.12 = 17.12
  assign sum[1] = prod_d[0] + prod_d[1];
  assign sum[2] = prod_d[2] + prod_d[3];

  always @(posedge clk) begin
    sum_d[1] <= sum[1];
    sum_d[2] <= sum[2];
  end

  // Nivel 2 (final): 17.12 + 17.12 = 18.12
  assign sum2 = sum_d[1] + sum_d[2];

  always @(posedge clk)
    sum2_d <= sum2;

  SatTruncFP
    inst_SatTruncFP_dataB
    (
      .i_data ( sum2_d ),
      .o_data ( o_data )
    );

endmodule