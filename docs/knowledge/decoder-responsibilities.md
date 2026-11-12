# Decoder と dispatch の責務境界

確認日: 2026-11-12。`src/decoder/decoder.sv` は即値・EU判定を書き始めた実装途中。以下は既存 backend の消費側から確認した契約と、それに基づく分担案。

- **分担案: decode で `dest_eu / dest_fu / fu_op / lat` を生成する。** `src/defs/uop_types.sv` に符号があり、IQ はそのまま使用する。`iq_core.sv` は `dest_eu - EU_BASE` で issue port の bitmap を選び、`dest_fu` で FU の blocked を参照するため、現構成では dispatch 前に行先が必要。`fu_op` は FU ごとの局所符号で、単独では演算を識別できない。
- **確認済み: `lat` は総実行時間ではなく fast wakeup の待ち時間。** `iq_core.sv` の `sending_wakeup` が入力 `lat` を送信し、依存ソースは countdown が 0 になると ready。issue cycle を i とすると既存 backend テストの契約は依存命令が最速 i+1+lat に issue。`LAT_FAST=0`、FMUL=1、ITOF/FTOI=2、FADD/FSUB=3。符号は `uop_types.sv`、使用例は `test/backend_top/tb_backend_top.sv`。MEM と FDIV/FSQRT は `iq_mem.sv` / `iq_float.sv` の `SLOW_WAKEUP_FU` により issue 時 wakeup を抑止する。FSQRT/FDIV は `eu_4_top.sv` が完了時に LAT_FAST で通知。LSU controller の通知処理は未実装なので load 完了通知の実動作は未確認。
- **分担案: `ldq_idx / stq_idx` は dispatch 時に LSU から受け取り、dispatch 側で uop に反映する。** `backend_top.sv` → `lsu_top.sv` → `ldq.sv / stq.sv` に割当て index 出力があるが、Queue 本体は未実装。decode では空き状態・復旧状態を持たない。IQ/ROB/LSU の受理と割当てを一致させ、stall 中に二重確保しない契約が必要。
- **未確定: 反対側 Queue の tail の配送。** `uop_types.sv` のコメントは load に自分の LDQ index と dispatch 時 STQ tail、store に自分の STQ index と dispatch 時 LDQ tail を要求する。一方、`st_dep_t` は同 cycle の先行 store を含む依存 mask と STQ tail を STQ→LDQ に送る形式で、STQ entry には LDQ tail がない。自分の index 出力を反対側 Queue の tail と同一視せず、必要性と配送経路を LSU 実装時に確定する。
- **レジスタの境界:** `disp_uop_t.rd/rs1/rs2` は `preg_t`。物理 index の割当て/検索は rename の責務だが、論理レジスタ番号、I/F の種別、使用有無 (`PREG_TYPE_NONE`) の命令解釈は decode で必要。decode から即 `disp_uop_t` を完成させるには rename 前の情報を運ぶ中間形式または別信号が必要。
- PC/予測 next PC/FTQ index の搬送不足は [frontend-multiway.md](frontend-multiway.md)、branch tag allocator の未実装と mask 規約は [rob-brmask-boom.md](rob-brmask-boom.md) を参照。現 `fetch_packet_t` は命令配列しか持たず、メタデータを decode で単にコピーできる状態ではない。

## is_store と命令内容の保持（2026-11-12 追記）

- `is_store` の実装済みの判断箇所は `iq_mem.sv` の `to_issue_part = is_store ? 2'b11 : 2'b01`。`iq_core.sv` は bit0 を rs1 の ready（load/store address）、bit1 を rs2 の ready（store data）で独立発行し、全 pending bit の発行後に entry を解放する。store は IQ 内では一つの entry のまま、STA/STD を別 cycle または同 cycle に発行できる。
- `is_store` は `mem_payload_t` → `rr_ex_mem_t.payload` → `eu_1_top` の meta → `ex_lsu_t` に搬送される。`addr_valid` は LDA/STA、`data_valid` は STD を示す。LSU controller は `ex_lsu_t` を受けるが本体未実装なので、load/store の振分けや D$ の write enable への変換はまだ動作しない。`lsu_tag_t.is_store` も宣言のみであり、uop の bit との接続を実装済みと扱わない。
- 命令全体のビット列は `disp_uop_t` に保持されない。演算は EU/FU/fu_op、オペランドは preg と即値、制御は PC/予測/tag/index 等に分解される。IQ はスケジューリング情報を `wrapper_ff_t iq_ff[SIZE]`、実行 payload を同じ slot の `payload_ram` に分けて保持する（`iq_core.sv`）。issue 後は `iq_rr_t` と payload、RF 読出し後は `rr_ex_*_t.common`（値を追加）と payload で搬送する。
- INT/FLOAT payload は `fu_op` を持つが、MEM payload は持たない（`backend/defs/iq_types.sv`）。AGU は共通のアドレス計算で、load/store は `is_store`、整数/浮動小数点データは preg の typ で区別する。`FU_OP_AGU` は定数として存在するが、現 MEM 経路で搬送・参照されない。`is_store=0` だけではメモリ命令であるとは判定できず、MEM 経路でのみ load の意味になる。
- **decoder 実装時の即値契約:** `ex_top.sv:extend_imm` は C/D をともに `imm[14:0]` から符号拡張する。旧 `core/imm_extend.sv` の D 形式は `{instr[24:20], instr[9:0]}` なので、新 decoder は D の分散ビットを先に下位15 bitへ連結して渡す必要がある。単に全形式で `instr[19:0]` をコピーすると D の即値を誤る。これは消費側と旧命令形式から導かれる入力要件で、未実装 decoder の動作確認ではない。

静的調査のみ。decoder と LSU Queue が未実装のため、統合動作は検証していない。

## dest_eu の論理変形で保持する優先順位（2026-11-12）

- `src/decoder/decoder.sv` の `1101111` は VERY_LONG の完全一致と LONG の `11011??` の両方に一致する。現三項演算子は VERY_LONG を優先するため、そのまま条件を並列ORしたり `unique casez` に移したりすると契約を壊す。
- LONG の排他的な集合は `10110?? / 1101000 / 110110? / 1101110`。MEM判定を M、VERY_LONG判定を V、この排他的LONG判定を L とすると、現 `src/defs/uop_types.sv` の符号（ALU=0, MEM=1, F_SHORT=2, F_LONG=3, F_VERY_LONG=4）では `dest_eu = {V, instr[31] & ~V, M | L}`。元の式との一致は上位7 bitの全128通りの0/1入力で確認済み。X/Zを含む4値等価性と合成後の遅延改善は未検証であり、RTLへの採用はしていない。
