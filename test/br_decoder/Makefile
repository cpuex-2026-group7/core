# Run with `make -C test/br_decoder` from the repository root (WSL/Linux).
TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(TEST_DIR)/../..)
VERILATOR ?= verilator

SOURCES := $(ROOT_DIR)/src/defs/types.sv \
           $(ROOT_DIR)/src/defs/isa.sv \
           $(ROOT_DIR)/src/defs/frontend_defs.sv \
           $(ROOT_DIR)/src/core/br_decoder.sv \
           $(TEST_DIR)/test_br_decoder.sv
EXE := $(TEST_DIR)/obj_dir/Vtest_br_decoder

.PHONY: test
test: $(EXE)
	$(EXE)

$(EXE): $(SOURCES) $(TEST_DIR)/Makefile
	$(VERILATOR) --binary --timing --top-module test_br_decoder \
	  --Mdir "$(TEST_DIR)/obj_dir" $(SOURCES)
