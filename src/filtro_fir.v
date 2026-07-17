//! @title FIR Filter - 15 taps, arquitectura serie plegada (folded FIR)
//! @file filtro_fir.v
//! @author  Bruno Moreira
//! @date 2026
//! @version Unit06 - Explota la simetria de fase lineal para bajar de 8 a 8
//!           multiplicaciones-ciclo por muestra (en vez de 15), y reduce la
//!           ROM de coeficientes de 60 a 24+1 entradas.
//!
//! - Los bancos 0/1/2 (pasa-altos, pasa-bajos, pasa-banda) son de fase lineal:
//!   h[k] = h[14-k]. Eso permite sumar x[n-k]+x[n-(14-k)] ANTES de multiplicar
//!   y usar un solo coeficiente para ese par -> 8 ciclos de MAC en vez de 15,
//!   y solo 8 coeficientes guardados por banco en vez de 15.
//! - El banco 3 (pasa-todo) NO es simetrico (es un delay puro), asi que se
//!   maneja aparte: 1 solo ciclo de MAC, sin plegado.
//! - Mismos 4 bancos / mismas frecuencias que la version anterior, Q1.7, fs=8000 Hz:
//!     00 -> Pasa-altos, 01 -> Pasa-bajos, 10 -> Pasa-banda, 11 -> Pasa-todo
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
  localparam WW_OPER  = WW_INPUT + 1;              // 9 bits: cabe x[n-k]+x[n-(14-k)]
  localparam WW_PROD  = WW_COEFF + WW_OPER;        // 17 bits
  localparam WW_ACC   = WW_INPUT + WW_COEFF + 4;   // 20 bits (igual que la version sin plegar)

  localparam [1:0] S_IDLE = 2'd0,
                    S_MAC  = 2'd1,
                    S_DONE = 2'd2;

  // Internal Signals
  reg  [1:0]                     state;
  reg  [2:0]                     idxf;        // 0..7: indice plegado
  reg  [1:0]                     sel_reg;     // i_filter_sel latcheado al arrancar
  reg  signed [WW_INPUT   -1:0]  register [14:0]; // x[n] .. x[n-14]
  reg  signed [WW_ACC     -1:0]  acc;
  reg  signed [WW_ACC     -1:0]  sum_final;   // -> SatTruncFP

  //=======================================================
  //  Bancos plegados (Q1.7): solo 8 coeficientes por banco simetrico
  //  (indices 0..6 = mitad del par, indice 7 = tap central, sin pareja)
  //=======================================================

  // Banco 0: Pasa-altos (remez, rechazo 0-1000 Hz / paso 1500-4000 Hz)
  wire signed [WW_COEFF-1:0] bank0f [7:0];
  assign bank0f[0] = 8'hFC;   // -0.03420
  assign bank0f[1] = 8'h05;   // +0.03639
  assign bank0f[2] = 8'h08;   // +0.06308
  assign bank0f[3] = 8'h07;   // +0.05616
  assign bank0f[4] = 8'hFE;   // -0.01629
  assign bank0f[5] = 8'hEE;   // -0.14166
  assign bank0f[6] = 8'hDE;   // -0.26259
  assign bank0f[7] = 8'h58;   // +0.68728 (tap central, sin pareja)

  // Banco 1: Pasa-bajos (remez, paso 0-1000 Hz / rechazo 1500-4000 Hz)
  wire signed [WW_COEFF-1:0] bank1f [7:0];
  assign bank1f[0] = 8'h04;   // +0.03420
  assign bank1f[1] = 8'hFB;   // -0.03639
  assign bank1f[2] = 8'hF8;   // -0.06308
  assign bank1f[3] = 8'hF9;   // -0.05616
  assign bank1f[4] = 8'h02;   // +0.01629
  assign bank1f[5] = 8'h12;   // +0.14166
  assign bank1f[6] = 8'h22;   // +0.26259
  assign bank1f[7] = 8'h28;   // +0.31272 (tap central, sin pareja)

  // Banco 2: Pasa-banda (pico ~2.6 kHz)
  wire signed [WW_COEFF-1:0] bank2f [7:0];
  assign bank2f[0] = 8'h00;
  assign bank2f[1] = 8'h00;
  assign bank2f[2] = 8'hF8;
  assign bank2f[3] = 8'h00;
  assign bank2f[4] = 8'h10;
  assign bank2f[5] = 8'h00;
  assign bank2f[6] = 8'hE0;
  assign bank2f[7] = 8'h40;   // tap central, sin pareja

  // Banco 3: Pasa-todo (delay/eco), ganancia ~1: solo el tap 0 vale, no es simetrico
  localparam signed [WW_COEFF-1:0] COEFF_ALLPASS = 8'h7F; // +0.99219

  //=======================================================
  //  Seleccion de operando y coeficiente para el paso plegado actual (idxf)
  //=======================================================

  wire is_allpass = (sel_reg == 2'd3);
  wire [2:0] last_idx = is_allpass ? 3'd0 : 3'd7;

  // Operando: para bancos simetricos, x[n-idxf] + x[n-(14-idxf)] (excepto el
  // tap central idxf==7, que no tiene pareja). Para el pasa-todo, es x[n] solo.
  wire signed [WW_OPER-1:0] operand_sym =
       (idxf == 3'd7) ? {register[7][WW_INPUT-1], register[7]} :
                         (register[idxf] + register[14-idxf]);
  wire signed [WW_OPER-1:0] operand_ap  = {register[0][WW_INPUT-1], register[0]};
  wire signed [WW_OPER-1:0] operand_sel = is_allpass ? operand_ap : operand_sym;

  wire signed [WW_COEFF-1:0] coeff_sel =
       is_allpass                ? COEFF_ALLPASS :
       (sel_reg == 2'd0)         ? bank0f[idxf]   :
       (sel_reg == 2'd1)         ? bank1f[idxf]   :
                                   bank2f[idxf];

  wire signed [WW_PROD-1:0] prod     = coeff_sel * operand_sel;
  wire signed [WW_ACC -1:0] prod_ext = {{(WW_ACC-WW_PROD){prod[WW_PROD-1]}}, prod};

  //=======================================================
  //  FSM: IDLE (espera i_en) -> MAC (8 ciclos, o 1 si es pasa-todo) -> DONE
  //=======================================================

  integer r;
  always @(posedge clk) begin
    if (i_srst) begin
      state     <= S_IDLE;
      idxf      <= 3'd0;
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
            idxf    <= 3'd0;
            acc     <= {WW_ACC{1'b0}};
            state   <= S_MAC;
          end
        end

        // Un paso plegado por ciclo: acumula coeff[idxf]*operand[idxf].
        // Para bancos simetricos son 8 pasos (idxf 0..7); para el pasa-todo
        // es 1 solo paso (idxf siempre 0, last_idx=0).
        S_MAC: begin
          acc <= acc + prod_ext;
          if (idxf == last_idx) begin
            state <= S_DONE;
          end else begin
            idxf <= idxf + 3'd1;
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