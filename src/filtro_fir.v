//! @title FIR Filter - 11 taps, arquitectura serie (1 MAC)
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit09 - Bajado de 13 a 11 taps para dejar margen real debajo del
//!           100% (a 100.788% no quedaba nada de colchon para ruteo/CTS).
//!
//! - Mismos 4 bancos que siempre (Q1.7, fs=8000 Hz), re-disenados a 11 taps:
//!     00 -> Pasa-altos : rechazo 0-1000 Hz    / paso 1500-4000 Hz
//!     01 -> Pasa-bajos : paso    0-1000 Hz    / rechazo 1500-4000 Hz
//!     10 -> Pasa-banda : pico ~2.6 kHz (paso 2000-3200 Hz)
//!     11 -> Pasa-todo  : delay/eco, ganancia ~1 (0.99219) - no vive en la ROM
//! - 1 multiplicador + 1 acumulador, reusado 11 veces por muestra (o 1 vez
//!   para el pasa-todo).
//! - **i_srst** es el reset del sistema.
//! - **i_en** es un PULSO que dispara el comienzo del computo de una muestra
//!   nueva (se ignora si llega mientras la FSM esta ocupada con la anterior).

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
  localparam WW_ACC   = WW_INPUT + WW_COEFF + 3;   // 19 bits (alcanza de sobra para 11 taps)

  localparam [1:0] S_IDLE = 2'd0,
                    S_MAC  = 2'd1,
                    S_DONE = 2'd2;

  // Internal Signals
  reg  [1:0]                    state;
  reg  [3:0]                    idx;       // 0..10
  reg  [1:0]                    sel_reg;   // i_filter_sel latcheado al arrancar
  reg  signed [WW_INPUT  -1:0]  register [10:0]; // register[0]=x[n] .. register[10]=x[n-10]
  reg  signed [WW_ACC    -1:0]  acc;
  reg  signed [WW_ACC    -1:0]  sum_final;  // -> SatTruncFP

  //=======================================================
  //  Bancos de coeficientes (Q1.7), 11 taps, fs = 8000 Hz
  //  (el banco pasa-todo NO esta acá: es trivial, se resuelve aparte)
  //=======================================================

  // Banco 0: Pasa-altos (remez, rechazo 0-1000 Hz / paso 1500-4000 Hz)
  wire signed [WW_COEFF-1:0] bank0 [10:0];
  assign bank0[ 0] = 8'h0B;   // +0.08363
  assign bank0[ 1] = 8'h08;   // +0.05997
  assign bank0[ 2] = 8'hFC;   // -0.02809
  assign bank0[ 3] = 8'hEF;   // -0.13543
  assign bank0[ 4] = 8'hDD;   // -0.27082
  assign bank0[ 5] = 8'h59;   // +0.69540
  assign bank0[ 6] = 8'hDD;   // -0.27082
  assign bank0[ 7] = 8'hEF;   // -0.13543
  assign bank0[ 8] = 8'hFC;   // -0.02809
  assign bank0[ 9] = 8'h08;   // +0.05997
  assign bank0[10] = 8'h0B;   // +0.08363

  // Banco 1: Pasa-bajos (remez, paso 0-1000 Hz / rechazo 1500-4000 Hz)
  wire signed [WW_COEFF-1:0] bank1 [10:0];
  assign bank1[ 0] = 8'hF5;   // -0.08363
  assign bank1[ 1] = 8'hF8;   // -0.05997
  assign bank1[ 2] = 8'h04;   // +0.02809
  assign bank1[ 3] = 8'h11;   // +0.13543
  assign bank1[ 4] = 8'h23;   // +0.27082
  assign bank1[ 5] = 8'h27;   // +0.30460
  assign bank1[ 6] = 8'h23;   // +0.27082
  assign bank1[ 7] = 8'h11;   // +0.13543
  assign bank1[ 8] = 8'h04;   // +0.02809
  assign bank1[ 9] = 8'hF8;   // -0.05997
  assign bank1[10] = 8'hF5;   // -0.08363

  // Banco 2: Pasa-banda (pico ~2.6 kHz, paso 2000-3200 Hz)
  wire signed [WW_COEFF-1:0] bank2 [10:0];
  assign bank2[ 0] = 8'h03;   // +0.02325
  assign bank2[ 1] = 8'h01;   // +0.01131
  assign bank2[ 2] = 8'h1B;   // +0.20840
  assign bank2[ 3] = 8'hEA;   // -0.17195
  assign bank2[ 4] = 8'hE7;   // -0.19517
  assign bank2[ 5] = 8'h38;   // +0.44089
  assign bank2[ 6] = 8'hE7;   // -0.19517
  assign bank2[ 7] = 8'hEA;   // -0.17195
  assign bank2[ 8] = 8'h1B;   // +0.20840
  assign bank2[ 9] = 8'h01;   // +0.01131
  assign bank2[10] = 8'h03;   // +0.02325

  // Banco 3: Pasa-todo (delay/eco), ganancia ~1. Es solo 1 tap -> no necesita
  // array ni recorrer los taps, se resuelve aparte (ver is_allpass abajo).
  localparam signed [WW_COEFF-1:0] COEFF_ALLPASS = 8'h7F; // +0.99219

  //=======================================================
  //  Seleccion de coeficiente y muestra para el tap actual (idx)
  //=======================================================

  wire is_allpass       = (sel_reg == 2'd3);
  wire [3:0] last_idx   = is_allpass ? 4'd0 : 4'd10;

  wire signed [WW_COEFF-1:0] coeff_sel =
       is_allpass        ? COEFF_ALLPASS :
       (sel_reg == 2'd0) ? bank0[idx]    :
       (sel_reg == 2'd1) ? bank1[idx]    :
                           bank2[idx];

  wire signed [WW_INPUT-1:0] sample_sel = register[idx];

  wire signed [WW_INPUT+WW_COEFF-1:0] prod     = coeff_sel * sample_sel; // 16 bits
  wire signed [WW_ACC            -1:0] prod_ext = {{(WW_ACC-WW_INPUT-WW_COEFF){prod[WW_INPUT+WW_COEFF-1]}}, prod};

  //=======================================================
  //  FSM: IDLE (espera i_en) -> MAC (11 ciclos, o 1 si es pasa-todo) -> DONE
  //=======================================================

  integer r;
  always @(posedge clk) begin
    if (i_srst) begin
      state     <= S_IDLE;
      idx       <= 4'd0;
      sel_reg   <= 2'd0;
      acc       <= {WW_ACC{1'b0}};
      sum_final <= {WW_ACC{1'b0}};
      for (r = 0; r <= 10; r = r + 1)
        register[r] <= {WW_INPUT{1'b0}};
    end else begin
      case (state)

        // Esperando una muestra nueva. Si llega i_en: se corre el shift
        // register, se latchea el banco activo, y arranca la FSM de MAC.
        S_IDLE: begin
          if (i_en) begin
            register[0] <= i_data;
            for (r = 1; r <= 10; r = r + 1)
              register[r] <= register[r-1];
            sel_reg <= i_filter_sel;
            idx     <= 4'd0;
            acc     <= {WW_ACC{1'b0}};
            state   <= S_MAC;
          end
        end

        // Un tap por ciclo: acumula coeff[idx]*sample[idx] y avanza idx.
        // Para el pasa-todo, last_idx=0, asi que este estado dura 1 ciclo.
        S_MAC: begin
          acc <= acc + prod_ext;
          if (idx == last_idx) begin
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
    #(
      .NB_XI  ( WW_ACC ) // 19 bits (NBF_XI se deja en su default, 12)
      )
    inst_SatTruncFP_dataB
    (
      .i_data ( sum_final ),
      .o_data ( o_data )
    );

endmodule