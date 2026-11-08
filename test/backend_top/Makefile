# backend_top（IQ / RR / EX / WB / LSU）のテスト（WSL2 の Ubuntu で実行）
#
#   make                         ビルドして実行
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make lint                    テストベンチと RTL を Verilator の -Wall で lint だけする
#   make clean                   ビルド結果を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。
# FPU 担当の演算器（fmul / itof / ftoi / fadd / fsqrt / fdiv）は、test/eu_3_top/models/ と
# test/eu_4_top/models/ のテスト用の代わりを使う（src/ の同名モジュールは読まない）。

CYCLES ?= 200000
SEED   ?= 1
CXXOPT ?= -Os

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/backend_top/ はリポジトリ直下の test/ の中に置くこと)
endif

# package は使う側より先に読む
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv ooo_types.sv isa.sv uop_types.sv) \
        $(addprefix $(RTL_DIR)/backend/defs/,back_types.sv iq_types.sv rr_types.sv ex_types.sv rob_types.sv lsu_types.sv)
MODS := backend_top \
        find_empty_slot multi_port_ram age_matrix selector iq_core iq_int iq_mem iq_float iq_top \
        rf_top \
        ex_top \
        eu_0_top eu_0_fu_0_top add sub sra beq blt pc_plus_1_eu_0 br_target \
        eu_1_top eu_1_fu_0_top agu \
        eu_2_top eu_2_fu_0_top fbeq fblt fbr_target fcsign flhi fli pc_plus_1_eu_2 \
        eu_3_top eu_3_fu_0_top eu_3_fu_1_top eu_3_fu_2_top \
        eu_4_top eu_4_fu_0_top eu_4_fu_1_top \
        lsu_top ldq stq lsu_controller lsu_searcher
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' $(RTL_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS)))
  $(error $(RTL_DIR) 以下で $(MODS) のどれかが見つからないか、2 つ以上ある)
endif

# 演算器の代わり（eu_3_top / eu_4_top のテストのものをそのまま使う）
MODELS := $(addprefix $(TEST_DIR)/../eu_3_top/models/,eu_3_model_pkg.sv fmul.sv itof.sv ftoi.sv fadd.sv) \
          $(addprefix $(TEST_DIR)/../eu_4_top/models/,eu_4_model_pkg.sv fsqrt.sv fdiv.sv)
ifneq ($(words $(wildcard $(MODELS))),$(words $(MODELS)))
  $(error test/eu_3_top/models/ か test/eu_4_top/models/ の演算器の代わりが見つからない)
endif

TB := $(TEST_DIR)/tb_backend_top.sv

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_backend_top -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
          -MAKEFLAGS OPT_FAST=$(CXXOPT) -MAKEFLAGS OPT_SLOW=$(CXXOPT) -MAKEFLAGS OPT_GLOBAL=$(CXXOPT)

.DEFAULT_GOAL := run
.PHONY: run lint clean

run:
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) --Mdir obj_dir $(PKGS) $(MODELS) $(RTL) $(TB) -o Vtb_backend_top
	./obj_dir/Vtb_backend_top +cycles=$(CYCLES) +seed=$(SEED)

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module tb_backend_top \
	  $(PKGS) $(MODELS) $(RTL) $(TB)

clean:
	rm -rf obj_dir
