# core_top の backend だけのテスト（backend_top に命令を入れて memory まで通す）（WSL2 の Ubuntu で実行）
#
#   make                          ビルドして実行
#   make CYCLES=200000 SEED=7     ランダムテストのサイクル数と乱数の種
#   make TRACE=3000               3000 サイクル目まで load / store の動きを表示する
#   make PULL=0                   memory リポジトリを pull せずに回す
#   make lint                     テストベンチと RTL を Verilator の -Wall で lint だけする
#   make clean                    ビルド結果を消す
#
# RTL はこの Makefile の 2 つ上（リポジトリ直下）の src/ から読む。memory は src/memory/memory_repository/rtl/（MEM_DIR で変えられる）。
# FPU 担当の演算器は test/eu_3_top/models/ と test/eu_4_top/models/ の代わりを、
# Vivado の IP（clk_wiz_core / fifo_generator_0・1 / mig_7series_0）は models/ip_stubs.sv の代わりを使う。
# backend_top は src/ のものをモジュール名だけ backend_top_real に変えて obj_dir/ に書き出し、
# models/backend_top_shim.sv の backend_top がそれを包む（core_top がまだ繋いでいない dispatch / ROB のポートをテストベンチから入れる）。

CYCLES ?= 100000
SEED   ?= 1
TRACE  ?= 0
CXXOPT ?= -Os

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR  := $(abspath $(TEST_DIR)/../../src)
MEM_REPO := $(RTL_DIR)/memory/memory_repository

# run / lint の前に memory リポジトリを最新にする（launch/flow.tcl の fetch_memory_repo と同じく pull --ff-only、失敗したら今のまま使う）。
# ファイルの一覧を作る前でないといけないので、レシピではなくここでやる。MEM_DIR を指定したときと PULL=0 のときはしない。
# Windows の git があればそれを使う（clone した側の改行の設定に合わせる）
PULL ?= 1
ifeq ($(PULL)$(origin MEM_DIR),1undefined)
ifneq ($(filter run lint,$(or $(MAKECMDGOALS),run)),)
ifneq ($(wildcard $(MEM_REPO)/.git),)
  GIT_PULL := $(if $(shell command -v git.exe),git.exe -C "$(shell wslpath -w $(MEM_REPO))",git -C $(MEM_REPO)) pull --ff-only -q
  $(info memory リポジトリを更新: $(GIT_PULL))
  PULL_OUT := $(shell $(GIT_PULL) 2>&1 || echo "PULL_FAILED")
  ifneq ($(findstring PULL_FAILED,$(PULL_OUT)),)
    $(warning memory リポジトリを更新できなかったので今のまま使う: $(PULL_OUT))
  endif
endif
endif
endif

MEM_DIR  ?= $(MEM_REPO)/rtl
MEM_DIR  := $(abspath $(MEM_DIR))
ifeq ($(wildcard $(RTL_DIR)/defs/types.sv),)
  $(error $(RTL_DIR)/defs/types.sv が無い。test/core_top_backend_only/ はリポジトリ直下の test/ の中に置くこと)
endif
ifeq ($(wildcard $(MEM_DIR)/mem_top.sv),)
  $(error $(MEM_DIR)/mem_top.sv が無い。memory リポジトリを src/memory/memory_repository に clone すること)
endif

# package は使う側より先に読む
PKGS := $(addprefix $(RTL_DIR)/defs/,types.sv ooo_types.sv isa.sv uop_types.sv) \
        $(addprefix $(RTL_DIR)/backend/defs/,back_types.sv iq_types.sv rr_types.sv ex_types.sv rob_types.sv lsu_types.sv) \
        $(TEST_DIR)/models/tb_core_top_backend_only_pkg.sv \
        $(MEM_DIR)/memory/dram/master_fifo_slave.sv
MODS := core_top async_to_sync \
        find_empty_slot multi_port_ram age_matrix selector iq_core iq_int iq_mem iq_float iq_top \
        rf_top \
        ex_top \
        eu_0_top eu_0_fu_0_top add sub sra beq blt pc_plus_1_eu_0 br_target \
        eu_1_top eu_1_fu_0_top agu \
        eu_2_top eu_2_fu_0_top fbeq fblt fbr_target fcsign flhi fli pc_plus_1_eu_2 \
        eu_3_top eu_3_fu_0_top eu_3_fu_1_top eu_3_fu_2_top \
        eu_4_top eu_4_fu_0_top eu_4_fu_1_top \
        lsu_top ldq stq lsu_controller lsu_searcher
