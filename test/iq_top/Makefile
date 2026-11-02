# iq_top の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                         決めてある構成を全部ビルドして実行
#   make run_base                構成を 1 つだけ（run_<名前>）
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make IQ_TOP=/path/to/x.sv    iq_top.sv の代わりに別のファイルを使う（わざと壊したもので、テストが落ちるかを見る用）
#                                IQ_CORE / IQ_INT / IQ_MEM / IQ_FLOAT も同じように差し替えられる
#   make lint                    テストベンチと RTL を Verilator の -Wall で lint だけする
#   make status                  各構成の進捗ログ（log/<名前>.log）の最後の数行を出す
#   make stop                    動いているテストのバイナリを止める（残っていないかの確認も兼ねる）
#   make clean                   ビルド結果とログを消す
#
# 進捗は log/<名前>.log に時刻付きで追記される（ビルド開始・完了、各テストの結果、ランダムの進み具合、終了コード）。
# ビルドの出力は log/<名前>.build.log に行く。
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。

CYCLES ?= 200000
SEED   ?= 1

# 構成: SIZE_INT SIZE_MEM SIZE_FPU DW_INT DW_MEM DW_FPU WAKEUP_W BR_UPDATE_W
CFG_base  := 16 16 16 1 1 1 2 1
CFG_d2    := 16 16 16 2 2 2 2 1
CFG_small := 4 2 4 2 1 2 2 1
CFG_br2   := 8 8 8 1 2 1 3 2
CFG_mix   := 16 4 8 2 1 2 3 1
CFG_tiny  := 2 2 2 1 1 1 2 1
CONFIGS := base d2 small br2 mix tiny

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/iq_top/ はリポジトリ直下の test/ の中に置くこと)
endif

# package は使う側より先に読む
PKGS := $(RTL_DIR)/defs/types.sv $(RTL_DIR)/defs/ooo_types.sv $(RTL_DIR)/defs/isa.sv $(RTL_DIR)/defs/uop_types.sv \
        $(RTL_DIR)/backend/defs/back_types.sv $(RTL_DIR)/backend/defs/iq_types.sv
MODS := find_empty_slot multi_port_ram age_matrix selector iq_core iq_int iq_mem iq_float iq_top
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' $(RTL_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS)))
  $(error $(RTL_DIR) 以下で $(MODS) のどれかが見つからないか、2 つ以上ある)
endif
swap = $(if $(2),$(filter-out $(call find_mod,$(1)),$(3)) $(2),$(3))
RTL := $(call swap,iq_top,$(IQ_TOP),$(RTL))
RTL := $(call swap,iq_core,$(IQ_CORE),$(RTL))
RTL := $(call swap,iq_int,$(IQ_INT),$(RTL))
RTL := $(call swap,iq_mem,$(IQ_MEM),$(RTL))
RTL := $(call swap,iq_float,$(IQ_FLOAT),$(RTL))

TB := $(TEST_DIR)/tb_iq_top.sv
LOG_DIR := $(TEST_DIR)/log

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_iq_top -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND

gparams = -GSIZE_INT=$(word 1,$(1)) -GSIZE_MEM=$(word 2,$(1)) -GSIZE_FPU=$(word 3,$(1)) -GDW_INT=$(word 4,$(1)) \
          -GDW_MEM=$(word 5,$(1)) -GDW_FPU=$(word 6,$(1)) -GWAKEUP_W=$(word 7,$(1)) -GBR_UPDATE_W=$(word 8,$(1))

.DEFAULT_GOAL := all
.PHONY: all lint status stop clean $(addprefix run_,$(CONFIGS))

all: $(addprefix run_,$(CONFIGS))

# $(1) を時刻付きで $(2) に追記して画面にも出す
logline = echo "[$$$$(date '+%F %T')] $(1)" | tee -a $(2)

define config_rule
run_$(1):
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	@mkdir -p $(LOG_DIR)
	@$(call logline,$(1): ビルド開始（$(CFG_$(1))）,$(LOG_DIR)/$(1).log)
	@verilator $(VFLAGS) $(call gparams,$(CFG_$(1))) --Mdir obj_dir_$(1) $(PKGS) $(RTL) $(TB) -o Vtb_iq_top \
	  > $(LOG_DIR)/$(1).build.log 2>&1 || { $(call logline,$(1): ビルド失敗（log/$(1).build.log を見る）,$(LOG_DIR)/$(1).log); exit 1; }
	@$(call logline,$(1): ビルド完了、実行開始 cycles=$(CYCLES) seed=$(SEED),$(LOG_DIR)/$(1).log)
	@./obj_dir_$(1)/Vtb_iq_top +cycles=$(CYCLES) +seed=$(SEED) +log=$(LOG_DIR)/$(1).log; rc=$$$$?; \
	  $(call logline,$(1): 終了 exit=$$$$rc,$(LOG_DIR)/$(1).log); exit $$$$rc
endef
$(foreach c,$(CONFIGS),$(eval $(call config_rule,$(c))))

lint:
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM --top-module tb_iq_top \
	  $(call gparams,$(CFG_d2)) $(PKGS) $(RTL) $(TB)

stop:
	-pkill -f 'obj_dir_[a-z0-9]*/Vtb_iq_top'
	@pgrep -af 'obj_dir_[a-z0-9]*/Vtb_iq_top' || echo "動いているテストは無い"

status:
	@for c in $(CONFIGS); do echo "== $$c"; tail -n 3 $(LOG_DIR)/$$c.log 2>/dev/null || echo "  （ログ無し）"; done

clean:
	rm -rf obj_dir_* $(LOG_DIR)
