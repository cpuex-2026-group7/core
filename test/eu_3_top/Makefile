# eu_3_top（F長 の EU）の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                         ビルドして実行
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make lint                    テストベンチと RTL を Verilator の -Wall で lint だけする
#   make clean                   ビルド結果を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。
# 演算器（fmul / itof / ftoi / fadd）は FPU 担当の実装ができるまで、models/ のテスト用の代わりを使う。

CYCLES ?= 200000
SEED   ?= 1
CXXOPT ?= -Os

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/eu_3_top/ はリポジトリ直下の test/ の中に置くこと)
endif

# package は使う側より先に読む
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv ooo_types.sv isa.sv uop_types.sv) \
        $(addprefix $(RTL_DIR)/backend/defs/,back_types.sv iq_types.sv rr_types.sv ex_types.sv)
MODS := eu_3_top eu_3_fu_0_top eu_3_fu_1_top eu_3_fu_2_top
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' $(RTL_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS)))
  $(error $(RTL_DIR) 以下で $(MODS) のどれかが見つからないか、2 つ以上ある)
endif

# 演算器の代わり（src/ の同名モジュールは読まない）
MODELS := $(addprefix $(TEST_DIR)/models/,eu_3_model_pkg.sv fmul.sv itof.sv ftoi.sv fadd.sv)

TB := $(TEST_DIR)/tb_eu_3_top.sv

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_eu_3_top -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
          -MAKEFLAGS OPT_FAST=$(CXXOPT) -MAKEFLAGS OPT_SLOW=$(CXXOPT) -MAKEFLAGS OPT_GLOBAL=$(CXXOPT)

.DEFAULT_GOAL := run
.PHONY: run lint clean

run:
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) --Mdir obj_dir $(PKGS) $(MODELS) $(RTL) $(TB) -o Vtb_eu_3_top
	./obj_dir/Vtb_eu_3_top +cycles=$(CYCLES) +seed=$(SEED)

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module tb_eu_3_top \
	  $(PKGS) $(MODELS) $(RTL) $(TB)

clean:
	rm -rf obj_dir
