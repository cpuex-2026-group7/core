# Vivado のビルドと lint を make で呼ぶ（中身は launch/）
#
#   make                          使い方
#   make synth iq_top             iq_top を合成だけ
#   make build backend CLOCK=100  backend_top を 100MHz で配置配線
#   make timing backend N=20      前回の結果のワースト 20 本
#   make view iq_top SYNTH=1      合成の結果を GUI で開く
#   make program                  全体をビルドしてボードに書き込む（write なら書き込むだけ）
#   make lint                     全部を lint
#   make lint iq_top              iq_top から下の階層だけを lint
#
# 1 つ目がコマンド、2 つ目が対象（無ければ全体）
# オプションはビルドが CLOCK= N= SYNTH=1 CLEAN=1、lint が ALL=1 STRICT=1 V=1
# ビルドは Windows の make で動かす（WSL の make からは Windows の .exe を呼べない）。
# lint は WSL の Verilator を使う（Windows の make からは wsl 経由で呼ぶ）

CMDS := help synth build timing lint list status view open program write errors

CMD    := $(firstword $(MAKECMDGOALS))
TARGET := $(word 2,$(MAKECMDGOALS))
ifeq ($(CMD),)
  CMD := help
endif
ifneq ($(word 3,$(MAKECMDGOALS)),)
  $(error 書けるのはコマンドと対象の 2 つまで。オプションは CLOCK= N= SYNTH=1 CLEAN=1 ALL=1 STRICT=1 V=1)
endif
ifeq ($(filter $(CMD),$(CMDS)),)
  $(error 知らないコマンド: $(CMD)（$(CMDS)）)
endif

.DEFAULT_GOAL := $(CMD)
.PHONY: $(CMDS)

ifeq ($(CMD),lint)

ifeq ($(OS),Windows_NT)
  LINT := wsl python3 launch/lint.py
else
  LINT := python3 launch/lint.py
endif
LINT_ARGS := $(TARGET) $(if $(ALL),-a) $(if $(STRICT),--strict) $(if $(V),-v)

lint:
	@$(LINT) $(strip $(LINT_ARGS))

else

# WSL の make から呼ぶときは、日本語が化けないように出力を UTF-8 にさせる
ifneq ($(OS),Windows_NT)
  CLI_UTF8 := -Utf8Output
endif

CLI_ARGS := $(CLI_UTF8) $(CMD) $(TARGET) \
            $(if $(CLOCK),CLOCK=$(CLOCK)) \
            $(if $(N),N=$(N)) \
            $(if $(SYNTH),SYNTH=$(SYNTH)) \
            $(if $(CLEAN),CLEAN=$(CLEAN))

$(CMD):
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File launch/cli.ps1 $(strip $(CLI_ARGS))

endif

# 2 つ目（対象）は何もしないゴールとして受け流す（timing のようにフォルダと同じ名前でも動くよう .PHONY にも入れる）
ifneq ($(TARGET),)
.PHONY: $(TARGET)
$(TARGET):
	@cd .
endif
