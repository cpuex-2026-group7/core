# ROB の branch mask 更新方針と BOOM の参照先

調査日: 2026-11-10。BOOM は公式 `riscv-boom/riscv-boom` の commit `ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428` を参照する。以下の BOOM の方式と、このリポジトリで確認した契約・未解決事項を区別する。

## 検証した BOOM の実装

- **v3** は各 ROB entry の旧 `br_mask` と `b1.mispredict_mask` を照合して kill し、生存する valid entry は `br_mask & ~b1.resolve_mask` に更新する。通常完了だけでなく、予測ミスを含む分岐解決を扱う。[v3 ROB L415-L428](https://github.com/riscv-boom/riscv-boom/blob/ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428/src/main/scala/v3/exu/rob.scala#L415-L428)、[公式 utility の IsKilledByBranch / GetNewBrMask](https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v3/util/util.scala#L45-L84)
- `resolve_mask` は全 valid 分岐の tag の OR、`mispredict_mask` は valid かつ mispredict の tag の OR。`b1` が mask の早期更新、レジスタを挟む `b2` が最古の mispredict の詳細情報を運ぶ。v3 ROB の tail 復旧は `b2` で行われる。この二段構成は timing の設計であり、今回の RTL が必ず同じ遅延を採る必要はない。[v3 core L163-L200](https://github.com/riscv-boom/riscv-boom/blob/ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428/src/main/scala/v3/exu/core.scala#L163-L200)、[v3 ROB tail L709-L729](https://github.com/riscv-boom/riscv-boom/blob/ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428/src/main/scala/v3/exu/rob.scala#L709-L729)
- **v4 は異なる**。通常 ROB entry は `b2` の ROB row/bank と head を基準に若い命令を無効化し、v3 の entry mask kill/update はコメントアウトされている。したがって「現行 BOOM の ROB は必ず全 entry の mask を更新する」と一般化しない。別保持の例外 uop は引き続き mask を更新して kill を判定する。[v4 row/bank mask L271-L276](https://github.com/riscv-boom/riscv-boom/blob/ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428/src/main/scala/v4/exu/rob.scala#L271-L276)、[v4 entry kill L439-L457](https://github.com/riscv-boom/riscv-boom/blob/ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428/src/main/scala/v4/exu/rob.scala#L439-L457)、[v4 exception tracking L627-L631](https://github.com/riscv-boom/riscv-boom/blob/ba03175e0a3cf5c0d5a7f14d385ac1c8998c4428/src/main/scala/v4/exu/rob.scala#L627-L631)

## このリポジトリの契約と推奨

確認済み: `src/defs/ooo_types.sv` の `br_update_t` と、その生成元 `src/backend/ex/ex_top.sv` は、正解決だけを `resolve_mask`、予測ミスだけを `kill_mask` に含める。ROB は旧 mask で kill を判定してから生存 entry の resolve bit を消す方式なので、この契約は整合する。BOOM の全 valid 解決方式と混同しない。正しく解決した分岐の tag を消さないまま再利用すると、古い依存 bit を持つ生存命令が後続の別分岐の mispredict で誤って kill される。

1. 正解決と予測ミスの両方の通知が必要。現在は `br_update_t` で受ける。複数ポート数は dispatch 幅ではなく分岐解決帯域として定義する。
2. 現在の生成元では正解決から `resolve_mask`、予測ミスから `kill_mask` を作る。以下の `mispredict_mask` はこの `kill_mask` に相当する。
3. 各既存 valid entry について、**更新前の mask** で `kill = |(old_mask & mispredict_mask)` を判定。kill なら valid を落とし、それ以外は `old_mask & ~resolve_mask` を保存する。先に bit を消してから kill を判定すると予測ミスを見逃す。
4. mask 更新は dispatch の有無や writeback と独立に毎 cycle 適用する。他の分岐が mispredict した cycle でも、生存 entry に対する正解決の通知を失わないこと。`kill_mask` の有無で分けた双方の経路に更新が必要。
5. `src/backend/defs/rob_types.sv` の `entry.brmask` と `entry.uop.brmask` は二重保持。片方だけ更新しない。mask の保持元を一つにして commit 出力をそこから構成するか、両方の一致を維持する。
6. 新規 dispatch と同 cycle の解決も整合させる。上流が既に mask を更新している契約を確認し、そうでなければ取り込む uop も旧 mask による kill と resolve bit 除去を行う。解決 tag の同 cycle 再割当ては、新しい依存 bit まで消さないよう割当て・通知の世代/タイミング契約を定める。
7. 複数 mispredict の mask は OR できるが、tail 復旧先は**最古**の mispredict を選ぶ。現在の `ex_top.sv` は他の mispredict に依存しない分岐の復旧情報を `br_update.rob_idx` に渡す。bank/row 型なので ROB の `+1` は row 単位であり、同じ row 内の若い bank の無効化は mask 側で担う。

`src/backend/defs/back_types.sv` の既存 `br_resolved()` は正解決だけを消す。kill を先に適用する設計なら、mispredict tag を持つ entry 自体が kill されるため、生存 entry に対しては全 valid 解決方式と同じ結果になり得る。helper 単体を不正と断定しない。

更新時の不変条件: 新規 dispatch と既存 entry の mask 更新は同じ slot に競合し得る。`rob.sv` の同じ `always_ff` 内で、新規 mask の代入より後に全 entry へ旧 mask ベースの代入を置くと、後の nonblocking assignment が優先され、新規 mask を失う。割当て slot は入力 mask、既存 slot は保存 mask を元に次状態を一度だけ決める必要がある。

## Branch tag の割当て境界（2026-11-11 確認）

- 現行 `src/` に branch tag allocator/free list はない。`src/frontend/frontend.sv` の `br_tag management` は TODO。`src/common/find_empty_slot.sv` は bitmap から空きを選ぶ組合せ回路のみで、使用中状態・解放・復旧は管理しない。
- backend は割当て済み tag を入力する契約。`disp_uop_t.br_tag` → `iq_int` / `iq_float` の payload → `rf_top` → `eu_0_top` / `eu_2_top` → `ex_top` の解決 mask、という経路。したがって frontend/decode のどちらで割り当てても、dispatch 受理時には tag と対応する `brmask` が必要。
- LSU は別入力の `disp_br_valid` / `disp_br_tag` を `backend_top` → `lsu_top` → `ldq` / `stq` に渡す。ただし両 Queue の tag 別 `tail_snapshot[MAX_BR]` は宣言のみで、保存・復旧処理は未実装。
- `test/ex_top/tb_ex_top.sv` の `alloc` / `tag_age` と `test/backend_top/tb_backend_top.sv` の `tag_owner` / `tag_free_at` はテスト用管理であり、RTL の allocator ではない。frontend 割当てを選ぶ場合、現行 `fetchq.sv` は命令だけを保持するため tag/mask の搬送も追加設計が必要。

## 実装時に確認するケース

正解決後の tag 再利用、同 cycle の正解決と別分岐の mispredict、旧 mask による kill、新規 dispatch と解決の同時発生、複数 mispredict の最古選択、同一 row の分岐より後ろの bank の kill。動作シミュレーションは未実行。
