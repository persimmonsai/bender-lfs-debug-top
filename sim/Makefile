# Options
DUMP ?= 0

# Variables
XRUN = xrun
XRUN_ARGS = -64bit -sv -timescale 1ns/1ps -lwdgen

ifeq ($(DUMP), 1)
	XRUN_ARGS += -access +rwc +DUMP_WAVES
endif

# Source files
SRC_DIR = ../src
TB_DIR = ../tb

SRCS = \
	$(SRC_DIR)/hbm4_pkg.sv \
	$(SRC_DIR)/hbm4_if.sv \
	$(SRC_DIR)/hbm4_model.sv \
	$(SRC_DIR)/hbm4_stack.sv \
	$(SRC_DIR)/hbm4_bfm.sv \
	$(SRC_DIR)/hbm4_trace_decoder.sv \
	$(TB_DIR)/tb_top.sv

# Default target
all: regress

# Run full regression (all tests)
regress:
	$(XRUN) $(XRUN_ARGS) $(SRCS)

# Run specific test via variable
# e.g., make test TEST=test_mrs_config
test:
	$(XRUN) $(XRUN_ARGS) $(SRCS) +TEST=$(TEST)

# Specific test targets
test_mrs_config test_basic_rw_bursts test_timing_ccd test_timing_rtp test_timing_wtr test_random_traffic test_concurrent_traffic test_refresh_mechanics test_hbm3e_controller_timing test_timing_violations:
	$(XRUN) $(XRUN_ARGS) $(SRCS) +TEST=$@

# Clean simulation files
clean:
	rm -rf xcelium.d xrun.history xrun.log waves.shm
