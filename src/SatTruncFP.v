module SatTruncFP
  #(
    parameter	NB_XI  	= 20,
    parameter	NBF_XI	= 12,
    
    parameter	NB_XO	= 8,
    parameter	NBF_XO	= 6
    )
   (
    input [(NB_XI)-1:0]  i_data,
    output [(NB_XO)-1:0] o_data
    );


//=======================================================
//  PARAMETER declarations
//=======================================================
   localparam	NBI_XI	=	NB_XI	-	NBF_XI;
   localparam	NBI_XO	=	NB_XO	-	NBF_XO;
   
//=======================================================
//  REG/WIRE declarations
//=======================================================
   
   wire [NB_XO-1:0] 	 aux_Sat;
   
   wire [NBF_XO-1:0] 	 aux_trunc;   // Solo se usa/asigna cuando NBF_XO > 0
   
   wire 		 condicion;
   wire [NB_XO-1:0] 	 resultado1;
   wire [NB_XO-1:0] 	 resultado2;

//=======================================================
//  Structural coding
//=======================================================
	generate
	   if (NBF_XO == 0)
	     begin : gen_no_frac_out
		// Caso especial: la salida no tiene bits fraccionarios.
		// Icarus Verilog no soporta bien concatenaciones/slices de
		// ancho cero (ni siquiera {0{1'b0}}), asi que en vez de
		// intentar producir aux_trunc de ancho 0 y concatenarlo,
		// directamente lo omitimos de resultado1/resultado2/aux_Sat.
		if (NBI_XI > NBI_XO)
		  begin : gen_sat_shrink0
		     assign condicion  = (i_data[(NB_XI-2)-:(NBI_XI-NBI_XO)] == {(NBI_XI-NBI_XO){i_data[NB_XI-1]}});
		     assign resultado1 = {i_data[(NB_XI-1)],{(NB_XO-1){~i_data[(NB_XI-1)]}}};
		     assign resultado2 = {i_data[(NB_XI-1)], i_data[NBF_XI +: NBI_XO-1]};
		     assign aux_Sat    = condicion ? resultado2 : resultado1;
		  end
		else if (NBI_XO == NBI_XI)
		  begin : gen_sat_equal0
		     assign aux_Sat = i_data[(NB_XI-1)-:NBI_XI];
		  end
		else
		  begin : gen_sat_extend0
		     assign aux_Sat = {{(NBI_XO - NBI_XI){i_data[NB_XI-1]}}, i_data[(NB_XI-1)-:NBI_XI]};
		  end
	     end
	   else
	     begin : gen_has_frac_out
		// Comportamiento original, sin cambios, para NBF_XO >= 1.
		if (NBF_XI >= NBF_XO)
		  begin : gen_trunc_wide
		     assign aux_trunc = i_data[(NBF_XI-1):(NBF_XI - NBF_XO)];
		  end
		else
		  begin : gen_trunc_narrow
		     assign aux_trunc = {i_data[NBF_XI-1:0],{(NBF_XO - NBF_XI){1'b0}}};
		  end
		if (NBI_XI > NBI_XO)
		  begin : gen_sat_shrink
		     assign condicion  = (i_data[(NB_XI-2)-:(NBI_XI-NBI_XO)] == {(NBI_XI-NBI_XO){i_data[NB_XI-1]}});
		     assign resultado1 = {i_data[(NB_XI-1)],{(NB_XO-1){~i_data[(NB_XI-1)]}}};
		     assign resultado2 = {i_data[(NB_XI-1)], i_data[NBF_XI +:NBI_XO-1], aux_trunc};
		     assign aux_Sat    = condicion ? resultado2 : resultado1;
		  end
		else
		  begin : gen_sat_grow
		     if (NBI_XO == NBI_XI)
		       begin : gen_sat_equal
			  assign  aux_Sat = {i_data[(NB_XI-1)-:NBI_XI],aux_trunc};
		       end
		     else
		       begin : gen_sat_extend
			  assign  aux_Sat	= {{(NBI_XO - NBI_XI){i_data[NB_XI-1]}},i_data[(NB_XI-1)-:NBI_XI],aux_trunc};
		       end
		  end
	     end
	endgenerate
   assign	o_data=aux_Sat;
      
endmodule