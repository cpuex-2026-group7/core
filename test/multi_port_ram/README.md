# multi_port_ram の単体テスト

`multi_port_ram`（`src/common/multi_port_ram.sv`。LVT 方式のマルチポート RAM で、LVT の表は XOR 方式）を Verilator で単体テストする。
WSL2 の Ubuntu で実行する想定。`verilator` と `g++` が必要。

## 使い方

```sh
cd test/multi_port_ram
make                        # I 側（3W5R）と F 側（4W7R）をビルドして実行
make int                    # I 側だけ
make fp                     # F 側だけ
make custom W=2 R=3         # 任意の構成（SIZE=128 でエントリ数、WIDTH=6 でエントリ幅も変えられる）
make CYCLES=1000000 SEED=7  # ランダムテストのサイクル数と乱数の種を変える
make TRACE=1 int            # 波形 wave_int.fst も出す（GTKWave などで見る）
make lint                   # multi_port_ram を -Wall で lint だけする
make clean
```

Windows 側からは `wsl make -C test/multi_port_ram int` のように実行する。

`multi_port_ram` は `src/` 以下のどのファイルにあってもよい（`module multi_port_ram` を含む `.sv` を探す）。
ビルドは `sim/Makefile` と同じく `src/` 以下の `.sv` をまとめて渡し、`--top-module multi_port_ram` で必要なものだけを使う。

## 前提にしている multi_port_ram のインターフェース

```systemverilog
module multi_port_ram #(parameter SIZE, parameter ENTRY_WIDTH, parameter R, parameter W) (
  input  clk,
  input  w_en[W], w_addr[W] /* $clog2(SIZE) bit */, w_data[W] /* ENTRY_WIDTH bit */,
  input  r_addr[R] /* $clog2(SIZE) bit */,
  output r_data[R] /* ENTRY_WIDTH bit */
);
```

- 読み出しは非同期、書き込みは同期
- 同じアドレスへの同時書き込みは禁止（テストでも発生させない）
- テストベンチが対応する `ENTRY_WIDTH` は 1〜32

## 確認していること

| テスト | 内容 |
|---|---|
| 初期値 | 起動直後に全エントリが 0（`initial` の 0 埋めが全コピーで揃っているか） |
| ポートごとの書き込み | 各書き込みポートで全アドレスに書き、全読み出しポートで読める。書いたのと同じサイクルの読み出しは古い値 |
| 書き込みポートの切り替わり | 同じアドレスを別々のポートが順番（正順・逆順）に書いたとき、最後の値が読める（LVT の表の更新） |
| 全ポート同時書き込み | 全書き込みポートが同時に別々のアドレスへ書いても干渉しない（XOR の打ち消し） |
| ランダム | 上を混ぜたもの。読み出しアドレスの半分は直近に書いたアドレスから選ぶ |

各テストの後に全アドレスを全読み出しポートで読み直して確認している。

## 失敗したとき

- テストベンチは最初の 20 件の不一致を `NG [テスト名] cycle ...` の形で出す
- `multi_port_ram` の中の `ifndef SYNTHESIS` のシャドウ配列の照合や、`lvt_table` の同時書き込み検出の
  `$error` でシミュレーションがその場で止まる（終了コードは 0 以外）
- 原因を追うときは `make TRACE=1 CYCLES=1000 int` で波形を出す
