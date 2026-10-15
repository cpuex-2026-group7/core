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

## build.bat

Windows のコマンドプロンプトか PowerShell で、リポジトリ直下（.xpr と _build.tcl がある場所）から実行する。Vivado の GUI は開かない。

```bat
.\build.bat                 :: 必要なら合成・配置配線・ビットストリーム生成をして、ボードに書き込む
.\build.bat build           :: ビットストリームを作るだけ（書き込まない）
.\build.bat program         :: 今あるビットストリームを書き込むだけ
.\build.bat clean           :: 合成と配置配線を強制的にやり直して書き込む（build clean なら作るだけ）
.\build.bat errors          :: 前回の ERROR と CRITICAL WARNING、タイミングの概要を表示
.\build.bat status          :: 各ランの状態とタイミングの概要を表示
.\build.bat timing          :: クリティカルパスのワースト 10 本を表示
.\build.bat timing 20       :: ワースト 20 本
.\build.bat ip              :: IP（clk_wiz_0）の状態を表示し、ロックされていれば更新・再生成
```

- ソースが前回のビルドから変わっていなければ、合成・配置配線は飛ばす
- clone 直後や別の PC で「locked IP」と言われたら、先に `.\build.bat ip` を実行する
- ボードが見つからないと言われたら、USB ケーブル・電源スイッチ・ドライバを確認する
- 終了コードは 0 = 成功、1 = 失敗
- Vivado は PATH にある vivado.bat、無ければ C:\Xilinx などから一番新しいものを探す。別のものを使うときは先に `set VIVADO=C:\Xilinx\Vivado\2020.2\bin\vivado.bat`（PowerShell なら `$env:VIVADO="..."`）
- timing の詳しいレポートは timing/summary.rpt と timing/paths.rpt に出る。配置配線が終わっていればその結果、無ければ合成の結果（配線遅延は見積もり）を使う

# CPU説明

5 段パイプライン（IF / ID / EX / MEM / WB）

# その他

verilatorやtclファイルなどはClaude製
