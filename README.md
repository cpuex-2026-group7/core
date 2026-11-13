# デバッグ機能

SW[5:0]でレジスタとかを7segで見られる
0-63はレジスタ
64はPCの中身

SW[15]が入っている時はステップ実行させる
BTNRを押すと1step進む

LED[15]だけSW[15]に対応して光る

リセットボタンでPCリセット

# Verilator

WSL2 の Ubuntu で sim/ に入って make する。make のたびに命令シミュレータ（cpuex-2026-group7/sim）を sim/sim_repository に取得・更新してビルドし、同じプログラムを RTL と命令シミュレータの両方で動かす。

```sh
cd sim
make                                        # sim_repository/test/fib.bin を両方で実行
make PROG=sim_repository/test/foo.bin       # 別のプログラム（パスは sim/ から見た相対パス）
make PROG=../test/foo.bin                   # リポジトリ側に置いたプログラム
make ARGS="+bp=0x8"                         # pc=0x8 を実行する直前で毎回レジスタ表示
make ARGS="+trace_mode=cycle"               # core.trace に毎サイクル c と pc を付ける
make ARGS="+wave_from=60 +wave_len=40"      # 区間の波形を出力する。gtkwave wave.fst で開ける
make build                                  # 取得/更新とビルドだけ
make clean                                  # ビルド結果と出力を消す（sim_repository は残す）
make distclean                              # sim_repository も消す
```

- PROG は .bin（命令シミュレータと同じビッグエンディアンの生バイナリ）だけ。命令シミュレータが .bin しか読まないので、.mem を渡すと make がエラーにする
- 出力（sim/ に出る）
  - core.trace : RTL の書き込み（レジスタ・メモリ）と halt
  - sim.trace : 命令シミュレータの --trace の出力
  - core.dump / sim.dump : それぞれの終了時のレジスタ表示
- core.trace と sim.trace は形式が違うので make では比較しない
- RTL だけを .mem（$readmemh 形式）で動かしたいときは、ビルド後に直接実行する

```sh
./obj_dir/Vcore_top +imem=foo.mem
```

ARGS に渡せるオプションの詳細は sim/tb_cpu.cpp の冒頭を参照。

# Vivado（実機）

i_mem は合成時に `fib.mem`（$readmemh 形式）を読む。

## make

Windows の PowerShell で、リポジトリ直下から実行する。view / open 以外は Vivado の GUI を開かない。makeを.\build.batに置き換えても同じコマンドが実行される。

```powershell
make                              # 使い方を表示
make <コマンド> [対象] [オプション]
```

| コマンド | すること |
| --- | --- |
| `synth` | 合成だけ。速いが配線遅延は見積もり（LUT の段数を見るとき用） |
| `build` | ビルドする（全体はビットストリームまで、それ以外は配置配線まで） |
| `timing` | 前回の結果のクリティカルパスを表示 |
| `lint` | 静的チェック（WSL の Verilator を使う） |
| `list` | これまでの結果の一覧（WNS・Fmax・LUT） |
| `status` | 前回の結果の回路規模とタイミングの概要を表示 |
| `view` | ビルドして Vivado の GUI で開く |
| `open` | ビルドせずに、前回の結果を GUI で開く |
| `program` | 全体を（必要なら）ビルドしてボードに書き込む |
| `write` | ビルドせずに、今あるビットストリームをボードに書き込むだけ |
| `errors` | 前回の全体のビルドの ERROR と CRITICAL WARNING を表示 |

| 対象 | 意味 |
| --- | --- |
| なし（か `top`） | 全体（top.sv）。core.xpr のプロジェクトでビルドする |
| `backend` | backend_top だけ |
| モジュール名（`iq_top`、`lsu_top` など） | そのモジュールだけ |

| オプション | 意味 |
| --- | --- |
| `CLOCK=100` | クロック（`100` / `100mhz` / `10ns`）。既定は 80MHz。全体は clk_wiz_0 で決まるので効かない |
| `N=20` | クリティカルパスを何本表示するか（既定 10 本） |
| `SYNTH=1` | view を合成までにする。全体の open は合成の結果を開く |
| `CLEAN=1` | 全体の合成と配置配線を強制的にやり直す |
| `ALL=1` / `STRICT=1` / `V=1` | lint で note も表示 / style も失敗にする / ツールの生の出力も表示 |

