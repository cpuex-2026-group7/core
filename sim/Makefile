# Verilator シミュレーション（WSL2 の Ubuntu で実行）
#
#   make                         sim を取得/更新 → ビルド → PROG を RTL と sim で 1 命令ずつ比べながら実行
#   make PROG=../test/foo.mem    別のプログラムで
#   make ARGS="+bp=0x8"          テストベンチへの追加オプション（tb_cpu.cpp の冒頭を参照）
#   make build                   取得/更新とビルドだけ
#   make compare                 sim の実行ファイルを単独で動かし、--trace の出力と RTL のトレースを突き合わせる
#   make clean                   ビルド結果を消す（sim_repository は残す）
#   make distclean               sim_repository も消す
#
# Windows 側の VS Code 用に、Verilator のヘッダを obj_dir/ide/verilator にコピーする
# （.vscode/c_cpp_properties.json の includePath からここを参照する）。

PROG ?= ../test/fib.mem
ARGS ?=

# 命令シミュレータ。make のたびに最新版に更新する
SIM_URL  := https://github.com/cpuex-2026-group7/sim.git
SIM_REPO := sim_repository

# RTL はこの Makefile の 1 つ上（リポジトリ直下）の src/。どこから make しても同じ場所を見る
SIM_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(SIM_DIR)/../src)
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。sim/ はリポジトリ ito_cpu_1 の直下（src/ と同じ階層）に置くこと)
endif
# package は使う側より先に読む必要がある
PKGS := $(RTL_DIR)/defs/types.sv $(RTL_DIR)/defs/isa.sv
RTL  := $(filter-out $(PKGS),$(shell find $(RTL_DIR) -name '*.sv' -not -path '*/ip/*' -not -name top.sv | sort))
ifeq ($(shell grep -lE '^\s*module\s+core_top\b' $(RTL) /dev/null),)
  $(error $(RTL_DIR) 以下に module core_top が見つからない（見つかった .sv: $(notdir $(RTL))）)
endif

TB_SRCS := $(wildcard *.cpp)
TB_HDRS := $(wildcard *.h)
# テストベンチには命令シミュレータの main.cpp 以外を全部リンクする
SIM_SRCS = $(filter-out %/main.cpp,$(wildcard $(SIM_REPO)/src/*.cpp))
SIM_HDRS = $(wildcard $(SIM_REPO)/src/*.h)

EXE     := obj_dir/Vcore_top
# 命令シミュレータ単体の実行ファイル（sim リポジトリの Makefile でビルドしたもの）
SIM_EXE := $(SIM_REPO)/build/sim
VL_ROOT := $(shell verilator --getenv VERILATOR_ROOT 2>/dev/null)

# 命令シミュレータは C++23 で書かれている（sim リポジトリの Makefile に合わせる）
CXXFLAGS_TB := -std=c++23 -O2 -I$(CURDIR) -I$(CURDIR)/$(SIM_REPO)/src

VFLAGS := --cc --exe --build -j 0 --top-module core_top --trace-fst \
          -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-TIMESCALEMOD \
          -CFLAGS "$(CXXFLAGS_TB)"

.DEFAULT_GOAL := all
.PHONY: all build fetch ide check-deps compare clean distclean

check-deps:
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	@echo '#include <cstdio>' | $(CXX) -x c++ -std=c++23 -fsyntax-only - 2>/dev/null || { \
	  echo "$(CXX) が C++ の標準ヘッダ（<cstdio> など）を見つけられない。$(CXX) が使っている GCC の版:"; \
	  $(CXX) -v -x c++ -fsyntax-only /dev/null 2>&1 | grep "Selected GCC" ; \
	  echo "その番号に合わせて sudo apt install libstdc++-<番号>-dev を実行して（例: libstdc++-14-dev）"; exit 1; }
	@echo '#include <zlib.h>' | $(CXX) -x c++ -fsyntax-only - 2>/dev/null || \
	  { echo "zlib.h が無い。WSL で sudo apt install zlib1g-dev を実行して"; exit 1; }

all: build
	./$(EXE) +imem=$(PROG) $(ARGS)

# sim を取ってきてからビルドする。取ってくる前は SIM_SRCS が空なので、ビルドは make を呼び直して行う
build: fetch
	@$(MAKE) --no-print-directory $(EXE) ide

fetch:
	@if [ -d $(SIM_REPO)/.git ]; then \
	  echo "[sim] $(SIM_REPO) を最新版に更新"; \
	  git -C $(SIM_REPO) pull --ff-only -q || echo "[sim] 更新に失敗したので手元の版で続ける"; \
	else \
	  echo "[sim] $(SIM_URL) を $(SIM_REPO) に取得"; \
	  git clone -q --depth 1 $(SIM_URL) $(SIM_REPO); \
	fi

$(EXE): | check-deps
$(EXE): $(PKGS) $(RTL) $(TB_SRCS) $(TB_HDRS) $(SIM_SRCS) $(SIM_HDRS)
	verilator $(VFLAGS) $(PKGS) $(RTL) $(TB_SRCS) $(SIM_SRCS) -o Vcore_top

# 命令シミュレータ単体は、sim リポジトリの Makefile のままビルドする（clang++ を使う）
$(SIM_EXE): $(wildcard $(SIM_REPO)/src/*.cpp) $(SIM_HDRS)
	@command -v clang++ >/dev/null || { echo "sim の Makefile は clang++ を使う。WSL で sudo apt install clang を実行して"; exit 1; }
	$(MAKE) -C $(SIM_REPO)

# sim と RTL の両方でトレースを出して突き合わせる。
# sim は .mem ではなくビッグエンディアンの生バイナリを読むので、mem2bin.py で変換する
compare: build
	@$(MAKE) --no-print-directory $(SIM_EXE)
	python3 mem2bin.py $(PROG) obj_dir/prog.bin
	./$(SIM_EXE) obj_dir/prog.bin --trace sim.trace > sim.dump
	-./$(EXE) +imem=$(PROG) +trace=rtl.trace $(ARGS) > rtl.dump
	python3 cmp_trace.py rtl.trace sim.trace

# Windows の VS Code からは WSL の /usr/share/verilator が見えにくいので、リポジトリ内にコピーしておく
ide:
	@[ -f obj_dir/ide/verilator/verilated.h ] || { mkdir -p obj_dir/ide && cp -r $(VL_ROOT)/include obj_dir/ide/verilator; }

clean:
	rm -rf obj_dir *.trace *.dump wave.fst

distclean: clean
	rm -rf $(SIM_REPO)
