# Verilator シミュレーション（WSL2 の Ubuntu で実行）
#
#   make                         sim を取得/更新 → ビルド → PROG を RTL と命令シミュレータでそれぞれ動かす
#                                  sim/core.trace : RTL の書き込み（tb_cpu.cpp が書く。形式は tb_cpu.cpp の冒頭を参照）
#                                  sim/sim.trace  : 命令シミュレータの --trace の出力そのまま
#                                  sim/core.dump / sim/sim.dump : それぞれの終了時のレジスタ表示
#   make PROG=sim_repository/test/bin/foo.bin  別のプログラムで（.bin のみ。命令シミュレータがビッグエンディアンの生バイナリしか読まないため）
#   make ARGS="+trace_mode=cycle" テストベンチへの追加オプション（tb_cpu.cpp の冒頭を参照）
#   make build                   取得/更新とビルドだけ
#   make clean                   ビルド結果と出力を消す（sim_repository は残す）
#   make distclean               sim_repository も消す
#
# core.trace と sim.trace は形式が違うので、ここでは比較しない。
#
# Windows 側の VS Code 用に、Verilator のヘッダを obj_dir/ide/verilator にコピーする
# （.vscode/c_cpp_properties.json の includePath からここを参照する）。

PROG ?= sim_repository/test/bin/fib.bin
ARGS ?=

# 命令シミュレータ。make のたびに最新版に更新する
SIM_URL  := https://github.com/cpuex-2026-group7/sim.git
SIM_REPO := sim_repository

# RTL はこの Makefile の 1 つ上（リポジトリ直下）の src/。どこから make しても同じ場所を見る
SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(SIM_DIR)/../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。sim/ はリポジトリの直下（src/ と同じ階層）に置くこと)
endif
# package は使う側より先に読む必要がある
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv isa.sv fpu_defs.sv ctrl_defs.sv)
RTL  := $(filter-out $(PKGS),$(shell find $(RTL_DIR) -name '*.sv' -not -path '*/ip/*' -not -name top.sv | sort))
ifeq ($(shell grep -lE '^\s*module\s+core_top\b' $(RTL) /dev/null),)
  $(error $(RTL_DIR) 以下に module core_top が見つからない（見つかった .sv: $(notdir $(RTL))）)
endif

TB_SRCS := tb_cpu.cpp

EXE     := obj_dir/Vcore_top
# 命令シミュレータの実行ファイル（sim リポジトリの Makefile でビルドしたもの）
SIM_EXE := $(SIM_REPO)/build/sim
VL_ROOT := $(shell verilator --getenv VERILATOR_ROOT 2>/dev/null)

CXXFLAGS_TB := -std=c++17 -O2

VFLAGS := --cc --exe --build -j 0 --top-module core_top --trace-fst \
          -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-TIMESCALEMOD \
          -CFLAGS "$(CXXFLAGS_TB)"

.DEFAULT_GOAL := all
.PHONY: all build fetch ide check-deps check-prog clean distclean

check-prog:
	@case "$(PROG)" in *.bin) ;; *) echo "PROG は .bin を指定して（今: $(PROG)）。.mem は命令シミュレータが読めない"; exit 1;; esac

check-deps:
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	@command -v clang++ >/dev/null || { echo "sim の Makefile は clang++ を使う。WSL で sudo apt install clang を実行して"; exit 1; }
	@echo '#include <zlib.h>' | $(CXX) -x c++ -fsyntax-only - 2>/dev/null || \
	  { echo "zlib.h が無い。WSL で sudo apt install zlib1g-dev を実行して"; exit 1; }

# PROG は RTL と命令シミュレータの両方にそのまま渡す（命令シミュレータが .bin しか読まないので .bin に限る）
# 既定の PROG は sim_repository の中にあるので、ファイルがあるかは fetch の後（ここ）で確かめる
all: check-prog build
	@[ -f "$(PROG)" ] || { echo "PROG が見つからない: $(PROG)"; exit 1; }
	-./$(EXE) +imem=$(PROG) $(ARGS) > core.dump
	./$(SIM_EXE) $(PROG) --trace sim.trace > sim.dump
	@echo "出力: core.trace sim.trace core.dump sim.dump"

# sim を取ってきてからビルドする（sim の実行ファイルは sim リポジトリの Makefile のままビルドする）
build: fetch
	@$(MAKE) --no-print-directory $(EXE) ide
	$(MAKE) -C $(SIM_REPO)

fetch:
	@if [ -d $(SIM_REPO)/.git ]; then \
	  echo "[sim] $(SIM_REPO) を最新版に更新"; \
	  git -C $(SIM_REPO) pull --ff-only -q || echo "[sim] 更新に失敗したので手元の版で続ける"; \
	else \
	  echo "[sim] $(SIM_URL) を $(SIM_REPO) に取得"; \
	  git clone -q --depth 1 $(SIM_URL) $(SIM_REPO); \
	fi

$(EXE): | check-deps
$(EXE): $(PKGS) $(RTL) $(TB_SRCS) konata_trace.h
	verilator $(VFLAGS) $(PKGS) $(RTL) $(TB_SRCS) -o Vcore_top

# Windows の VS Code からは WSL の /usr/share/verilator が見えにくいので、リポジトリ内にコピーしておく
ide:
	@[ -f obj_dir/ide/verilator/verilated.h ] || { mkdir -p obj_dir/ide && cp -r $(VL_ROOT)/include obj_dir/ide/verilator; }

clean:
	rm -rf obj_dir *.trace *.dump wave.fst core.kanata.log

distclean: clean
	rm -rf $(SIM_REPO)