```powershell
make synth iq_top              # iq_top を合成だけして段数を見る
make build backend CLOCK=100   # backend_top を 100MHz で配置配線
make view iq_top               # iq_top を配置配線して GUI で開く
make timing backend N=20       # 前回の backend のワースト 20 本
make list                      # これまでの結果を並べて比べる
make lint iq_top               # iq_top から下の階層だけを lint
make program                   # 全体をビルドしてボードに書き込む
```

### backend とモジュール単位のビルド

- .xpr を使わず、out-of-context で合成・配置配線する。ピンを割り当てないので、ボードには書き込めない（回路規模とクロックを見る用）
- ポートの外は遅延 0 とみなす（入力から FF、FF から出力のパスも見る）
- 結果は `timing/<名前>/`（backend は `timing/backend/`）に出る。git には入れない
  - `summary.rpt` / `paths.rpt`：Vivado のタイミングレポート
  - `groups.rpt`：違反パスを「始点の FF の束 → 終点の束」でまとめて悪い順に並べたもの
  - `utilization.rpt` / `utilization_hier.rpt`：回路規模
  - `placement.svg`：配置の図。Vivado の Device 画面と同じタイルの並びで、使っている LUT / FF などをモジュールごとに色分けする（配線は描かない。ブラウザで拡大するとスライスの中まで見える）
  - `<名前>_synth.dcp` / `<名前>_routed.dcp`：GUI で開ける（`make open <名前>`）

### lint

- `make lint` は全部、`make lint iq_top` は iq_top から下の階層のファイルだけを見る
- 見るもの：Verilator（-Wall）、`default_nettype の規約、Verible（入っていれば）。全部のときは .xpr とファイルの対応、テストベンチ、Python も
- WSL で直接動かすときは `python3 launch/lint.py [モジュール]`

## build.bat

make と同じ書き方で使える（make が入っていなくてよい。中で同じものを呼んでいる）。

```bat
.\build.bat                           :: 使い方を表示（make と同じ）
.\build.bat synth iq_top CLOCK=100    :: make synth iq_top CLOCK=100 と同じ
.\build.bat timing backend N=20
.\build.bat lint iq_top
.\build.bat program                   :: 全体をビルドしてボードに書き込む
```

- 前の書き方（`.\build.bat build`、`.\build.bat build iq_top synth`、`.\build.bat timing 20`、`.\build.bat clean` など）もそのまま使える
- ただし次の 2 つは前と意味が変わった
  - 何も付けない `.\build.bat`：前は「ビルドして書き込む」、今は使い方の表示
  - `.\build.bat program`：前は「書き込むだけ」、今は「（必要なら）ビルドして書き込む」。書き込むだけなら `.\build.bat write`

## 共通の注意

- 全体のビルドのときは、最初に src/memory/memory_repository に cpuex-2026-group7/memory を、src/fpu/fpu_repository に cpuex-2026-group7/fpu を取得する（あれば `git pull --ff-only` で更新）。backend とモジュールのときは fpu だけ。git には入れない
- core.xpr は git に入れていない。無ければ全体のビルドのときに作る。src/ に .sv を足したり消したりしたら、全体のビルドのときに core.xpr にも反映する（GUI で Add Sources しなくてよい）
- 全体のビルドは、ソースが前回から変わっていなければ合成・配置配線を飛ばす
- clone 直後や別の PC で IP（clk_wiz_0）がロックされていたら、全体のビルドのときに自動で更新する（Vivado の版が違うと src/ip/clk_wiz_0/clk_wiz_0.xci が書き換わることがある）。直らなかったときは IP の状態を表示して止まる
- ボードが見つからないと言われたら、USB ケーブル・電源スイッチ・ドライバを確認する
- 終了コードは 0 = 成功、1 = 失敗
- Vivado は PATH にある vivado.bat、無ければ C:\Xilinx などから一番新しいものを探す。別のものを使うときは先に `$env:VIVADO="C:\Xilinx\Vivado\2020.2\bin\vivado.bat"`（コマンドプロンプトなら `set VIVADO=...`）
- ファイルの構成：`Makefile` と `build.bat` → `launch/cli.ps1`（引数の解釈・ヘルプ・一覧・lint の呼び出し）→ `launch/run.bat`（Vivado を探して起動）→ `launch/boot.tcl`（flow.tcl を UTF-8 で読み込むだけ）→ `launch/flow.tcl`（Vivado の中で動く本体）。lint は `launch/lint.py`

# CPU説明

5 段パイプライン（IF / ID / EX / MEM / WB）

# その他

build系、テストファイルなどはClaude製
