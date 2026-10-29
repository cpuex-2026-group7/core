# find_empty_slot の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                        決めてある構成を全部ビルドして実行
#   make custom SIZE=12 FIND=3  任意の構成
#   make N=1000000 SEED=7       SIZE > 16 のときのランダムパターン数と乱数の種
#   make lint                   Verilator の -Wall で lint だけする
#   make clean                  ビルド結果を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。

TOP := find_empty_slot

N    ?= 200000
SEED ?= 1

# SIZE_FIND の組。SIZE <= 16 は全パターン、それより大きいものはランダム
CONFIGS := 16_1 16_2 16_3 16_4 5_1 5_2 5_3 1_1 1_2 1_3 32_2 32_3 64_1 64_2 64_4

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
TOP_SRC  := $(shell grep -rlE '^\s*module\s+$(TOP)\b' --include='*.sv' $(RTL_DIR) /dev/null)
ifeq ($(TOP_SRC),)
  $(error $(RTL_DIR) 以下に module $(TOP) が見つからない)
endif

TB_SRCS := tb_$(TOP).cpp

CXXFLAGS_TB := -std=c++17 -O2
# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --cc --exe --build --build-jobs 0 --verilate-jobs 1 --top-module $(TOP) -O3 -Wall -Wno-fatal -Wno-TIMESCALEMOD

RUN_ARGS := +n=$(N) +seed=$(SEED)

.DEFAULT_GOAL := all
.PHONY: all custom lint clean $(addprefix run_,$(CONFIGS))

all: $(addprefix run_,$(CONFIGS))

# $(1)=SIZE, $(2)=FIND_NUM
define build_and_run
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) -GSIZE=$(1) -GFIND_NUM=$(2) \
	  -CFLAGS "$(CXXFLAGS_TB) -DSIZE=$(1) -DFIND_NUM=$(2)" \
	  --Mdir obj_dir_s$(1)_f$(2) $(TOP_SRC) $(addprefix $(TEST_DIR)/,$(TB_SRCS)) -o V$(TOP)
	cd obj_dir_s$(1)_f$(2) && ./V$(TOP) $(RUN_ARGS)
endef

# .PHONY にはパターンルールが効かないので、構成ごとにルールを作る
define config_rule
run_$(1):
	$$(call build_and_run,$(word 1,$(subst _, ,$(1))),$(word 2,$(subst _, ,$(1))))
endef
$(foreach c,$(CONFIGS),$(eval $(call config_rule,$(c))))

custom:
	@[ -n "$(SIZE)" ] && [ -n "$(FIND)" ] || { echo "SIZE と FIND を指定して（例: make custom SIZE=12 FIND=3）"; exit 1; }
	$(call build_and_run,$(SIZE),$(FIND))

lint:
	@for c in $(CONFIGS); do \
	  s=$${c%_*}; f=$${c#*_}; \
	  echo "lint SIZE=$$s FIND_NUM=$$f"; \
	  verilator --lint-only -Wall -Wno-TIMESCALEMOD --top-module $(TOP) -GSIZE=$$s -GFIND_NUM=$$f $(TOP_SRC) || exit 1; \
	done

clean:
	rm -rf obj_dir_*
