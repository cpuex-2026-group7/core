# core_top（backend_top と memory）のテスト（WSL2 の Ubuntu で実行）
#
#   make                ビルドして実行
#   make CYCLES=10000   boot の後に回すサイクル数
#   make lint           テストベンチと RTL を Verilator の -Wall で lint だけする
#   make clean          ビルド結果を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。memory は src/memory/memory_repository/rtl/。
# FPU 担当の演算器は test/eu_3_top/models/ と test/eu_4_top/models/ の代わりを、
# Vivado の IP（clk_wiz_core / fifo_generator_0・1 / mig_7series_0）は models/ip_stubs.sv の代わりを使う。

CYCLES ?= 2000
CXXOPT ?= -Os

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
MEM_DIR  := $(RTL_DIR)/memory/memory_repository/rtl
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/core_top/ はリポジトリ直下の test/ の中に置くこと)
endif
ifeq ($(wildcard $(MEM_DIR)/mem_top.sv),)
  $(error $(MEM_DIR)/mem_top.sv が無い。memory リポジトリを src/memory/memory_repository に clone すること)
endif

# package は使う側より先に読む
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv ooo_types.sv isa.sv uop_types.sv) \
        $(addprefix $(RTL_DIR)/backend/defs/,back_types.sv iq_types.sv rr_types.sv ex_types.sv rob_types.sv lsu_types.sv) \
        $(MEM_DIR)/memory/dram/master_fifo_slave.sv
MODS := core_top async_to_sync \
        backend_top \
        find_empty_slot multi_port_ram age_matrix selector iq_core iq_int iq_mem iq_float iq_top \
        rf_top \
        ex_top \
        eu_0_top eu_0_fu_0_top add sub sra beq blt pc_plus_1_eu_0 br_target \
        eu_1_top eu_1_fu_0_top agu \
        eu_2_top eu_2_fu_0_top fbeq fblt fbr_target fcsign flhi fli pc_plus_1_eu_2 \
        eu_3_top eu_3_fu_0_top eu_3_fu_1_top eu_3_fu_2_top \
        eu_4_top eu_4_fu_0_top eu_4_fu_1_top \
        lsu_top ldq stq lsu_controller lsu_searcher \
        mem_top recv_loader send_loader imem router d_cache dram_buf dram_controller uart_rx uart_tx
# memory リポジトリの archive/ と test/ には同じ名前の古いモジュールがあるので見ない
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' --exclude-dir=archive --exclude-dir=test $(RTL_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS)))
  $(error $(RTL_DIR) 以下で $(MODS) のどれかが見つからないか、2 つ以上ある)
endif

MODELS := $(addprefix $(TEST_DIR)/../eu_3_top/models/,eu_3_model_pkg.sv fmul.sv itof.sv ftoi.sv fadd.sv) \
          $(addprefix $(TEST_DIR)/../eu_4_top/models/,eu_4_model_pkg.sv fsqrt.sv fdiv.sv) \
          $(TEST_DIR)/models/ip_stubs.sv
ifneq ($(words $(wildcard $(MODELS))),$(words $(MODELS)))
  $(error 演算器か IP の代わりが見つからない)
endif

TB := $(TEST_DIR)/tb_core_top.sv

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_core_top -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
          -MAKEFLAGS OPT_FAST=$(CXXOPT) -MAKEFLAGS OPT_SLOW=$(CXXOPT) -MAKEFLAGS OPT_GLOBAL=$(CXXOPT)

.DEFAULT_GOAL := run
.PHONY: run lint clean

run:
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) --Mdir obj_dir $(PKGS) $(MODELS) $(RTL) $(TB) -o Vtb_core_top
	./obj_dir/Vtb_core_top +cycles=$(CYCLES)

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module tb_core_top \
	  $(PKGS) $(MODELS) $(RTL) $(TB)

clean:
	rm -rf obj_dir
