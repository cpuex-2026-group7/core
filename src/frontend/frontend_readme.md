# Frontend 仕様・統合メモ

この文書は、作業ツリー上の [`core/frontend.sv`](core/frontend.sv) と関連 RTL の現行実装、および統合に向けて確認した仕様・方針をまとめる。
各節の動作説明は現行 RTL に基づく。目標仕様との違いは明示し、未定事項は第 8 節にまとめる。
この文書の作成に伴う RTL 変更は行っていない。

統合に向けた主な方針と実装状況は次のとおり。

| 項目 | 仕様・方針 | 現行 RTL |
| --- | --- | --- |
| FTQ の解放 | commit 時に最古の分岐を解放する | `ftq_pop` による head の更新を実装済み。commit 側との接続は未実施 |
| FTQ の復元 | 分岐予測ミス専用。原因の分岐を残して若い分岐を破棄する | `tail = ftq_restore_idx + 1` を実装済み |
| 例外からの復元 | 現時点では対象外。復元方法は用意しない | 例外専用の復元機構なし |
| backend からの予測器更新 | jump / branch による redirect 時に BTB を更新する | `pc_backend_redirect_src` を更新元 PC、`pc_backend_redirect` を target として登録する |
| 分岐方向予測 | 当面は always-taken。将来、予測器を変更予定 | BPD は常に taken。not-taken の学習・予測改善は現段階では求めない |
| PC 幅 | 16 bit にする予定 | frontend は現在 32 bit。backend の `pc_t` は 16 bit |
| 命令と PC / FTQ index の対応付け | 管理方法は未定 | Fetch Queue に PC / FTQ index の出力なし |

## 1. 構成と責務

frontend は毎サイクル最大 1 命令をフェッチし、Fetch Queue に格納する。
命令メモリ、BTB、分岐方向予測器、F3 での分岐デコード・予測検査、Fetch Queue、FTQ を内包する。
FTQ には全命令ではなく、分岐・ジャンプ命令だけを格納する。

| 構成要素 | ファイル | 現行の役割 |
| --- | --- | --- |
| frontend | [`core/frontend.sv`](core/frontend.sv) | PC 選択、パイプライン、stall / flush、各 Queue への投入 |
| 命令メモリ | [`memory/i_mem.sv`](memory/i_mem.sv) | 固定 2 段の同期読み出し、enable による保持 |
| BTB | [`core/btb.sv`](core/btb.sv) | F1 の PC に対する予測先を F0 に返し、検査用の応答もパイプライン化 |
| BPD | [`core/bpd.sv`](core/bpd.sv) | 常に taken を返す。履歴・学習はない |
| 分岐デコーダ | [`core/br_decoder.sv`](core/br_decoder.sv) | 分岐種別と直接分岐先の計算 |
| 分岐検査 | [`core/br_checker.sv`](core/br_checker.sv) | F3 で BTB 応答とデコード結果を比較 |
| Fetch Queue | [`core/fetchq.sv`](core/fetchq.sv) | 命令だけを保持する FIFO |
| FTQ | [`core/ftq.sv`](core/ftq.sv) | 分岐の PC・種別を保持し、index 指定で読み出すリングバッファ |
| 共通定義 | [`defs/frontend_defs.sv`](defs/frontend_defs.sv) | 応答、分岐種別、FTQ データの型 |

現行の [`core/core_top.sv`](core/core_top.sv) は `stage_if` を使っており、この frontend はまだ接続されていない。
また `stage_if` の `i_mem` インスタンスには、現行 `i_mem` にある `clk` / `en` の接続がない。
既存の 5 段 CPU にそのまま置き換え可能な接続にはなっていない。

## 2. アドレス・パラメータ

- 命令は `isa::instr_t` の 32 bit。ISA はワードアドレッシングで、逐次 PC は `PC + 1`。
  分岐即値にも byte address への変換や左シフトを行わない。
- frontend の PC、redirect 先、FTQ の PC、BTB target は `types::addr_t`（32 bit）。
- PC は統合に向けて **16 bit にする予定**。backend 用の `types::pc_t` は既に 16 bit だが、
  frontend はまだ 32 bit のため、PC の保持・加算・target・ポートなどの幅を揃える必要がある。

| パラメータ | 既定値 | 意味 |
| --- | --- | --- |
| `RESET_PC` | `0` | リセット解除後の初回要求 PC |
| `BTB_IDX_WIDTH` | `7` | BTB のエントリ数は `2^7 = 128` |
| `BTB_TAG_WIDTH` | `9` | BTB の比較用 tag 幅 |
| `FETCHQ_IDX_WIDTH` | `5` | Fetch Queue の配列長は 32、使用可能数は **31** |
| `FTQ_IDX_WIDTH` | `5` | FTQ の配列長は 32、使用可能数は **31** |

