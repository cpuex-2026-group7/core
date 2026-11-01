# iq_core の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                         決めてある構成を全部ビルドして実行
#   make run_fp                  構成を 1 つだけ（run_<名前>）
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make IQ_CORE=/path/to/x.sv   iq_core.sv の代わりに別のファイルを使う（わざと壊したもので、テストが落ちるかを見る用）
#   make lint                    テストベンチと iq_core を Verilator の -Wall で lint だけする
#   make clean                   ビルド結果を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。

CYCLES ?= 200000
SEED   ?= 1

# 構成: SIZE DISPATCH_W ISSUE_W DEST_FU_NUM FU_LISTEN_PORT SLOW_WAKEUP_FU BLOCKING_FU（ビット列は 10 進で書く）
#   fp の FU_LISTEN_PORT = 0x911: FU0(F短)->port0, FU1(F長)->port1, FU2(fdiv)/FU3(fsqrt)->port2
#   fp の SLOW / BLOCKING = 0b1100: fdiv と fsqrt
CFG_int    := 16 1 1 1 1 0 0
CFG_mem    := 16 1 1 1 1 1 0
CFG_fp     := 16 1 3 4 2321 12 12
CFG_int_d2 := 16 2 1 1 1 0 0
CFG_fp_d2  := 16 2 3 4 2321 12 12
CFG_fp_s4  := 4 2 3 4 2321 12 12
CFG_int_s2 := 2 1 1 1 1 0 0
CONFIGS := int mem fp int_d2 fp_d2 fp_s4 int_s2

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/iq_core/ はリポジトリ直下の test/ の中に置くこと)
endif

# package は使う側より先に読む
PKGS := $(RTL_DIR)/defs/types.sv $(RTL_DIR)/defs/isa.sv $(RTL_DIR)/defs/uop_types.sv \
        $(RTL_DIR)/backend/defs/back_types.sv $(RTL_DIR)/backend/defs/iq_types.sv
MODS := find_empty_slot multi_port_ram age_matrix selector iq_core
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' $(RTL_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS)))
  $(error $(RTL_DIR) 以下で $(MODS) のどれかが見つからないか、2 つ以上ある)
endif
ifneq ($(IQ_CORE),)
  RTL := $(filter-out $(call find_mod,iq_core),$(RTL)) $(IQ_CORE)
endif

TB := $(TEST_DIR)/tb_iq_core.sv

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_iq_core -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND

gparams = -GSIZE=$(word 1,$(1)) -GDISPATCH_W=$(word 2,$(1)) -GISSUE_W=$(word 3,$(1)) -GDEST_FU_NUM=$(word 4,$(1)) \
          -GFU_LISTEN_PORT=$(word 5,$(1)) -GSLOW_WAKEUP_FU=$(word 6,$(1)) -GBLOCKING_FU=$(word 7,$(1))

.DEFAULT_GOAL := all
.PHONY: all lint clean $(addprefix run_,$(CONFIGS))

all: $(addprefix run_,$(CONFIGS))

define config_rule
run_$(1):
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) $(call gparams,$(CFG_$(1))) --Mdir obj_dir_$(1) $(PKGS) $(RTL) $(TB) -o Vtb_iq_core
	./obj_dir_$(1)/Vtb_iq_core +cycles=$(CYCLES) +seed=$(SEED)
endef
$(foreach c,$(CONFIGS),$(eval $(call config_rule,$(c))))

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM --top-module tb_iq_core \
	  $(call gparams,$(CFG_fp_d2)) $(PKGS) $(RTL) $(TB)

clean:
	rm -rf obj_dir_*
