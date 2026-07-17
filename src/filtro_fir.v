//! @title FIR Filter - 15 taps, arquitectura serie (1 MAC)
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit07 - Vuelta a la version serie sin plegar (el plegado costo
//!           mas de lo que ahorro, por duplicar la lectura variable del
//!           shift register). Se mantiene la mejora que SI vale la pena:
//!           el banco pasa-todo (trivial) sale de la ROM combinada.
//!
//! - Mismos 4 bancos que siempre (Q1.7, fs=8000 Hz):
//!     00 -> Pasa-altos, 01 -> Pasa-bajos, 10 -> Pasa-banda, 11 -> Pasa-todo
//! - 1 multiplicador + 1 acumulador, reusado 15 veces por muestra (o 1 vez
//!   para el pasa-todo, que no necesita recorrer los 15 taps).
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
  localparam WW_ACC   = WW_INPUT + WW_COEFF + 3;   // 19 bits (alcanza: peor caso <= 2^18)

  localparam [1:0] S_IDLE = 2'd0,
                    S_MAC  = 2'd1,
                    S_DONE = 2'd2;

  // Internal Signals
  reg  [1:0]                    state;
  reg  [3:0]                    idx;       // 0..14
  reg  [1:0]                    sel_reg;   // i_filter_sel latcheado al arrancar
  reg  signed [WW_INPUT  -1:0]  register [14:0]; // register[0]=x[n] .. register[14]=x[n-14]
  reg  signed [WW_ACC    -1:0]  acc;
  reg  signed [WW_ACC    -1:0]  sum_final;  // -> SatTruncFP

  //=======================================================
  //  Bancos de coeficientes (Q1.7), 15 taps, fs = 8000 Hz
  //  (el banco pasa-todo NO esta acá: es trivial, se resuelve aparte)
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

  // Banco 3: Pasa-todo (delay/eco), ganancia ~1. Es solo 1 tap -> no necesita
  // array ni recorrer los 15 taps, se resuelve aparte (ver is_allpass abajo).
  localparam signed [WW_COEFF-1:0] COEFF_ALLPASS = 8'h7F; // +0.99219

  //=======================================================
  //  Seleccion de coeficiente y muestra para el tap actual (idx)
  //=======================================================

  wire is_allpass       = (sel_reg == 2'd3);
  wire [3:0] last_idx   = is_allpass ? 4'd0 : 4'd14;

  wire signed [WW_COEFF-1:0] coeff_sel =
       is_allpass        ? COEFF_ALLPASS :
       (sel_reg == 2'd0) ? bank0[idx]    :
       (sel_reg == 2'd1) ? bank1[idx]    :
                           bank2[idx];

  wire signed [WW_INPUT-1:0] sample_sel = register[idx];

  wire signed [WW_INPUT+WW_COEFF-1:0] prod     = coeff_sel * sample_sel; // 16 bits
  wire signed [WW_ACC            -1:0] prod_ext = {{(WW_ACC-WW_INPUT-WW_COEFF){prod[WW_INPUT+WW_COEFF-1]}}, prod};

  //=======================================================
  //  FSM: IDLE (espera i_en) -> MAC (15 ciclos, o 1 si es pasa-todo) -> DONE
  //=======================================================

  integer r;
  always @(posedge clk) begin
    if (i_srst) begin
      state     <= S_IDLE;
      idx       <= 4'd0;
      sel_reg   <= 2'd0;
      acc       <= {WW_ACC{1'b0}};
      sum_final <= {WW_ACC{1'b0}};
      for (r = 0; r <= 14; r = r + 1)
        register[r] <= {WW_INPUT{1'b0}};
    end else begin
      case (state)

        // Esperando una muestra nueva. Si llega i_en: se corre el shift
        // register, se latchea el banco activo, y arranca la FSM de MAC.
        S_IDLE: begin
          if (i_en) begin
            register[0] <= i_data;
            for (r = 1; r <= 14; r = r + 1)
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
      .NB_XI  ( WW_ACC ) // 19 bits en vez de 20 (NBF_XI se deja en su default, 12:
                         // el bit que se saco es un bit ENTERO de guarda, no fraccionario)
      )
    inst_SatTruncFP_dataB
    (
      .i_data ( sum_final ),
      .o_data ( o_data )
    );

endmodule