両 Queue は head と tail の一致を empty とするため、満杯との区別に 1 スロットを空ける。
Queue の index 幅は 1 以上を前提とする。BTB の index / tag の切り出しは PC 幅内に収める必要がある。

## 3. 外部インターフェース

全状態は `clk` の立ち上がりで更新する。`rst` は active-high の**同期リセット**。
外部の ready、全体 enable、命令メモリ要求・応答ポートはない。

| 信号 | 方向・型 | 接続時の意味 |
| --- | --- | --- |
| `clk`, `rst` | 入力・1 bit | 単一クロックと同期リセット |
| `backend_redirect` | 入力・1 bit | jump / branch による redirect。このエッジで旧経路を破棄し、新 PC の要求と BTB 更新を取り込む |
| `pc_backend_redirect` | 入力・`types::addr_t` | redirect 先のワード PC。同じエッジで BTB の target にも書く |
| `pc_backend_redirect_src` | 入力・`types::addr_t` | redirect を引き起こした jump / branch 命令自身のワード PC。BTB の更新元 PC |
| `fetchq_dout` | 出力・`isa::instr_t` | Queue の先頭命令。組合せ読み出し |
| `fetchq_valid` | 出力・1 bit | Fetch Queue が非 empty であること |
| `fetchq_pop` | 入力・1 bit | 非 empty なら、このエッジで先頭命令を消費する |
| `ftq_get_idx` | 入力・`FTQ_IDX_WIDTH` bit | FTQ の読み出しスロット。head とは独立 |
| `ftq_dout` | 出力・`frontend_pkg::ftq_data_t` | `data[ftq_get_idx]` の組合せ読み出し |
| `ftq_pop` | 入力・1 bit | commit 時に assert し、このエッジで FTQ の最古の分岐エントリを解放する。empty なら無視 |
| `ftq_restore_idx` | 入力・`FTQ_IDX_WIDTH` bit | 分岐予測ミスの backend redirect 時に**最後に残すスロット**。次に書く位置ではない |

`backend_redirect=1` のエッジでは、`pc_backend_redirect_src`、`pc_backend_redirect`、`ftq_restore_idx` を
同じ原因命令に対応させて渡す。`backend_redirect=0` のとき、これらの入力値は使用しない。
BTB 更新は redirect と一体で行い、更新だけを要求する独立したポートはない。

### Fetch Queue の消費

通常は `fetchq_valid && fetchq_pop` のエッジで消費する。
空のときの pop は無視され、`fetchq_dout` の内容に意味はない。
空から push した同じエッジでの pop は成立しない（バイパスなし）。

backend redirect のエッジは Fetch Queue のリセットが優先される。
`fetchq_valid` は redirect を組合せでマスクしていないため、エッジ直前まで旧命令が valid に見える場合がある。
後段でも `rst` / `backend_redirect` を優先し、そのエッジの旧出力を取り込まないこと。
例えば通常の消費条件に `!rst && !backend_redirect` を加える。

`fetchq_pop=0` だけでは frontend は直ちに停止せず、空きがある間はフェッチを続ける。
ステップ実行・halt などの全体停止用 enable は現行インターフェースにはない。

### FTQ の読み出し・解放

`ftq_data_t` の内容は次の 2 項目だけ。

```text
pc            : types::addr_t       // 分岐命令自身の PC
bp_data.btype : branch_type_t       // BR_BRANCH / BR_JAL / BR_JALR
```

予測 taken、予測 target、実際に選択した次 PC、命令本体は保存しない。
`ftq_dout` には valid がなく、未使用・解放済みのスロットでも配列の値を返す。
データ配列はリセット・復元で消去しないため、後段は自分が参照する index の生存期間を管理する必要がある。

`ftq_pop` は `ftq_get_idx` のエントリを消す信号ではなく、head を 1 つ進める信号。
解放は格納順で、**最古の分岐命令の commit 時に `ftq_pop` を assert する**契約とする。
head / tail、full / empty、push 通知、割り当て index は frontend の外へ公開されていない。

## 4. パイプラインとタイミング

| 段 | 処理 |
| --- | --- |
| F0 | 組合せで要求 PC を選択し、命令メモリと BTB に渡す |
| F1 | 要求 PC を保持。BTB はこの PC を組合せ検索し、`resp_F0` として F0 へ返す |
| F2 | 命令メモリの命令と BTB の登録済み応答が揃う |
| F3 | PC・命令・BTB 応答を保持。分岐デコードと検査を行い、Queue へ投入する |

