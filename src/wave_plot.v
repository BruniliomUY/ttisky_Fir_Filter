module wave_plot #(
  parameter SCREEN_H = 480
)(
  input  signed [7:0] sample,     // o_os_data del FIR, formato Q1.7
  input        [9:0]  counter_y,  // fila actual que entrega hvsync_generator
  output              pixel_on    // 1 si este pixel pertenece a la traza
);
  localparam CENTER = SCREEN_H/2;        // fila 240, el "cero" de la onda
  localparam signed [15:0] AMPLITUDE = 200; // cuántos pixeles ocupa el rango completo

  wire signed [15:0] sample_ext = {{8{sample[7]}}, sample}; // extiendo signo a 16 bits
  wire signed [15:0] y_offset   = (sample_ext * AMPLITUDE) >>> 7; // Q1.7 -> pixeles
  wire signed [15:0] y_target   = CENTER - y_offset; // en VGA, Y crece hacia abajo

  assign pixel_on = (counter_y >= y_target - 1) && (counter_y <= y_target + 1); // línea de 3px
endmodule
