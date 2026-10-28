# multi_port_ram（LVT 方式のマルチポート RAM）の単体テスト（WSL2 の Ubuntu で実行）
#
#   make                  I 側（3W5R）と F 側（4W7R）の両方をビルドして実行
#   make int              I 側だけ
#   make fp               F 側だけ
#   make custom W=2 R=3   任意の構成（SIZE=128 でエントリ数、WIDTH=6 でエントリ幅も変えられる）
#   make CYCLES=1000000 SEED=7   ランダムテストのサイクル数と乱数の種
#   make TRACE=1 int      波形（wave_int.fst）も出す。遅くなるので必要なときだけ
#   make lint             multi_port_ram を Verilator の -Wall で lint だけする
#   make clean            ビルド結果と波形を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。
# multi_port_ram.sv が src/ のどこにあっても動くように、sim/Makefile と同じく src/ 以下の .sv をまとめて渡し、
# --top-module multi_port_ram で必要なモジュールだけを使う。

TOP := multi_port_ram

SIZE   ?= 64
WIDTH  ?= 32
CYCLES ?= 200000
SEED   ?= 1
TRACE  ?= 0

# I 側・F 側の構成（claude/ooo-execution-units.md の決定どおり）
INT_W := 3
INT_R := 5
FP_W  := 4
FP_R  := 7

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/multi_port_ram/ はリポジトリ直下の test/ の中に置くこと)
endif
# package は使う側より先に読む必要がある
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv isa.sv fpu_defs.sv ctrl_defs.sv)
RTL  := $(filter-out $(PKGS),$(shell find $(RTL_DIR) -name '*.sv' -not -path '*/ip/*' -not -name top.sv | sort))
TOP_SRC := $(shell grep -lE '^\s*module\s+$(TOP)\b' $(RTL) /dev/null)
ifeq ($(TOP_SRC),)
  $(error $(RTL_DIR) 以下に module $(TOP) が見つからない)
endif

TB_SRCS := tb_$(TOP).cpp

CXXFLAGS_TB := -std=c++17 -O2
VFLAGS := --cc --exe --build -j 0 --top-module $(TOP) -O3 -Wno-fatal -Wno-TIMESCALEMOD
ifeq ($(TRACE),1)
  VFLAGS += --trace-fst
  CXXFLAGS_TB += -DMPR_TRACE
  RUN_TRACE := +trace
endif

RUN_ARGS := +cycles=$(CYCLES) +seed=$(SEED) $(RUN_TRACE)

.DEFAULT_GOAL := all
.PHONY: all int fp custom lint clean

all: int fp

# $(1)=名前, $(2)=W, $(3)=R
define build_and_run
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) -GSIZE=$(SIZE) -GENTRY_WIDTH=$(WIDTH) -GW=$(2) -GR=$(3) \
	  -CFLAGS "$(CXXFLAGS_TB) -DSIZE=$(SIZE) -DENTRY_WIDTH=$(WIDTH) -DWP=$(2) -DRP=$(3)" \
	  --Mdir obj_dir_$(1) $(PKGS) $(RTL) $(addprefix $(TEST_DIR)/,$(TB_SRCS)) -o V$(TOP)
	cd obj_dir_$(1) && ./V$(TOP) $(RUN_ARGS)
	@[ "$(TRACE)" != 1 ] || { mv obj_dir_$(1)/wave.fst wave_$(1).fst && echo "波形: wave_$(1).fst"; }
endef

int:
	$(call build_and_run,int,$(INT_W),$(INT_R))

fp:
	$(call build_and_run,fp,$(FP_W),$(FP_R))

custom:
	@[ -n "$(W)" ] && [ -n "$(R)" ] || { echo "W と R を指定して（例: make custom W=2 R=3）"; exit 1; }
	$(call build_and_run,w$(W)r$(R)x$(WIDTH),$(W),$(R))

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module $(TOP) \
	  -GSIZE=$(SIZE) -GENTRY_WIDTH=$(WIDTH) -GW=$(FP_W) -GR=$(FP_R) $(PKGS) $(TOP_SRC)

clean:
	rm -rf obj_dir_* *.fst
