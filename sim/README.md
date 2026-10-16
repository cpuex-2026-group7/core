ここにあるMakefile,cpp,hはほぼclaudeが作成
sim_repositoryにはsim係のrepositoryが入る

## Konataでパイプラインを表示する

```sh
cd sim
make ARGS="+konata=core.kanata.log"
# RTLだけを実行する場合（ビルド済み）
./obj_dir/Vcore_top +imem=../test/fib.mem +konata=core.kanata.log
```

[Konata](https://github.com/shioyadan/Konata)で生成された
`sim/core.kanata.log`を開く（上のコマンドの実行ディレクトリからは`core.kanata.log`）。
[Kanata v4形式](https://github.com/shioyadan/Konata/blob/master/docs/kanata-log-format.md)で、
IF / ID / EX / MEM / WB、PC（ワードアドレス）、命令の生ビット列を表示する。
レジスタ・メモリ書き込みは命令のツールチップに付く。
ストールはlane 1に表示するので、必要に応じてKonataのViewメニューでSplit lanesを有効にする。
分岐で破棄された命令はflushとして記録する。同じPCの繰り返し実行にも別の命令IDを割り当てる。

サイクル0はリセット解除後の最初のposedge直前の状態（`core.trace`の`c=0`に対応）。
各ステージはその状態を1サイクル幅で表示する。リセット・flushで挿入されたバブルは表示しない。
haltをIDに保持している間の内部コピーは重複表示しない。
halt・タイムアウト終了時は未完了命令をflushで閉じ、ツールチップに終了理由を付ける。
したがって末尾のflushには分岐以外の終了処理も含まれる。

`+konata`を省略するとパイプライントレースは出力しない。`core.trace`や波形出力との併用も可能。
ログが大きくなる場合は`+max_cycle=10000`などで実行を制限できる。
`make clean`で既定名の`core.kanata.log`も削除する。

出力形式・ストール・分岐・halt処理の単体テスト（Verilator不要）:

```sh
python3 sim/test_konata.py  # リポジトリ直下から実行
```
