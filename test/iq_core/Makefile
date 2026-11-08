# iq_core の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                         決めてある構成を全部ビルドして実行
#   make run_fp                  構成を 1 つだけ（run_<名前>）
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make IQ_CORE=/path/to/x.sv   iq_core.sv の代わりに別のファイルを使う（わざと壊したもので、テストが落ちるかを見る用）
#   make CXXOPT=-O0              g++ の最適化を変える（変えたら作り直す）
#   make lint                    テストベンチと iq_core を Verilator の -Wall で lint だけする
#   make status                  各構成の進捗ログ（log/<名前>.log）の最後の数行を出す
#   make stop                    動いているビルドとテストを止める（残っていないかの確認も兼ねる）
#   make clean                   ビルド結果とログを消す（clean_obj はビルド結果だけ）
#
# 進捗は log/<名前>.log に時刻付きで追記される。ビルドの出力は log/<名前>.build.log に行く。
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。

SHELL := /bin/bash

CYCLES ?= 200000
SEED   ?= 1
CXXOPT ?= -Os

# 構成: SIZE DISPATCH_W ISSUE_W DEST_FU_NUM FU_LISTEN_PORT SLOW_WAKEUP_FU BLOCKING_FU EU_BASE ALLOW_SPLIT_ISSUE（ビット列は 10 進で書く）
#   fp の FU_LISTEN_PORT = 0x911: FU0(F短)->port0, FU1(F長)->port1, FU2(fdiv)/FU3(fsqrt)->port2
#   fp の SLOW / BLOCKING = 0b1100: fdiv と fsqrt
#   FU 番号はテストの中の通し番号。DUT には (EU_BASE+port, port の中で何番目か) にして渡す
#   mem_split* は STA/STD を別々に出す MEM 用の構成
CFG_int    := 16 1 1 1 1 0 0 0 0
CFG_mem    := 16 1 1 1 1 1 0 1 0
CFG_fp     := 16 1 3 4 2321 12 12 2 0
CFG_int_d2 := 16 2 1 1 1 0 0 0 0
CFG_fp_d2  := 16 2 3 4 2321 12 12 2 0
CFG_fp_s4  := 4 2 3 4 2321 12 12 2 0
CFG_int_s2 := 2 1 1 1 1 0 0 0 0
CFG_mem_split    := 16 1 1 1 1 1 0 1 1
CFG_mem_split_d2 := 16 2 1 1 1 1 0 1 1
CFG_mem_split_s4 := 4 2 1 1 1 1 0 1 1
CONFIGS := int mem fp int_d2 fp_d2 fp_s4 int_s2 mem_split mem_split_d2 mem_split_s4

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/iq_core/ はリポジトリ直下の test/ の中に置くこと)
endif

# package は使う側より先に読む
PKGS := $(RTL_DIR)/defs/types.sv $(RTL_DIR)/defs/ooo_types.sv $(RTL_DIR)/defs/isa.sv $(RTL_DIR)/defs/uop_types.sv \
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
LOG_DIR := $(TEST_DIR)/log

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
# g++ の最適化は -O0 / -O1 / -Os でビルド時間がほぼ変わらず、-O0 は実行が 15 倍遅いので -Os（Verilator の既定）にしている
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_iq_core -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
          -MAKEFLAGS OPT_FAST=$(CXXOPT) -MAKEFLAGS OPT_SLOW=$(CXXOPT) -MAKEFLAGS OPT_GLOBAL=$(CXXOPT)

gparams = -GSIZE=$(word 1,$(1)) -GDISPATCH_W=$(word 2,$(1)) -GISSUE_W=$(word 3,$(1)) -GDEST_FU_NUM=$(word 4,$(1)) \
          -GFU_LISTEN_PORT=$(word 5,$(1)) -GSLOW_WAKEUP_FU=$(word 6,$(1)) -GBLOCKING_FU=$(word 7,$(1)) \
          -GEU_BASE=$(word 8,$(1)) -GALLOW_SPLIT_ISSUE=$(word 9,$(1))

.DEFAULT_GOAL := all
# 1 構成のビルドで CPU を使い切る（--build-jobs 0）ので、構成は 1 つずつ回す。
# 並列にすると g++ が倍に増えて取り合い、iq_top では 2 並列で 3 倍遅くなった（2026-11-03 計測）
.NOTPARALLEL:
.PHONY: all lint status stop clean clean_obj $(addprefix run_,$(CONFIGS))

all: $(addprefix run_,$(CONFIGS))

# $(1) を時刻付きで $(2) に追記して画面にも出す
logline = echo "[$$$$(date '+%F %T')] $(1)" | tee -a $(2)

# 前回とビルドオプションが違えば obj_dir を消す（.o が古いオプションのまま使い回されるのを防ぐ）
BUILD_SIG = CXXOPT=$(CXXOPT)
define fresh_objdir
	@if [ -d obj_dir_$(1) ] && [ "$$$$(cat obj_dir_$(1)/.build_sig 2>/dev/null)" != "$(BUILD_SIG)" ]; then rm -rf obj_dir_$(1); fi
endef

define config_rule
run_$(1):
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	@mkdir -p $(LOG_DIR)
	$(call fresh_objdir,$(1))
	@$(call logline,$(1): ビルド開始（$(CFG_$(1))、$(BUILD_SIG)）,$(LOG_DIR)/$(1).log)
	@verilator $(VFLAGS) $(call gparams,$(CFG_$(1))) --Mdir obj_dir_$(1) $(PKGS) $(RTL) $(TB) -o Vtb_iq_core \
	  > $(LOG_DIR)/$(1).build.log 2>&1 || { $(call logline,$(1): ビルド失敗（log/$(1).build.log を見る）,$(LOG_DIR)/$(1).log); exit 1; }
	@echo "$(BUILD_SIG)" > obj_dir_$(1)/.build_sig
	@$(call logline,$(1): ビルド完了、実行開始 cycles=$(CYCLES) seed=$(SEED),$(LOG_DIR)/$(1).log)
	@./obj_dir_$(1)/Vtb_iq_core +cycles=$(CYCLES) +seed=$(SEED) 2>&1 | tee -a $(LOG_DIR)/$(1).log; rc=$$$${PIPESTATUS[0]}; \
	  $(call logline,$(1): 終了 exit=$$$$rc,$(LOG_DIR)/$(1).log); exit $$$$rc
endef
$(foreach c,$(CONFIGS),$(eval $(call config_rule,$(c))))

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM --top-module tb_iq_core \
	  $(call gparams,$(CFG_fp_d2)) $(PKGS) $(RTL) $(TB)

# ビルド中の verilator / g++（引数に Vtb_iq_core を含む）と、テストのバイナリを止める
# [V] にしておくと、このコマンドを走らせているシェル自身には当たらない
stop:
	-pkill -f '[V]tb_iq_core'
	@pgrep -af '[V]tb_iq_core' || echo "動いているビルド・テストは無い"

status:
	@for c in $(CONFIGS); do echo "== $$c"; tail -n 3 $(LOG_DIR)/$$c.log 2>/dev/null || echo "  （ログ無し）"; done

clean:
	rm -rf obj_dir_* $(LOG_DIR)

clean_obj:
	rm -rf obj_dir_*
