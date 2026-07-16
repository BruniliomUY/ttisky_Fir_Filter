//! @title FIR Filter - 15 taps, arquitectura serie (1 MAC)
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit05 - FIR serie: 1 multiplicador reusado x15, en vez de 15 en paralelo
//!
//! - Misma interfaz y mismos 4 bancos que la version paralela (Q1.7, fs=8000 Hz):
//!     00 -> Pasa-altos, 01 -> Pasa-bajos, 10 -> Pasa-banda, 11 -> Pasa-todo
//! - En vez de 15 multiplicadores + arbol de sumas, se usa 1 multiplicador y un
//!   acumulador, recorriendo los 15 taps con una FSM (IDLE -> MAC x15 -> DONE).
//!   Cuesta 17 ciclos de clock de latencia en vez de 5, pero eso sigue siendo
//!   insignificante frente a los ~3125 ciclos que hay entre muestra y muestra
//!   a fs=8000 Hz con clk=25 MHz.
//! - **i_srst** es el reset del sistema.
//! - **i_en** ahora es un PULSO que dispara el comienzo del computo de una
//!   muestra nueva (se ignora si llega mientras la FSM esta ocupada con la
//!   muestra anterior - en la practica nunca deberia pasar con el sample_tick
//!   que ya tenes en el top).

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

  localparam [1:0] S_IDLE = 2'd0,
                    S_MAC  = 2'd1,
                    S_DONE = 2'd2;

  // Internal Signals
  reg  [1:0]                          state;
  reg  [3:0]                          idx;         // recorre los taps 0..14
  reg  signed [WW_INPUT          -1:0] register [14:0]; // register[0]=x[n] .. register[14]=x[n-14]
  reg  signed [WW_INPUT+WW_COEFF+4-1:0] acc;             // acumulador (20 bits)
  reg  signed [WW_INPUT+WW_COEFF+4-1:0] sum_final;       // resultado ya completo -> SatTruncFP

  //=======================================================
  //  Bancos de coeficientes (Q1.7), 15 taps, fs = 8000 Hz
  //  (identicos a la version paralela)
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

  //=======================================================
  //  Selección de coeficiente y muestra para el tap actual (idx)
  //=======================================================

  wire signed [WW_COEFF-1:0] coeff_sel =
       (i_filter_sel == 2'd0) ? bank0[idx] :
       (i_filter_sel == 2'd1) ? bank1[idx] :
       (i_filter_sel == 2'd2) ? bank2[idx] :
                                bank3[idx];

  wire signed [WW_INPUT-1:0] sample_sel = register[idx];

  wire signed [WW_INPUT+WW_COEFF  -1:0] prod     = coeff_sel * sample_sel; // 16 bits
  wire signed [WW_INPUT+WW_COEFF+4-1:0] prod_ext = {{4{prod[WW_INPUT+WW_COEFF-1]}}, prod}; // sign-extend a 20 bits

  //=======================================================
  //  FSM: IDLE (espera i_en) -> MAC x15 -> DONE (latch resultado)
  //=======================================================

  integer r;
  always @(posedge clk) begin
    if (i_srst) begin
      state       <= S_IDLE;
      idx         <= 4'd0;
      acc         <= {(WW_INPUT+WW_COEFF+4){1'b0}};
      sum_final   <= {(WW_INPUT+WW_COEFF+4){1'b0}};
      for (r = 0; r <= 14; r = r + 1)
        register[r] <= {WW_INPUT{1'b0}};
    end else begin
      case (state)

        // Esperando una muestra nueva. Si llega i_en: se corre el shift
        // register (register[0] <= x[n] nuevo, el resto se corre una
        // posicion), y se arranca la FSM de MAC desde idx=0.
        S_IDLE: begin
          if (i_en) begin
            register[0] <= i_data;
            for (r = 1; r <= 14; r = r + 1)
              register[r] <= register[r-1];
            idx   <= 4'd0;
            acc   <= {(WW_INPUT+WW_COEFF+4){1'b0}};
            state <= S_MAC;
          end
        end

        // Un tap por ciclo: acumula coeff[idx]*sample[idx] y avanza idx.
        // Al llegar a idx==14 (ultimo tap) pasa a DONE.
        S_MAC: begin
          acc <= acc + prod_ext;
          if (idx == 4'd14) begin
            state <= S_DONE;
          end else begin
            idx <= idx + 4'd1;
          end
        end

        // El acumulador ya tiene la convolucion completa: se copia a
        // sum_final (que alimenta a SatTruncFP) y se vuelve a IDLE.
        S_DONE: begin
          sum_final <= acc;
          state     <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  SatTruncFP
    inst_SatTruncFP_dataB
    (
      .i_data ( sum_final ),
      .o_data ( o_data )
    );

endmodule