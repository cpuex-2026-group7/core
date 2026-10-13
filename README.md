# デバッグ機能

SW[5:0]でレジスタとかを7segで見られる
0-31はレジスタ
32はPCの中身

SW[15]が入っている時はステップ実行させる
BTNRを押すと1step進む

LED[15]だけSW[15]に対応して光る

リセットボタンでPCリセット

# Verilator

sim/でmake

```sh
cd sim
make                          # fib.mem で比較
make PROG=../test/foo.mem     # 別のプログラム
make ARGS="+bp=0x8"               # pc=0x8 を実行する直前で毎回レジスタ表示
make ARGS="+wave_from=60 +wave_len=40"   # 区間の波形を出力する。gtkwave wave.fstで開ける
```

# CPU説明

シングルサイクル

# その他

verilatorやtclファイルなどはClaude製
