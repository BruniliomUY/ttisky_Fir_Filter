//! @title FIR Filter - 15 taps con selector de coeficientes
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit04 - 15 taps + pipeline + i_filter_sel (vuelta a 15 taps, VGA removido)
//!
//! - FIR de 15 coeficientes, adder tree pipelined en 3 niveles.
//! - i_filter_sel[1:0] elige entre 4 bancos de coeficientes (Q1.7, fs = 8000 Hz):
//!     00 -> Pasa-altos : rechazo 0-1000 Hz    / paso 1500-4000 Hz  (remez, 15 taps)
//!     01 -> Pasa-bajos : paso    0-1000 Hz    / rechazo 1500-4000 Hz (remez, 15 taps)
//!     10 -> Pasa-banda : pico ~2.6 kHz (coeficientes provistos)
//!     11 -> Pasa-todo  : delay/eco con ganancia ~1 (0.99219)
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
   reg  signed [WW_INPUT           -1:0] register [14:1];
   wire signed [         WW_COEFF  -1:0] coeff    [14:0];
   wire signed [WW_INPUT+WW_COEFF  -1:0] prod     [14:0];
   reg  signed [WW_INPUT+WW_COEFF  -1:0] prod_d   [14:0];
   wire signed [WW_INPUT+WW_COEFF+1-1:0] sum      [8:1];
   reg  signed [WW_INPUT+WW_COEFF+1-1:0] sum_d    [8:1];
   wire signed [WW_INPUT+WW_COEFF+2-1:0] sum1     [4:1];
   reg  signed [WW_INPUT+WW_COEFF+2-1:0] sum1_d   [4:1];
   wire signed [WW_INPUT+WW_COEFF+3-1:0] sum2     [2:1];
   reg  signed [WW_INPUT+WW_COEFF+3-1:0] sum2_d   [2:1];
   wire signed [WW_INPUT+WW_COEFF+4-1:0] sum3;
   reg  signed [WW_INPUT+WW_COEFF+4-1:0] sum3_d;

  //=======================================================
  //  Bancos de coeficientes (Q1.7), 15 taps, fs = 8000 Hz
  //=======================================================

  // Banco 0: Pasa-altos (remez, rechazo 0-1000 Hz / paso 1500-4000 Hz)
  wire signed [WW_COEFF-1:0] bank0 [14:0];
  assign bank0[ 0] = 8'hFC;   // -0.03420
  assign bank0[ 1] = 8'h05;   // +0.03639
  assign bank0[ 2] = 8'h08;   // +0.06308
  assign bank0[ 3] = 8'h07;   // +0.05616
  assign bank0[ 4] = 8'hFE;   // -0.01629
  assign bank0[ 5] = 8'hEE;   // -0.14166
  assign bank0[ 6] = 8'hDE;   // -0.26259
  assign bank0[ 7] = 8'h58;   // +0.68728
  assign bank0[ 8] = 8'hDE;   // -0.26259
  assign bank0[ 9] = 8'hEE;   // -0.14166
  assign bank0[10] = 8'hFE;   // -0.01629
  assign bank0[11] = 8'h07;   // +0.05616
  assign bank0[12] = 8'h08;   // +0.06308
  assign bank0[13] = 8'h05;   // +0.03639
  assign bank0[14] = 8'hFC;   // -0.03420

  // Banco 1: Pasa-bajos (remez, paso 0-1000 Hz / rechazo 1500-4000 Hz)
  wire signed [WW_COEFF-1:0] bank1 [14:0];
  assign bank1[ 0] = 8'h04;   // +0.03420
  assign bank1[ 1] = 8'hFB;   // -0.03639
  assign bank1[ 2] = 8'hF8;   // -0.06308
  assign bank1[ 3] = 8'hF9;   // -0.05616
  assign bank1[ 4] = 8'h02;   // +0.01629
  assign bank1[ 5] = 8'h12;   // +0.14166
  assign bank1[ 6] = 8'h22;   // +0.26259
  assign bank1[ 7] = 8'h28;   // +0.31272
  assign bank1[ 8] = 8'h22;   // +0.26259
  assign bank1[ 9] = 8'h12;   // +0.14166
  assign bank1[10] = 8'h02;   // +0.01629
  assign bank1[11] = 8'hF9;   // -0.05616
  assign bank1[12] = 8'hF8;   // -0.06308
  assign bank1[13] = 8'hFB;   // -0.03639
  assign bank1[14] = 8'h04;   // +0.03420

  // Banco 2: Pasa-banda (pico ~2.6 kHz)
  wire signed [WW_COEFF-1:0] bank2 [14:0];
  assign bank2[ 0] = 8'h00;
  assign bank2[ 1] = 8'h00;
  assign bank2[ 2] = 8'hF8;
  assign bank2[ 3] = 8'h00;
  assign bank2[ 4] = 8'h10;
  assign bank2[ 5] = 8'h00;
  assign bank2[ 6] = 8'hE0;
  assign bank2[ 7] = 8'h40;
  assign bank2[ 8] = 8'hE0;
  assign bank2[ 9] = 8'h00;
  assign bank2[10] = 8'h10;
  assign bank2[11] = 8'h00;
  assign bank2[12] = 8'hF8;
  assign bank2[13] = 8'h00;
  assign bank2[14] = 8'h00;

  // Banco 3: Pasa-todo (delay/eco), ganancia ~1: [0.99219 0 0 ... 0]
  wire signed [WW_COEFF-1:0] bank3 [14:0];
  assign bank3[ 0] = 8'h7F;   // +0.99219
  assign bank3[ 1] = 8'h00;
  assign bank3[ 2] = 8'h00;
  assign bank3[ 3] = 8'h00;
  assign bank3[ 4] = 8'h00;
  assign bank3[ 5] = 8'h00;
  assign bank3[ 6] = 8'h00;
  assign bank3[ 7] = 8'h00;
  assign bank3[ 8] = 8'h00;
  assign bank3[ 9] = 8'h00;
  assign bank3[10] = 8'h00;
  assign bank3[11] = 8'h00;
  assign bank3[12] = 8'h00;
  assign bank3[13] = 8'h00;
  assign bank3[14] = 8'h00;

  // Multiplexado del banco activo segun i_filter_sel
  genvar gc;
  generate
    for (gc = 0; gc < 15; gc = gc + 1) begin : g_sel_coeff
      assign coeff[gc] =
       (i_filter_sel == 2'd0) ? bank0[gc] :
       (i_filter_sel == 2'd1) ? bank1[gc] :
       (i_filter_sel == 2'd2) ? bank2[gc] :
                                bank3[gc];
    end
  endgenerate

  //=======================================================
  //  Datapath (15 taps, adder tree pipelined en 3 niveles)
  //=======================================================

  // Shift Register: x[n-1] .. x[n-14]
  integer i;
  always @(posedge clk) begin
    if (i_srst == 1'b1) begin
      for (i = 1; i <= 14; i = i + 1)
        register[i] <= {WW_INPUT{1'b0}};
    end else begin
      if (i_en == 1'b1) begin
        register[1] <= i_data;
        for (i = 2; i <= 14; i = i + 1)
          register[i] <= register[i-1];
      end
    end
  end

  // Products
  assign prod[0] = coeff[0] * i_data;
  generate
    genvar gp;
    for (gp = 1; gp <= 14; gp = gp + 1) begin : g_prod
      assign prod[gp] = coeff[gp] * register[gp];
    end
  endgenerate

  always @(posedge clk) begin
    integer j;
    for (j = 0; j <= 14; j = j + 1)
      prod_d[j] <= prod[j];
  end

  // Nivel 1: 14 productos en 7 pares (16.12+16.12=17.12) + el tap 14 solo, sign-extendido
  assign sum[1] = prod_d[ 0] + prod_d[ 1];
  assign sum[2] = prod_d[ 2] + prod_d[ 3];
  assign sum[3] = prod_d[ 4] + prod_d[ 5];
  assign sum[4] = prod_d[ 6] + prod_d[ 7];
  assign sum[5] = prod_d[ 8] + prod_d[ 9];
  assign sum[6] = prod_d[10] + prod_d[11];
  assign sum[7] = prod_d[12] + prod_d[13];
  assign sum[8] = {prod_d[14][WW_INPUT+WW_COEFF-1], prod_d[14]};

  always @(posedge clk) begin
    integer k;
    for (k = 1; k <= 8; k = k + 1)
      sum_d[k] <= sum[k];
  end

  // Nivel 2: 17.12 + 17.12 = 18.12
  assign sum1[1] = sum_d[1] + sum_d[2];
  assign sum1[2] = sum_d[3] + sum_d[4];
  assign sum1[3] = sum_d[5] + sum_d[6];
  assign sum1[4] = sum_d[7] + sum_d[8];

  always @(posedge clk) begin
    integer m;
    for (m = 1; m <= 4; m = m + 1)
      sum1_d[m] <= sum1[m];
  end

  // Nivel 3: 18.12 + 18.12 = 19.12
  assign sum2[1] = sum1_d[1] + sum1_d[2];
  assign sum2[2] = sum1_d[3] + sum1_d[4];

  always @(posedge clk) begin
    sum2_d[1] <= sum2[1];
    sum2_d[2] <= sum2[2];
  end

  // Final: 19.12 + 19.12 = 20.12
  assign sum3 = sum2_d[1] + sum2_d[2];

  always @(posedge clk)
    sum3_d <= sum3;

  SatTruncFP
    inst_SatTruncFP_dataB
    (
      .i_data ( sum3_d ),
      .o_data ( o_data )
    );

endmodule