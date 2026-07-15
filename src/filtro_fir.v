//! @title FIR Filter - 15 taps con selector de coeficientes
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit02 - 15 taps + pipeline + i_filter_sel
//!
//! - Fir filter with 15 coefficients, pipelined adder tree (arquitectura original de 15 taps)
//! - Se agrega i_filter_sel[1:0] para elegir entre 4 bancos de coeficientes:
//!     00 -> Pasa-altos# Diseño del filtro: pasa-bajos de 15 taps
//!        banda de paso: 0 - 1000 Hz
//!        banda de rechazo: 1500 - 4000 Hz
//!     01 -> Pasa-bajos
//!        banda de paso: 0 - 1000 Hz
//!        banda de rechazo: 1500 - 4000 Hz
//!     10 -> Pasa-todo
//!     11 -> Notch
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
   wire signed [WW_INPUT+WW_COEFF+1-1:0] sum      [8:1];
   wire signed [WW_INPUT+WW_COEFF+2-1:0] sum1     [4:1];
   wire signed [WW_INPUT+WW_COEFF+3-1:0] sum2     [2:1];
   wire signed [WW_INPUT+WW_COEFF+4-1:0] sum3;
   reg signed [WW_INPUT+WW_COEFF   -1:0] prod_d   [14:0];
   reg signed [WW_INPUT+WW_COEFF+4 -1:0] sum3_d;
   reg signed [WW_INPUT+WW_COEFF+1 -1:0] sum_d    [8:1];

  //=======================================================
  //  Bancos de coeficientes (Q1.7)
  //=======================================================

  // Banco 0: Pasa-altos / diferenciador aprox. [-1 1/2 -1/4 1/8] "18kHz"
  //          (mismo set que estaba activo en la version original de 15 taps)
  wire signed [WW_COEFF-1:0] bank0 [14:0];
  assign bank0[ 0] = 8'hFF;
  assign bank0[ 1] = 8'h00;
  assign bank0[ 2] = 8'hFF;
  assign bank0[ 3] = 8'h00;
  assign bank0[ 4] = 8'h03;
  assign bank0[ 5] = 8'hF7;
  assign bank0[ 6] = 8'h0D;
  assign bank0[ 7] = 8'h30;
  assign bank0[ 8] = 8'h0D;
  assign bank0[ 9] = 8'hF7;
  assign bank0[10] = 8'h03;
  assign bank0[11] = 8'h00;
  assign bank0[12] = 8'hFF;
  assign bank0[13] = 8'h00;
  assign bank0[14] = 8'hFF;

  // Banco 1: Pasa-bajos / promediador -> 15 coeficientes iguales
  //          8'h08 = 8/128 = 0.0625 ; suma de los 15 = 120/128 = 0.9375
  //          (se eligio 8 en vez de 9 para evitar overshoot/saturacion en el paso)
  wire signed [WW_COEFF-1:0] bank1 [14:0];
  genvar gb1;
  generate
    for (gb1 = 0; gb1 < 15; gb1 = gb1 + 1) begin : g_bank1
      assign bank1[gb1] = 8'h08;
    end
  endgenerate

  // Banco 2: Pasa-todo con ganancia (solo eco/delay) -> [1, 0, 0, ..., 0]
  //          8'h7F = 127/128 = 0.9921875 (maximo positivo representable en Q1.7)
  wire signed [WW_COEFF-1:0] bank2 [14:0];
  assign bank2[0] = 8'h7F;
  genvar gb2;
  generate
    for (gb2 = 1; gb2 < 15; gb2 = gb2 + 1) begin : g_bank2
      assign bank2[gb2] = 8'h00;
    end
  endgenerate
  
  // Banco 3: Ejemplo Notch
  wire signed [WW_COEFF-1:0] bank3 [14:0];
  assign bank3[ 0] = 8'h00;
  assign bank3[ 1] = 8'h00;
  assign bank3[ 2] = 8'hF8;
  assign bank3[ 3] = 8'h00;
  assign bank3[ 4] = 8'h10;
  assign bank3[ 5] = 8'h00;
  assign bank3[ 6] = 8'hE0;
  assign bank3[ 7] = 8'h40;
  assign bank3[ 8] = 8'hE0;
  assign bank3[ 9] = 8'h00;
  assign bank3[10] = 8'h10;
  assign bank3[11] = 8'h00;
  assign bank3[12] = 8'hF8;
  assign bank3[13] = 8'h00;
  assign bank3[14] = 8'h00;
    

  // Multiplexado del banco activo segun i_filter_sel
  // (i_filter_sel == 2'd3 cae por defecto en el banco 2, igual que en la version de 4 taps)
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
  //  Datapath (igual a la version original de 15 taps)
  //=======================================================

  // Shift Register
  always @(posedge clk) begin
    if (i_srst == 1'b1) begin
      register[ 1] <= {WW_INPUT{1'b0}};
      register[ 2] <= {WW_INPUT{1'b0}};
      register[ 3] <= {WW_INPUT{1'b0}};
      register[ 4] <= {WW_INPUT{1'b0}};
      register[ 5] <= {WW_INPUT{1'b0}};
      register[ 6] <= {WW_INPUT{1'b0}};
      register[ 7] <= {WW_INPUT{1'b0}};
      register[ 8] <= {WW_INPUT{1'b0}};
      register[ 9] <= {WW_INPUT{1'b0}};
      register[10] <= {WW_INPUT{1'b0}};
      register[11] <= {WW_INPUT{1'b0}};
      register[12] <= {WW_INPUT{1'b0}};
      register[13] <= {WW_INPUT{1'b0}};
      register[14] <= {WW_INPUT{1'b0}};
    end else begin
      if (i_en == 1'b1) begin
        register[ 1] <= i_data;
        register[ 2] <= register[ 1];
        register[ 3] <= register[ 2];
        register[ 4] <= register[ 3];
        register[ 5] <= register[ 4];
        register[ 6] <= register[ 5];
        register[ 7] <= register[ 6];
        register[ 8] <= register[ 7];
        register[ 9] <= register[ 8];
        register[10] <= register[ 9];
        register[11] <= register[10];
        register[12] <= register[11];
        register[13] <= register[12];
        register[14] <= register[13];
      end
    end
  end

  // Products
  assign prod[ 0] = coeff[ 0] * i_data;
  assign prod[ 1] = coeff[ 1] * register[ 1];
  assign prod[ 2] = coeff[ 2] * register[ 2];
  assign prod[ 3] = coeff[ 3] * register[ 3];
  assign prod[ 4] = coeff[ 4] * register[ 4];
  assign prod[ 5] = coeff[ 5] * register[ 5];
  assign prod[ 6] = coeff[ 6] * register[ 6];
  assign prod[ 7] = coeff[ 7] * register[ 7];
  assign prod[ 8] = coeff[ 8] * register[ 8];
  assign prod[ 9] = coeff[ 9] * register[ 9];
  assign prod[10] = coeff[10] * register[10];
  assign prod[11] = coeff[11] * register[11];
  assign prod[12] = coeff[12] * register[12];
  assign prod[13] = coeff[13] * register[13];
  assign prod[14] = coeff[14] * register[14];

  always @(posedge clk) begin
    prod_d[ 0] <= prod[ 0];
    prod_d[ 1] <= prod[ 1];
    prod_d[ 2] <= prod[ 2];
    prod_d[ 3] <= prod[ 3];
    prod_d[ 4] <= prod[ 4];
    prod_d[ 5] <= prod[ 5];
    prod_d[ 6] <= prod[ 6];
    prod_d[ 7] <= prod[ 7];
    prod_d[ 8] <= prod[ 8];
    prod_d[ 9] <= prod[ 9];
    prod_d[10] <= prod[10];
    prod_d[11] <= prod[11];
    prod_d[12] <= prod[12];
    prod_d[13] <= prod[13];
    prod_d[14] <= prod[14];
  end

  // Adders
  assign sum[ 1] = prod_d[ 0] + prod_d[ 1]; //16.12 + 16.12 = 17.12
  assign sum[ 2] = prod_d[ 2] + prod_d[ 3];

  assign sum[ 3] = prod_d[ 4] + prod_d[ 5];
  assign sum[ 4] = prod_d[ 6] + prod_d[ 7];

  assign sum[ 5] = prod_d[ 8] + prod_d[ 9];
  assign sum[ 6] = prod_d[10] + prod_d[11];

  assign sum[ 7] = prod_d[12] + prod_d[13];
  assign sum[ 8] = {prod_d[14][WW_INPUT+WW_COEFF-1], prod_d[14]};

  always @(posedge clk) begin
    sum_d[1] <= sum[1];
    sum_d[2] <= sum[2];
    sum_d[3] <= sum[3];
    sum_d[4] <= sum[4];
    sum_d[5] <= sum[5];
    sum_d[6] <= sum[6];
    sum_d[7] <= sum[7];
    sum_d[8] <= sum[8];
  end

  assign sum1[ 1] = sum_d[ 1] + sum_d[ 2]; //17.12 + 17.12 = 18.12
  assign sum1[ 2] = sum_d[ 3] + sum_d[ 4];
  assign sum1[ 3] = sum_d[ 5] + sum_d[ 6];
  assign sum1[ 4] = sum_d[ 7] + sum_d[ 8];

  assign sum2[ 1] = sum1[ 1] + sum1[ 2]; //18.12 + 18.12 = 19.12
  assign sum2[ 2] = sum1[ 3] + sum1[ 4];

  assign sum3 = sum2[ 1] + sum2[ 2]; //19.12 + 19.12 = 20.12

  always @(posedge clk)
    sum3_d <= sum3;

  SatTruncFP
    inst_SatTruncFP_dataB
    (
      .i_data ( sum3_d ),
      .o_data ( o_data )
    );

endmodule