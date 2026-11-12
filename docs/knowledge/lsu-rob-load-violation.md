# LSU → ROB の load violation 通知

確認日: 2026-11-12。

- `src/backend/defs/rob_types.sv` の `load_violation_t` は `valid` と `rob_idx` を持ち、コメント上は最古の violation を通知する契約。一般的な例外原因・障害アドレスのフィールドはない。
- 宣言済みの通知経路は `ldq.load_violation` → `lsu_top.load_violation` → `backend_top.load_violation`。LSU 側の port が存在することと、通知が生成されることを区別する。
- 未実装: `src/backend/lsu/lsu_searcher.sv` と `ldq.sv` はロジックが未実装で、違反検出・最古選択・通知生成は動作しない。`src/backend/rob/rob.sv` には受信 port と対象 entry の `excp` を立てる処理が追加されているが、`backend_top.sv` は ROB を instantiate していない。
- ROB へ接続する際は、通知対象の valid entry への記録と、同 cycle の分岐 kill・commit との優先順位を定める必要がある。現在の `excp` は load violation 専用というコメントであり、一般的な trap 情報を保持する型ではない。
- 検証済みの制約: 複数 bank の commit scan は `busy` だけでなく `excp` でも停止する必要がある。`rob.sv` の `detect_head_exception` は最古の valid bank だけを見るため、その前の正常命令と違反 load を同時 commit すると flush の機会を失う。現在の `commit_flags` は `valid && (busy || excp)` で停止し、記録済みの違反 load とそれ以降の commit を抑止する。
- 未確定の契約: violation 通知が、対象 load の `busy=0` による commit 可能化までに必ず完了するかを LSU 接続前に確認する。`rob.sv` の `clr_bsy_on_comp` は WB で busy を解除し、`commit_flags` は保存済みの busy/excp を見る。通知まで `busy=1` が維持されるなら安全で、WB と violation が同 cycle でも、更新前の `busy=1` が commit を止め、同じクロック端で `busy=0, excp=1` になる。一方、既に `busy=0` の load に遅れて通知できる契約なら、到着 cycle の対象 load と後続命令の commit 抑止が必要。この保証は未確認であり、ROB の無条件の不具合とは断定しない。
- 2026-11-11 の限定単体検証で、WB 済みの head load に violation を通知すると、到着 cycle は `com_mask=1, flush=0`、次 cycle は `valid=0, flush=0` となることを再現した。2026-11-12 に現行 RTL（Verilator、DISPATCH_W=2）でも再確認。`excp=1` は無効化済み entry に残り、flush の機会を失う。一方、事前に記録済みの bank1 の violation は bank0 の正常命令だけを commit させ、次 cycle に flush することも確認した。これは WB 済み head への遅延通知を許す場合の ROB 単体の挙動であり、未実装 LSU を含む統合動作の検証ではない。検証用の型定義補正条件は `rob-brmask-boom.md` を参照。
