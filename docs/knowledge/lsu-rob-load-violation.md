# LSU → ROB の load violation 通知

確認日: 2026-11-11。

- `src/backend/defs/rob_types.sv` の `load_violation_t` は `valid` と `rob_idx` を持ち、コメント上は最古の violation を通知する契約。一般的な例外原因・障害アドレスのフィールドはない。
- 宣言済みの通知経路は `ldq.load_violation` → `lsu_top.load_violation` → `backend_top.load_violation`。LSU 側の port が存在することと、通知が生成されることを区別する。
- 未実装: `src/backend/lsu/lsu_searcher.sv` と `ldq.sv` はロジックが未実装で、違反検出・最古選択・通知生成は動作しない。`src/backend/rob/rob.sv` には受信 port と対象 entry の `excp` を立てる処理が追加されているが、`backend_top.sv` は ROB を instantiate していない。
- ROB へ接続する際は、通知対象の valid entry への記録と、同 cycle の分岐 kill・commit との優先順位を定める必要がある。現在の `excp` は load violation 専用というコメントであり、一般的な trap 情報を保持する型ではない。
- 検証済みの制約: 複数 bank の commit scan は `busy` だけでなく `excp` でも停止する必要がある。`rob.sv` の `detect_head_exception` は最古の valid bank だけを見るため、その前の正常命令と違反 load を同時 commit すると flush の機会を失う。現在の `commit_flags` は `valid && (busy || excp)` で停止し、記録済みの違反 load とそれ以降の commit を抑止する。
- 未確定の契約: `load_violation` 到着 cycle に対象 load の commit を許すか。現在の ROB は `excp` を FF に記録するだけで同 cycle の commit 判定に反映しないため、接続前に通知タイミングまたは commit 抑止を定義する必要がある。