MEM_MODS := mem_top recv_loader send_loader imem router d_cache dram_buf dram_controller uart_rx uart_tx
find_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' --exclude-dir=memory_repository $(RTL_DIR) /dev/null)
# memory リポジトリの archive/ と test/ には同じ名前の古いモジュールがあるので見ない
find_mem_mod = $(shell grep -rlE '^\s*module\s+$(1)\b' --include='*.sv' --exclude-dir=archive --exclude-dir=test $(MEM_DIR) /dev/null)
RTL := $(foreach m,$(MODS),$(call find_mod,$(m))) $(foreach m,$(MEM_MODS),$(call find_mem_mod,$(m)))
ifneq ($(words $(RTL)),$(words $(MODS) $(MEM_MODS)))
  $(error $(RTL_DIR) か $(MEM_DIR) 以下で $(MODS) $(MEM_MODS) のどれかが見つからないか、2 つ以上ある)
endif

BACKEND_SRC := $(call find_mod,backend_top)
ifneq ($(words $(BACKEND_SRC)),1)
  $(error $(RTL_DIR) 以下で backend_top が見つからないか、2 つ以上ある)
endif
BACKEND_REAL := $(TEST_DIR)/obj_dir/backend_top_real.sv

MODELS := $(addprefix $(TEST_DIR)/../eu_3_top/models/,eu_3_model_pkg.sv fmul.sv itof.sv ftoi.sv fadd.sv) \
          $(addprefix $(TEST_DIR)/../eu_4_top/models/,eu_4_model_pkg.sv fsqrt.sv fdiv.sv) \
          $(TEST_DIR)/models/ip_stubs.sv $(TEST_DIR)/models/backend_top_shim.sv
ifneq ($(words $(wildcard $(MODELS))),$(words $(MODELS)))
  $(error 演算器か IP の代わりが見つからない)
endif

TB := $(TEST_DIR)/tb_core_top_backend_only.sv

# -j 0 だと Verilator 5.020 が終了時に "attempted to destroy locked Thread Pool" で落ちることがある
VFLAGS := --binary --timing --build-jobs 0 --verilate-jobs 1 --top-module tb_core_top_backend_only -O3 -Wno-fatal -Wno-TIMESCALEMOD \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
          -MAKEFLAGS OPT_FAST=$(CXXOPT) -MAKEFLAGS OPT_SLOW=$(CXXOPT) -MAKEFLAGS OPT_GLOBAL=$(CXXOPT)

.DEFAULT_GOAL := run
.PHONY: run lint clean

# モジュール名だけ変える（ファイルは毎回作り直す）
.PHONY: $(BACKEND_REAL)
$(BACKEND_REAL):
	@mkdir -p $(dir $@)
	sed -E 's/^([[:space:]]*module[[:space:]]+)backend_top\b/\1backend_top_real/' $(BACKEND_SRC) > $@
	@grep -qE '^\s*module\s+backend_top_real\b' $@ || { echo "$(BACKEND_SRC) の module backend_top を書き換えられなかった"; exit 1; }

run: $(BACKEND_REAL)
	@command -v verilator >/dev/null || { echo "verilator が無い。WSL で sudo apt install verilator を実行して"; exit 1; }
	verilator $(VFLAGS) --Mdir obj_dir $(PKGS) $(MODELS) $(BACKEND_REAL) $(RTL) $(TB) -o Vtb_core_top_backend_only
	./obj_dir/Vtb_core_top_backend_only +cycles=$(CYCLES) +seed=$(SEED) +trace=$(TRACE)

lint: $(BACKEND_REAL)
	verilator --lint-only --timing -Wall -Wno-DECLFILENAME -Wno-TIMESCALEMOD --top-module tb_core_top_backend_only \
	  $(PKGS) $(MODELS) $(BACKEND_REAL) $(RTL) $(TB)

clean:
	rm -rf obj_dir