以下は stall、redirect、reset がないときの、ある命令 P に対する時系列。
各行の状態はその立ち上がりエッジの**直後**を表す。

| エッジ | 命令 P の状態 |
| --- | --- |
| E1 | F0 の P を要求として取り込み、`pc_F1=P`。メモリ・BTB の内部要求 PC も P |
| E2 | `pc_F2=P`、`instr_F2` と `btb_resp_F2` が P の結果になる |
| E3 | P が valid な F3 に到達し、投入条件・frontend redirect を組合せ判定 |
| E4 | P を Fetch Queue へ push。分岐なら同時に FTQ へ push |
| E5 | P が先頭で後段が pop する場合、最速でこのエッジで消費 |

立ち上がり直後に成立した F3 の条件は、次のエッジで Queue や PC に反映される。
定常状態では毎サイクル 1 命令を投入・消費できる。

### リセット

`rst=1` のエッジで F1〜F3 の valid、Queue のポインタ、BTB の valid をクリアする。
`reset_pending` を立て、解除後の最初の要求に `RESET_PC` を選ぶ。
初回要求のエッジを E1 とすると、最初の Queue 投入は上表の E4。
解除後、初回要求と同時に backend redirect が来た場合は redirect 先が優先される。
`rst` 自体と redirect が同時なら、状態更新はリセットが優先される。

### Stall

内部の主要条件は次のとおり。

```systemverilog
ftq_ready = !ftq_full || (branch_type_F3 == BR_NONE);
stall = instr_valid_F3 && !(fetchq_ready && ftq_ready);
frontend_advance = !stall || backend_redirect;
fire_instr = instr_valid_F3 && !stall && !backend_redirect;
frontend_redirect_fire = frontend_redirect_F3 && !stall && !backend_redirect;
```

- valid な F3 が必要な Queue に入れないとき、PC、valid、命令、BTB 応答、命令メモリ内部段を一括保持する。
- 非分岐命令は FTQ の空きを必要としない。FTQ が満杯でも流れる。
- F3 が invalid なら Queue が満杯でも停止しない。redirect 後のパイプラインを埋められる。
- Queue の pop は stall 中も動作する。
- full 判定に同時 pop を先取りしない。満杯から pop したエッジでは push せず、次のサイクルから再開する。
- frontend redirect は stall 中には実行・BTB 更新せず、F3 に保持して再開時に実行する。

## 5. PC 選択と分岐予測

通常の要求 PC の優先順位は次のとおり。初回要求だけは、backend redirect がなければ `RESET_PC` を使う。

1. backend redirect の `pc_backend_redirect`
2. F3 の frontend redirect 先
3. valid な F1 に対する BTB hit の target
4. `pc_F1 + 1`

BTB の `resp_F0` は、ポート入力中の新しい F0 PC ではなく、**直前に取り込んだ F1 の PC** に対する応答。
その予測先を次の要求に使うため、学習済みの分岐では分岐自身と予測先を連続サイクルでフェッチできる。
F3 検査用の応答は、同じ検索結果を F2、F3 と進めたもの。

### F3 の分岐分類・修正

`instr.op` の定義は [`defs/isa.sv`](defs/isa.sv) を参照。
`sext` は 32 bit への符号拡張を表す。

| 種別 | デコード条件 | デコード先 PC | 現行 BPD における frontend redirect 条件 |
| --- | --- | --- | --- |
| `BR_NONE` | 下記以外 | `PC + 1` | BTB hit。逐次経路へ戻す |
| `BR_BRANCH` | `{unit, eff, imm} == BRANCH_OP5` | `PC + sext({instr.rd, instr.rest})` | BTB miss、または target 不一致 |
| `BR_JAL` | `{unit, eff, imm} == JAL_OP5` | `PC + sext({instr.rs1, instr.rs2, instr.rest})` | BTB miss、または target 不一致 |
| `BR_JALR` | `{unit, eff, imm} == JALR_OP5` かつ `id == 0` | `PC + 1`（実 target は不明） | 常に補正なし |

BPD は当面 always-taken とし、条件分岐も F3 では taken として扱う。将来、より高性能な予測器に変更する予定。
レジスタ値の比較・実際の成立判定は frontend では行わない。
条件分岐が実際には not-taken の場合、後段から `PC + 1` へ backend redirect する必要がある。

