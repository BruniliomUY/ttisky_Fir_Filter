# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info
# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
# Todos los fuentes RTL del proyecto (orden no importa para icarus,
# pero los dejamos en orden jerárquico por claridad)
PROJECT_SOURCES = \
	tt_um_bruniliomuy_top.v \
	filtro_fir.v \
	SatTruncFP.v \
	uart_tx.v
ifneq ($(GATES),yes)
# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
else
# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUSE_POWER_PINS
# FIX: estos apuntaban a ihp-sg13g2 (otro PDK) y despues a nombres de
# archivo que no existian en sky130A. Confirmado por debug en CI que los
# archivos reales son:
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_io/verilog/sky130_ef_io.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
endif
# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)
# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test
# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
