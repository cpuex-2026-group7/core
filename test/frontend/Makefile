# Run with `make -C test/frontend` from the repository root (WSL/Linux).
TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(TEST_DIR)/../..)
VERILATOR ?= verilator
BUILD_DIR ?= $(TEST_DIR)/obj_dir

RTL := $(ROOT_DIR)/src/defs/types.sv \
       $(ROOT_DIR)/src/defs/isa.sv \
       $(ROOT_DIR)/src/defs/frontend_defs.sv \
       $(ROOT_DIR)/src/frontend/frontend.sv \
       $(ROOT_DIR)/src/frontend/br_checker.sv \
       $(ROOT_DIR)/src/frontend/br_decoder.sv \
       $(ROOT_DIR)/src/frontend/btb.sv \
       $(ROOT_DIR)/src/frontend/bpd.sv \
       $(ROOT_DIR)/src/frontend/fetchq.sv \
       $(ROOT_DIR)/src/frontend/ftq.sv \
       $(ROOT_DIR)/src/memory/i_mem.sv
SOURCES := $(RTL) $(TEST_DIR)/test_frontend.sv
EXE := $(BUILD_DIR)/Vtest_frontend

.PHONY: test lint
test: $(EXE)
	$(EXE) +imem=$(ROOT_DIR)/test/fib.mem

$(EXE): $(SOURCES) $(TEST_DIR)/Makefile
	$(VERILATOR) --binary --timing --top-module test_frontend \
	  --Mdir "$(BUILD_DIR)" $(SOURCES)

lint:
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
	  -Wno-TIMESCALEMOD --top-module frontend $(RTL)