JALR は BTB miss なら逐次経路をフェッチし、F3 でも補正しない。
実 target の解決と必要な redirect は後段で行う必要がある。
backend redirect 時に JALR 自身の PC と解決した redirect 先を BTB に登録するため、
次回以降に hit すればその target を予測に使える。
JALR の BTB 応答は F3 では検査も無効化もしないので、古い target や alias による誤予測も後段で訂正する。

条件分岐が not-taken で backend redirect した場合も、BTB には redirect 先である `PC + 1` を登録する。
次回そのエントリに hit すると、F3 はデコードした分岐先との不一致を検出し、taken 側へ frontend redirect して BTB を再更新する
（分岐先自体が `PC + 1` と一致する場合を除く）。
これは現行 always-taken 構成で受け入れる制約であり、not-taken の学習による予測改善は現段階では求めない。

`br_checker` の条件分岐・JAL に対する一般式は
`(btb.valid ^ bpd.taken) || (btb.valid && decoded_target != btb.target)`。
現在の配線では redirect 先は常に `br_decoder.target_pc` なので、将来 BPD を not-taken 対応にする際は、
redirect 先も逐次 PC と分岐先から選べるよう見直す必要がある。

### BTB の格納・更新

- direct-mapped。index は `PC[IDX_WIDTH-1:0]`、tag はその直上の `TAG_WIDTH` bit。
  ワード PC なので下位 bit を捨てない。
- 既定値では `PC[6:0]` が index、`PC[15:7]` が tag。`PC[31:16]` は比較しないため alias する。
- 全エントリの valid をリセットでクリアする。tag / target の配列値自体はクリアしない。
- 更新条件は `frontend_redirect_fire || backend_redirect`。同時に要求される場合は backend 側を優先する。
- frontend redirect では、F3 の PC に decoded target を書く。
  非分岐への誤 hit は valid を落とす。条件分岐・JAL の miss / target 不一致は valid を立てて登録・置換する。
- backend redirect では、`pc_backend_redirect_src` のエントリに `pc_backend_redirect` を書き、valid を必ず立てる。
  redirect の原因は jump / branch のみという契約に基づき、F3 の命令種別・valid には依存しない。
- backend redirect のエッジでも BTB 全体はクリアせず、指定した 1 エントリだけを登録・置換する。
  旧 F3 に対する frontend 更新は抑止する。どちらの redirect もない場合は更新しない。
- BPD は常に taken を返し、backend からの方向学習は行わない。redirect を伴わない分岐結果も入力しない。
- BTB 単体は検索の `en` と更新の `update_en` が独立。
  frontend redirect の更新は stall 解消まで待つが、backend redirect の更新は stall 中でも同じエッジで行う。
  F2 応答の登録と同じエッジで同じエントリを更新した場合、その F2 応答は更新前の値を使う。

更新データの選択をまとめると次のとおり（`rst=1` のエッジではリセット優先）。

| 条件 | 更新 PC | 更新 target | 更新後 valid |
| --- | --- | --- | --- |
| `backend_redirect=1` | `pc_backend_redirect_src` | `pc_backend_redirect` | `1` |
| `backend_redirect=0` かつ `frontend_redirect_fire=1` | `pc_F3` | `pc_frontend_redirect_F3` | `branch_type_F3 != BR_NONE` |
| 上記以外 | 更新なし | 更新なし | 保持 |

## 6. Redirect と Queue 復元

backend redirect を発生させるのは **jump / branch のみ**で、現時点では**分岐予測ミス専用**とする。
例外は対象に含めず、対応する分岐のない例外からの復元方法は用意していない。

| 項目 | frontend redirect | backend redirect |
| --- | --- | --- |
| 発生・適用 | F3 検査。stall 解消まで待つ | 外部入力。stall 中でも取り込む |
| 現在の F3 | 自分自身を Queue に投入する | 投入しない |
| 旧 F1 / F2 | 無効化 | 無効化 |
| 新しい F0 要求 | decoded target を取り込み、F1 valid を立てる | 外部 target を取り込み、F1 valid を立てる |
| Fetch Queue | 既存エントリを保持 | 全破棄 |
| FTQ | 既存を保持し、当該命令が分岐なら追加 | `ftq_restore_idx` まで保持し、tail を復元 |
| BTB | 当該 F3 のエントリを更新 | 原因命令の PC に redirect 先を登録し valid を立てる。旧 F3 の更新は抑止 |

redirect を取り込んだエッジ直後の valid は `(F1,F2,F3) = (1,0,0)`。
新 PC の要求はそのエッジで既に発行しており、翌サイクルに出し直す構成ではない。
stall がなければ、新経路の先頭はその 3 エッジ後に Queue へ投入される。
frontend redirect 自身の命令は残るため、その命令と修正先の投入の間には 2 サイクルの空きが入る。

