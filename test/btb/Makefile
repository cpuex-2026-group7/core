# Run with `make -C test/btb` from the repository root (WSL/Linux).
TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(TEST_DIR)/../..)
VERILATOR ?= verilator

SOURCES := $(ROOT_DIR)/src/defs/types.sv \
           $(ROOT_DIR)/src/defs/frontend_defs.sv \
           $(ROOT_DIR)/src/core/btb.sv \
           $(TEST_DIR)/test_btb.sv
EXE := $(TEST_DIR)/obj_dir/Vtest_btb

.PHONY: test
test: $(EXE)
	cd "$(TEST_DIR)" && ./obj_dir/Vtest_btb

$(EXE): $(SOURCES) $(TEST_DIR)/Makefile
	$(VERILATOR) --binary --timing --trace --top-module test_btb \
	  --Mdir "$(TEST_DIR)/obj_dir" $(SOURCES)
