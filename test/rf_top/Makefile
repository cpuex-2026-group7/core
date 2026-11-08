# rf_top の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                         決めてある構成を全部ビルドして実行
#   make run_base                構成を 1 つだけ（run_<名前>）
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make RF_TOP=/path/to/x.sv    rf_top.sv の代わりに別のファイルを使う（わざと壊したもので、テストが落ちるかを見る用）
#   make CXXOPT=-O0              g++ の最適化を変える（変えたら作り直す）
#   make lint                    テストベンチと RTL を Verilator の -Wall で lint だけする
#   make status                  各構成の進捗ログ（log/<名前>.log）の最後の数行を出す
#   make stop                    動いているビルドとテストを止める（残っていないかの確認も兼ねる）
#   make clean                   ビルド結果とログを消す（clean_obj はビルド結果だけ）
#
# 進捗は log/<名前>.log に時刻付きで追記される。ビルドの出力は log/<名前>.build.log に行く。
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。

CYCLES ?= 200000
SEED   ?= 1
CXXOPT ?= -Os

# 構成: I_PREG_NUM F_PREG_NUM BR_UPDATE_W
CFG_base  := 64 64 1
CFG_br2   := 64 64 2
CFG_wide  := 64 64 3
CFG_small := 8 4 2
CFG_mix   := 32 64 1
CONFIGS := base br2 wide small mix

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/rf_top/ はリポジトリ直下の test/ の中に置くこと)
endif

# package は使う側より先に読む
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv ooo_types.sv isa.sv uop_types.sv) \
        $(addprefix $(RTL_DIR)/backend/defs/,back_types.sv iq_types.sv rr_types.sv ex_types.sv rob_types.sv)
MODS := multi_port_ram rf_top
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' $(RTL_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS)))
  $(error $(RTL_DIR) 以下で $(MODS) のどれかが見つからないか、2 つ以上ある)
endif
swap = $(if $(2),$(filter-out $(call find_mod,$(1)),$(3)) $(2),$(3))
RTL := $(call swap,rf_top,$(RF_TOP),$(RTL))

TB := $(TEST_DIR)/tb_rf_top.sv
LOG_DIR := $(TEST_DIR)/log

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
# g++ の最適化は -O0 / -O1 / -Os でビルド時間がほぼ変わらず、-O0 は実行が 15 倍遅いので -Os（Verilator の既定）にしている
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_rf_top -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
          -MAKEFLAGS OPT_FAST=$(CXXOPT) -MAKEFLAGS OPT_SLOW=$(CXXOPT) -MAKEFLAGS OPT_GLOBAL=$(CXXOPT)

gparams = -GI_PREG_NUM=$(word 1,$(1)) -GF_PREG_NUM=$(word 2,$(1)) -GBR_UPDATE_W=$(word 3,$(1))

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
	@verilator $(VFLAGS) $(call gparams,$(CFG_$(1))) --Mdir obj_dir_$(1) $(PKGS) $(RTL) $(TB) -o Vtb_rf_top \
	  > $(LOG_DIR)/$(1).build.log 2>&1 || { $(call logline,$(1): ビルド失敗（log/$(1).build.log を見る）,$(LOG_DIR)/$(1).log); exit 1; }
	@echo "$(BUILD_SIG)" > obj_dir_$(1)/.build_sig
	@$(call logline,$(1): ビルド完了、実行開始 cycles=$(CYCLES) seed=$(SEED),$(LOG_DIR)/$(1).log)
	@./obj_dir_$(1)/Vtb_rf_top +cycles=$(CYCLES) +seed=$(SEED) +log=$(LOG_DIR)/$(1).log; rc=$$$$?; \
	  $(call logline,$(1): 終了 exit=$$$$rc,$(LOG_DIR)/$(1).log); exit $$$$rc
endef
$(foreach c,$(CONFIGS),$(eval $(call config_rule,$(c))))

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM --top-module tb_rf_top \
	  $(call gparams,$(CFG_base)) $(PKGS) $(RTL) $(TB)

# ビルド中の verilator / g++（引数に Vtb_rf_top を含む）と、テストのバイナリを止める
# [V] にしておくと、このコマンドを走らせているシェル自身には当たらない
stop:
	-pkill -f '[V]tb_rf_top'
	@pgrep -af '[V]tb_rf_top' || echo "動いているビルド・テストは無い"

status:
	@for c in $(CONFIGS); do echo "== $$c"; tail -n 3 $(LOG_DIR)/$$c.log 2>/dev/null || echo "  （ログ無し）"; done

clean:
	rm -rf obj_dir_* $(LOG_DIR)

clean_obj:
	rm -rf obj_dir_*