backend redirect は frontend redirect に優先する。
連続して assert した場合は毎エッジで経路を置き換え、最後に指定した経路だけが残る。
BTB 更新も各エッジで実行されるため、それぞれの原因 PC と redirect 先を対応させる。
従って 1 回だけ redirect したい場合は、要求を取り込ませた後に deassert する。

### FTQ 復元の正確な意味

backend redirect のエッジで、FTQ は次を行う。

```text
tail := ftq_restore_idx + 1   // index 幅で折り返す
head := 変更しない           // ただし同時 ftq_pop は別途成立し得る
push := 抑止
```

例えば分岐スロット 5 に戻すと、スロット 5 は残り、次の書き込み位置は 6 になる。
より若い領域の配列値は残るが、Queue の有効範囲から外れる。
同時 `ftq_pop` は復元前に非 empty なら成立し、head を 1 つ進める。restore が pop を打ち消すわけではない。

復元 index の妥当性や、生存範囲内であることを検査する回路はない。
全体を空にする操作は `tail=head` となる位置への復元だが、head は外部に公開されない。
例外など「残す分岐がない redirect」の復元は、現時点の仕様では対象外。

## 7. 命令メモリを置き換える際の条件

現行 `i_mem` は 1024 ワードの仮置きメモリで、`addr[9:0]` だけを使う。
範囲外アドレスを検出せず、上位 bit が違う PC も同じ命令を読む。
Verilator では `+imem=<path>`、未指定時およびそれ以外では `fib.mem` を `$readmemh` で読む。
内容は reset では再ロードしない。

置き換え先は、少なくとも次の契約を満たす必要がある。

- `en=1` の立ち上がりで要求 PC を受け付け、次の `en=1` の立ち上がりでその命令を出力する 2 段構成。
- 毎サイクル要求を受け付けられる。
- `en=0` では内部アドレス段と出力段の両方を保持し、frontend の PC / valid と対応を崩さない。
- redirect の際も新しい要求を同じエッジで受け付ける。旧応答は valid で破棄される。

可変レイテンシ、cache miss、要求側 ready、応答側 valid、fetch fault には現行 RTL は対応していない。
I-cache や外部バスを接続する場合は、内部の valid・stall 制御も含めた変更が必要。

## 8. 未定事項・統合に向けて必要な変更

以下は接続先の設計と合わせて決める、または実装する必要がある。

1. **命令と PC / FTQ index の対応付け（未定）**：Fetch Queue の出力には PC も FTQ index もない。
   分岐だけ FTQ に入るため、通常命令の PC をどこで保持・再構成するか、分岐の割り当て index をどこで管理するかは未定。
   F3 で内部 redirect が発生することも含めて対応を維持する必要がある。
2. **FTQ と commit の接続**：分岐 commit 時の `ftq_pop` を接続する。
   redirect と同時に pop を許す条件は、head が進む現行動作を踏まえて決める。
3. **将来の予測器への変更**：現状は always-taken と、backend redirect 時の BTB 更新を使う。
   将来の BPD、方向学習に渡す情報、redirect を伴わない更新のインターフェースは今後設計する。
   後段での予測ミス判定に必要な予測 next PC などの保持方法も未定。
4. **PC の 16 bit 化（予定・未実装）**：frontend の PC、redirect 先、BTB target、FTQ の PC を含めて幅を揃える。
   共用の `addr_t` 自体を変更するか、PC 用の型を使うかという実装方法は未定。

## 9. 検証用ファイル

frontend の回帰テストは [`../test/frontend/`](../test/frontend/README.md)、BTB 単体テストは
[`../test/btb/`](../test/btb/README.md) にある。WSL / Linux の Verilator 環境向けのコマンドは次のとおり。

```sh
make -C test/frontend lint
make -C test/frontend
make -C test/btb
```

frontend テストには、逐次フェッチ、リセットベクタ、cold / warm JAL、学習済みループ、
Queue 満杯時を含む redirect、stall 中の frontend redirect 保持、redirect の優先順位を検査する記述がある。
2026-11-12 に現行ソースで上記 lint と frontend 回帰テストの成功を確認した（300 checks）。
テストは `fetchq_valid` / `fetchq_ready` を使い、`pc_backend_redirect_src` の接続・駆動と原因 PC への BTB 学習も検証する。
条件分岐の実行結果や JALR の実 target、後段との PC / FTQ index の対応付けは、このテストでは検証していない。
複数命令供給へ拡張する際の制約と追加検証項目は [`docs/knowledge/frontend-multiway.md`](../../docs/knowledge/frontend-multiway.md) を参照。
