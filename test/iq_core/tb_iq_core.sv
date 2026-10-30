`timescale 1ns / 1ps
`default_nettype none

// iq_core のテストベンチ（Verilator の --binary --timing で動かす）
//
// IQ の構成はビルド時に -G で決める（Makefile の CONFIGS を参照）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 参照モデルは RTL のカウンタを写さず、各ソースが「何サイクル目から使えるか」を絶対時刻で持つ。
// 毎サイクル次のものを独立に計算して DUT と突き合わせる
//   - issued / issued_dest_fu / sending_wakeup / disp_full（組み合わせ出力）
//   - 次のサイクルの rr_ff / rr_payload
//
// テストの前提にしている仕様
//   - サイクル t に latency=L の wakeup が来たら、t+1+L から issue できる（L は「レイテンシ-1」）
//   - dispatch で counting=1, cnt=C として入れたソースは t+1+C から使える
//   - 既に wakeup 済みのソースに来た wakeup は無視する
//   - ポートごとに、受け付ける FU の ready なものから一番古いものを出す（同じサイクルの dispatch はレーン番号の小さい方が古い）
//   - BLOCKING_FU には issue してから ISSUE_TO_FU(=2) サイクル出さない。dest_fu_blocked が立っている FU にも出さない
//   - SLOW_WAKEUP_FU と rd が NONE の命令は issue 時に wakeup を出さない
//   - mispredict した分岐に依存するものは、そのサイクルに issue せず消える。dispatch 中のものも入らない
//   - 当たった分岐は brmask のビットを落とす（rr_ff に出るものも含む）
//   - レーン i の dispatch は、サイクル頭の空きが i+1 個以上のときだけ入る。入らなかったものは捨てられる
//   - flush のサイクルは issue せず、中身も同じサイクルの dispatch も全部消える
//   - rst は最初にしか使わない（rst 中の issued は見ない）

module tb_iq_core
  import types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int ISSUE_W = 1,
  parameter int DEST_FU_NUM = 1,
  parameter logic [DEST_FU_NUM-1:0][ISSUE_W-1:0] FU_LISTEN_PORT = '1,
  parameter logic [DEST_FU_NUM-1:0] SLOW_WAKEUP_FU = '0,
  parameter logic [DEST_FU_NUM-1:0] BLOCKING_FU = '0
);

  localparam int EXT_W = 3;  // テストから流す wakeup のレーン数
  localparam int WAKEUP_W = ISSUE_W + EXT_W;
  localparam int PAYLOAD_W = 64;
  localparam int ISSUE_TO_FU = 2;
  localparam int MAX_ERRORS = 30;

  typedef logic [63:0] cyc_t;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst;
  logic flush;
  logic disp_valid[DISPATCH_W];
  wrapper_ff_t disp_entry[DISPATCH_W];
  logic [PAYLOAD_W-1:0] disp_payload[DISPATCH_W];
  logic disp_full;
  wakeup_t coming_wakeup[WAKEUP_W];
  wakeup_t sending_wakeup[ISSUE_W];
  wakeup_t ext_wakeup[EXT_W];
  br_update_t br_update[1];
  logic dest_fu_blocked[DEST_FU_NUM];
  logic issued[ISSUE_W];
  dest_fu_t issued_dest_fu[ISSUE_W];
  iq_rr_t rr_ff[ISSUE_W];
  logic [PAYLOAD_W-1:0] rr_payload[ISSUE_W];

  // DUT につなぐ側。initial の中から直接書くと Verilator 5.020 の --timing で
  // DUT の組み合わせ回路が評価し直されないことがあるので、立ち下がりで写す
  logic d_rst;
  logic d_flush;
  logic d_disp_valid[DISPATCH_W];
  wrapper_ff_t d_disp_entry[DISPATCH_W];
  logic [PAYLOAD_W-1:0] d_disp_payload[DISPATCH_W];
  wakeup_t d_ext_wakeup[EXT_W];
  br_update_t d_br_update[1];
  logic d_dest_fu_blocked[DEST_FU_NUM];

  always @(negedge clk) begin
    d_rst <= rst;
    d_flush <= flush;
    d_disp_valid <= disp_valid;
    d_disp_entry <= disp_entry;
    d_disp_payload <= disp_payload;
    d_ext_wakeup <= ext_wakeup;
    d_br_update <= br_update;
    d_dest_fu_blocked <= dest_fu_blocked;
  end

  // 自分が出した wakeup は自分にも戻す
  always_comb begin
    for (int p = 0; p < ISSUE_W; p++) coming_wakeup[p] = sending_wakeup[p];
    for (int x = 0; x < EXT_W; x++) coming_wakeup[ISSUE_W+x] = d_ext_wakeup[x];
  end

  iq_core #(
    .SIZE(SIZE),
    .DISPATCH_W(DISPATCH_W),
    .ISSUE_W(ISSUE_W),
    .DEST_FU_NUM(DEST_FU_NUM),
    .FU_LISTEN_PORT(FU_LISTEN_PORT),
    .SLOW_WAKEUP_FU(SLOW_WAKEUP_FU),
    .BLOCKING_FU(BLOCKING_FU),
    .WAKEUP_W(WAKEUP_W),
    .BR_UPDATE_W(1),
    .PAYLOAD_W(PAYLOAD_W)
  ) dut (
    .clk(clk),
    .rst(d_rst),
    .flush(d_flush),
    .disp_valid(d_disp_valid),
    .disp_entry(d_disp_entry),
    .disp_payload(d_disp_payload),
    .disp_full(disp_full),
    .coming_wakeup(coming_wakeup),
    .sending_wakeup(sending_wakeup),
    .br_update(d_br_update),
    .dest_fu_blocked(d_dest_fu_blocked),
    .issued(issued),
    .issued_dest_fu(issued_dest_fu),
    .rr_ff(rr_ff),
    .rr_payload(rr_payload)
  );

  // ---------------- 乱数（xorshift64） ----------------

  logic [63:0] rng_state;

  function automatic int rnd(int n);
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return int'(rng_state % 64'(n));
  endfunction

  // ---------------- 値を作る補助 ----------------

  function automatic preg_t mk_preg(preg_type_t t, int i);
    preg_t p;
    p.typ = t;
    p.idx = preg_idx_t'(i);
    return p;
  endfunction

  function automatic preg_t pi(int i);
    return mk_preg(PREG_TYPE_INT, i);
  endfunction

  function automatic preg_t pf(int i);
    return mk_preg(PREG_TYPE_F, i);
  endfunction

  function automatic preg_t pn();
    return mk_preg(PREG_TYPE_NONE, 0);
  endfunction

  // 読まないソース（wrapper は counting=1, cnt=0 で入れる）
  function automatic src_reg_t s_none();
    src_reg_t s;
    s.preg = pn();
    s.st.counting = 1'b1;
    s.st.cnt = '0;
    return s;
  endfunction

  // もう wakeup 済みで、あと c サイクル
  function automatic src_reg_t s_rdy(preg_t p, int c);
    src_reg_t s;
    s.preg = p;
    s.st.counting = 1'b1;
    s.st.cnt = cnt_down_t'(c);
    return s;
  endfunction

  // まだ wakeup が来ていない
  function automatic src_reg_t s_wait(preg_t p);
    src_reg_t s;
    s.preg = p;
    s.st.counting = 1'b0;
    s.st.cnt = '0;
    return s;
  endfunction

  function automatic wrapper_ff_t ent(preg_t rd, src_reg_t a, src_reg_t b, int lat, int fu, brmask_t bm);
    wrapper_ff_t e;
    e.rd = rd;
    e.rs1 = a;
    e.rs2 = b;
    e.lat = latency_t'(lat);
    e.dest_fu = dest_fu_t'(fu);
    e.brmask = bm;
    return e;
  endfunction

  function automatic brmask_t bit_of(int b);
    brmask_t m = '0;
    m[b] = 1'b1;
    return m;
  endfunction

  // ---------------- 参照モデル ----------------

  typedef struct packed {
    logic valid;
    logic [31:0] id;
    cyc_t seq;  // 小さいほど古い
    preg_t rd;
    preg_t rs1;
    preg_t rs2;
    logic w1;  // wakeup 済みか
    logic w2;
    cyc_t r1;  // このサイクルから使える
    cyc_t r2;
    latency_t lat;
    dest_fu_t fu;
    brmask_t brmask;
    logic [PAYLOAD_W-1:0] payload;
  } ment_t;

  ment_t m[SIZE];
  cyc_t next_seq;
  logic memo_v[DEST_FU_NUM];
  cyc_t memo_at[DEST_FU_NUM];

  cyc_t cyc;
  int exp_idx[ISSUE_W];
  logic exp_rr_valid[ISSUE_W];
  ment_t exp_rr[ISSUE_W];
  cyc_t issued_at[int];

  int errors;
  longint checks;
  string test_name;
  int n_tests;
  int n_fail;

  // カバレッジ用の数
  longint st_issue[ISSUE_W];
  longint st_kill;
  longint st_drop_kill;
  longint st_drop_full;
  longint st_full_cycles;
  longint st_alloc_wake;
  longint st_rewake;
  longint st_memo_block;
  longint st_input_block;
  longint st_flush;
  longint st_resolve;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[NG] %s: cycle %0d: %s", test_name, cyc, msg);
    if (errors == MAX_ERRORS) begin
      $display("エラーが %0d 個になったので打ち切る", MAX_ERRORS);
      $fatal(1, "FAIL");
    end
  endtask

  function automatic logic killed_by(brmask_t bm);
    return br_update[0].valid && br_update[0].mispredict && bm[br_update[0].tag];
  endfunction

  function automatic brmask_t resolve_mask(brmask_t bm);
    brmask_t r = bm;
    if (br_update[0].valid && !br_update[0].mispredict) r[br_update[0].tag] = 1'b0;
    return r;
  endfunction

  function automatic logic memo_blocked(int f);
    return memo_v[f] && (cyc - memo_at[f] <= cyc_t'(ISSUE_TO_FU));
  endfunction

  function automatic int occupancy();
    int n = 0;
    for (int e = 0; e < SIZE; e++) if (m[e].valid) n++;
    return n;
  endfunction

  function automatic int port_of(int f);
    for (int p = 0; p < ISSUE_W; p++) if (FU_LISTEN_PORT[f][p]) return p;
    return -1;
  endfunction

  // サイクル頭の状態と入力から、このサイクルに各ポートが出すエントリを決める
  task automatic compute_expect();
    for (int p = 0; p < ISSUE_W; p++) begin
      exp_idx[p] = -1;
      if (flush || rst) continue;
      for (int e = 0; e < SIZE; e++) begin
        if (!m[e].valid || killed_by(m[e].brmask)) continue;
        if (!FU_LISTEN_PORT[m[e].fu][p]) continue;
        if (!(m[e].w1 && cyc >= m[e].r1 && m[e].w2 && cyc >= m[e].r2)) continue;
        if (dest_fu_blocked[m[e].fu]) begin
          st_input_block++;
          continue;
        end
        if (memo_blocked(int'(m[e].fu))) begin
          st_memo_block++;
          continue;
        end
        if (exp_idx[p] < 0 || m[e].seq < m[exp_idx[p]].seq) exp_idx[p] = e;
      end
    end
  endtask

  task automatic check_comb();
    logic exp_full;
    logic exp_wv;
    ment_t e;
    if (rst) return;
    exp_full = (SIZE - occupancy()) < DISPATCH_W;
    if (exp_full) st_full_cycles++;
    checks++;
    if (disp_full !== exp_full)
      fail($sformatf("disp_full=%0b 期待=%0b（中身 %0d/%0d）", disp_full, exp_full, occupancy(), SIZE));
    for (int p = 0; p < ISSUE_W; p++) begin
      checks++;
      if (exp_idx[p] < 0) begin
        if (issued[p] !== 1'b0) fail($sformatf("port%0d が issue した（期待は issue なし）", p));
        else if (sending_wakeup[p].valid !== 1'b0) fail($sformatf("port%0d が issue していないのに wakeup を出した", p));
        continue;
      end
      e = m[exp_idx[p]];
      if (issued[p] !== 1'b1) begin
        fail($sformatf("port%0d が issue しない（期待は id %0d）", p, e.id));
        continue;
      end
      if (issued_dest_fu[p] !== e.fu) fail($sformatf("port%0d issued_dest_fu=%0d 期待=%0d", p, issued_dest_fu[p], e.fu));
      exp_wv = !SLOW_WAKEUP_FU[e.fu] && e.rd.typ != PREG_TYPE_NONE;
      if (sending_wakeup[p].valid !== exp_wv)
        fail($sformatf("port%0d sending_wakeup.valid=%0b 期待=%0b（id %0d）", p, sending_wakeup[p].valid, exp_wv, e.id));
      else if (exp_wv && (sending_wakeup[p].preg !== e.rd || sending_wakeup[p].latency !== e.lat))
        fail($sformatf("port%0d sending_wakeup preg=%h lat=%0d 期待 preg=%h lat=%0d", p, sending_wakeup[p].preg,
                       sending_wakeup[p].latency, e.rd, e.lat));
    end
  endtask

  // ソースに wakeup を当てる。当たったら 1
  function automatic logic wake_src(inout logic w, inout cyc_t r, input preg_t s, input logic wv[WAKEUP_W],
                                    input preg_t wp[WAKEUP_W], input latency_t wl[WAKEUP_W]);
    logic hit = 1'b0;
    for (int k = 0; k < WAKEUP_W; k++) begin
      if (!wv[k] || wp[k] != s) continue;
      if (w) begin
        st_rewake++;
      end else begin
        w = 1'b1;
        r = cyc + 1 + cyc_t'(wl[k]);
        hit = 1'b1;
      end
    end
    return hit;
  endfunction

  // クロックの後でモデルを 1 サイクル進める
  task automatic model_advance();
    logic wv[WAKEUP_W];
    preg_t wp[WAKEUP_W];
    latency_t wl[WAKEUP_W];
    int free_slots;
    int idx;
    int j;
    logic hit;

    free_slots = SIZE - occupancy();
    for (int p = 0; p < ISSUE_W; p++) begin
      idx = exp_idx[p];
      wv[p] = 1'b0;
      wp[p] = '0;
      wl[p] = '0;
      exp_rr_valid[p] = idx >= 0;
      exp_rr[p] = '0;
      if (idx >= 0) begin
        exp_rr[p] = m[idx];
        exp_rr[p].brmask = resolve_mask(m[idx].brmask);
        if (!SLOW_WAKEUP_FU[m[idx].fu] && m[idx].rd.typ != PREG_TYPE_NONE) begin
          wv[p] = 1'b1;
          wp[p] = m[idx].rd;
          wl[p] = m[idx].lat;
        end
      end
    end
    for (int x = 0; x < EXT_W; x++) begin
      wv[ISSUE_W+x] = ext_wakeup[x].valid;
      wp[ISSUE_W+x] = ext_wakeup[x].preg;
      wl[ISSUE_W+x] = ext_wakeup[x].latency;
    end

    if (rst || flush) begin
      for (int e = 0; e < SIZE; e++) m[e].valid = 1'b0;
      for (int f = 0; f < DEST_FU_NUM; f++) memo_v[f] = 1'b0;
      for (int p = 0; p < ISSUE_W; p++) exp_rr_valid[p] = 1'b0;
      if (flush) st_flush++;
      return;
    end
    if (br_update[0].valid && !br_update[0].mispredict) st_resolve++;

    // issue したものが抜ける
    for (int p = 0; p < ISSUE_W; p++) begin
      idx = exp_idx[p];
      if (idx < 0) continue;
      issued_at[int'(m[idx].id)] = cyc;
      st_issue[p]++;
      if (BLOCKING_FU[m[idx].fu]) begin
        memo_v[m[idx].fu] = 1'b1;
        memo_at[m[idx].fu] = cyc;
      end
      m[idx].valid = 1'b0;
    end

    // mispredict で消える
    for (int e = 0; e < SIZE; e++) begin
      if (m[e].valid && killed_by(m[e].brmask)) begin
        m[e].valid = 1'b0;
        st_kill++;
      end
    end

    // 残ったものに分岐の解決と wakeup を当てる
    for (int e = 0; e < SIZE; e++) begin
      if (!m[e].valid) continue;
      m[e].brmask = resolve_mask(m[e].brmask);
      hit = wake_src(m[e].w1, m[e].r1, m[e].rs1, wv, wp, wl);
      hit = wake_src(m[e].w2, m[e].r2, m[e].rs2, wv, wp, wl);
    end

    // dispatch
    for (int i = 0; i < DISPATCH_W; i++) begin
      if (!disp_valid[i]) continue;
      if (i >= free_slots) begin
        st_drop_full++;
        continue;
      end
      if (killed_by(disp_entry[i].brmask)) begin
        st_drop_kill++;
        continue;
      end
      j = -1;
      for (int e = 0; e < SIZE; e++) begin
        if (!m[e].valid) begin
          j = e;
          break;
        end
      end
      if (j < 0) begin
        fail("モデルの空きが無い（テストの誤り）");
        continue;
      end
      m[j].valid = 1'b1;
      m[j].id = disp_payload[i][31:0];
      m[j].seq = next_seq++;
      m[j].rd = disp_entry[i].rd;
      m[j].rs1 = disp_entry[i].rs1.preg;
      m[j].rs2 = disp_entry[i].rs2.preg;
      m[j].w1 = disp_entry[i].rs1.st.counting;
      m[j].w2 = disp_entry[i].rs2.st.counting;
      m[j].r1 = cyc + 1 + cyc_t'(disp_entry[i].rs1.st.cnt);
      m[j].r2 = cyc + 1 + cyc_t'(disp_entry[i].rs2.st.cnt);
      m[j].lat = disp_entry[i].lat;
      m[j].fu = disp_entry[i].dest_fu;
      m[j].brmask = resolve_mask(disp_entry[i].brmask);
      m[j].payload = disp_payload[i];
      hit = wake_src(m[j].w1, m[j].r1, m[j].rs1, wv, wp, wl);
      if (hit) st_alloc_wake++;
      hit = wake_src(m[j].w2, m[j].r2, m[j].rs2, wv, wp, wl);
      if (hit) st_alloc_wake++;
    end
  endtask

  task automatic check_rr();
    for (int p = 0; p < ISSUE_W; p++) begin
      checks++;
      if (rr_ff[p].valid !== exp_rr_valid[p]) begin
        fail($sformatf("port%0d rr_ff.valid=%0b 期待=%0b", p, rr_ff[p].valid, exp_rr_valid[p]));
        continue;
      end
      if (!exp_rr_valid[p]) continue;
      if (rr_ff[p].rd !== exp_rr[p].rd || rr_ff[p].rs1 !== exp_rr[p].rs1 || rr_ff[p].rs2 !== exp_rr[p].rs2)
        fail($sformatf("port%0d rr_ff のレジスタ rd=%h rs1=%h rs2=%h 期待 rd=%h rs1=%h rs2=%h（id %0d）", p, rr_ff[p].rd,
                       rr_ff[p].rs1, rr_ff[p].rs2, exp_rr[p].rd, exp_rr[p].rs1, exp_rr[p].rs2, exp_rr[p].id));
      if (rr_ff[p].dest_fu !== exp_rr[p].fu)
        fail($sformatf("port%0d rr_ff.dest_fu=%0d 期待=%0d（id %0d）", p, rr_ff[p].dest_fu, exp_rr[p].fu, exp_rr[p].id));
      if (rr_ff[p].brmask !== exp_rr[p].brmask)
        fail($sformatf("port%0d rr_ff.brmask=%b 期待=%b（id %0d）", p, rr_ff[p].brmask, exp_rr[p].brmask, exp_rr[p].id));
      if (rr_payload[p] !== exp_rr[p].payload)
        fail($sformatf("port%0d rr_payload=%h 期待=%h（id %0d）", p, rr_payload[p], exp_rr[p].payload, exp_rr[p].id));
    end
  endtask

  // 入力をセットしてから呼ぶ。1 サイクル進めて全部チェックする
  task automatic cycle();
    @(negedge clk);
    #2;
    compute_expect();
    check_comb();
    @(posedge clk);
    #1;
    model_advance();
    check_rr();
    cyc++;
  endtask

  // ---------------- 入力を作る補助 ----------------

  int next_id;

  function automatic int nid();
    return next_id++;
  endfunction

  task automatic clear_inputs();
    rst = 1'b0;
    flush = 1'b0;
    for (int i = 0; i < DISPATCH_W; i++) begin
      disp_valid[i] = 1'b0;
      disp_entry[i] = '0;
      disp_payload[i] = '0;
    end
    for (int x = 0; x < EXT_W; x++) ext_wakeup[x] = '0;
    br_update[0] = '0;
    for (int f = 0; f < DEST_FU_NUM; f++) dest_fu_blocked[f] = 1'b0;
  endtask

  task automatic put(int lane, wrapper_ff_t e, int id);
    disp_valid[lane] = 1'b1;
    disp_entry[lane] = e;
    disp_payload[lane] = {rng_state[63:32], 32'(id)};
  endtask

  task automatic ext(int lane, preg_t p, int lat);
    ext_wakeup[lane].valid = 1'b1;
    ext_wakeup[lane].preg = p;
    ext_wakeup[lane].latency = latency_t'(lat);
  endtask

  task automatic mispredict(int tag);
    br_update[0].valid = 1'b1;
    br_update[0].mispredict = 1'b1;
    br_update[0].tag = br_tag_t'(tag);
  endtask

  task automatic resolve(int tag);
    br_update[0].valid = 1'b1;
    br_update[0].mispredict = 1'b0;
    br_update[0].tag = br_tag_t'(tag);
  endtask

  task automatic run_idle(int n);
    repeat (n) begin
      clear_inputs();
      cycle();
    end
  endtask

  task automatic expect_at(int id, cyc_t c);
    checks++;
    if (!issued_at.exists(id)) fail($sformatf("id %0d が issue されていない（期待 cycle %0d）", id, c));
    else if (issued_at[id] != c) fail($sformatf("id %0d の issue が cycle %0d（期待 %0d）", id, issued_at[id], c));
  endtask

  task automatic expect_never(int id);
    checks++;
    if (issued_at.exists(id)) fail($sformatf("id %0d は issue されないはずが cycle %0d に issue された", id, issued_at[id]));
  endtask

  task automatic expect_true(logic c, string msg);
    checks++;
    if (!c) fail(msg);
  endtask

  // ---------------- 決め打ちのテスト ----------------

  int fu_fast;  // slow でも blocking でもない FU
  int fu_slow;
  int fu_blk;
  int fu_blk2;  // fu_blk と同じポートの別の blocking FU
  int fu_any;
  int err_base;

  task automatic begin_test(string name);
    test_name = "（前処理）";
    clear_inputs();
    flush = 1'b1;
    cycle();
    run_idle(3);
    test_name = name;
    err_base = errors;
  endtask

  task automatic end_test();
    n_tests++;
    if (errors == err_base) begin
      $display("[OK] %s", test_name);
    end else begin
      $display("[NG] %s", test_name);
      n_fail++;
    end
  endtask

  task automatic t_basic();
    int a;
    cyc_t t0;
    begin_test("ready なものは dispatch の次のサイクルに issue");
    a = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(40), s_none(), s_none(), 0, fu_any, '0), a);
    cycle();
    run_idle(3);
    expect_at(a, t0 + 1);
    end_test();
  endtask

  task automatic t_back_to_back();
    int a, b, c, d, e;
    cyc_t t0, t1;
    if (fu_fast < 0) return;
    begin_test("LAT_FAST の依存命令が毎サイクル連続で issue（dispatch と同じサイクルの wakeup を含む）");
    a = nid();
    b = nid();
    c = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(40), s_none(), s_none(), LAT_FAST, fu_fast, '0), a);
    cycle();
    // a の issue と同じサイクルに b が入る
    clear_inputs();
    put(0, ent(pi(41), s_wait(pi(40)), s_none(), LAT_FAST, fu_fast, '0), b);
    cycle();
    clear_inputs();
    put(0, ent(pi(42), s_none(), s_wait(pi(41)), LAT_FAST, fu_fast, '0), c);
    cycle();
    run_idle(3);
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 2);
    expect_at(c, t0 + 3);

    // 先に IQ で待っている側
    d = nid();
    e = nid();
    t1 = cyc;
    clear_inputs();
    put(0, ent(pi(43), s_wait(pi(44)), s_none(), LAT_FAST, fu_fast, '0), d);
    cycle();
    clear_inputs();
    put(0, ent(pi(44), s_none(), s_none(), LAT_FAST, fu_fast, '0), e);
    cycle();
    run_idle(3);
    expect_at(e, t1 + 2);
    expect_at(d, t1 + 3);
    end_test();
  endtask

  task automatic t_latency();
    int a, b, c, d;
    cyc_t t0, t1;
    if (fu_fast < 0) return;
    begin_test("lat の分だけ依存命令が待つ（lat=3, lat=1）");
    a = nid();
    b = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(45), s_none(), s_none(), 3, fu_fast, '0), a);
    cycle();
    clear_inputs();
    put(0, ent(pi(46), s_wait(pi(45)), s_none(), 0, fu_fast, '0), b);
    cycle();
    run_idle(6);
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 5);

    c = nid();
    d = nid();
    t1 = cyc;
    clear_inputs();
    put(0, ent(pi(47), s_none(), s_none(), 1, fu_fast, '0), c);
    cycle();
    clear_inputs();
    put(0, ent(pi(48), s_none(), s_wait(pi(47)), 0, fu_fast, '0), d);
    cycle();
    run_idle(4);
    expect_at(c, t1 + 1);
    expect_at(d, t1 + 3);
    end_test();
  endtask

  task automatic t_init_cnt();
    int a, b, c;
    cyc_t t0, t1, t2;
    begin_test("dispatch 時の cnt の分だけ待つ（遅い方のソースに合わせる）");
    a = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(50), s_rdy(pi(51), 2), s_none(), 0, fu_any, '0), a);
    cycle();
    run_idle(4);
    expect_at(a, t0 + 3);

    b = nid();
    t1 = cyc;
    clear_inputs();
    put(0, ent(pi(52), s_rdy(pi(53), 1), s_rdy(pf(53), 3), 0, fu_any, '0), b);
    cycle();
    run_idle(5);
    expect_at(b, t1 + 4);

    c = nid();
    t2 = cyc;
    clear_inputs();
    put(0, ent(pi(54), s_rdy(pi(55), 0), s_rdy(pf(55), 0), 0, fu_any, '0), c);
    cycle();
    run_idle(2);
    expect_at(c, t2 + 1);
    end_test();
  endtask

  task automatic t_age();
    int a, b, c, d, e, f, g;
    cyc_t tw, tw2, tw3;
    begin_test("古いものから issue する");
    a = nid();
    b = nid();
    c = nid();
    clear_inputs();
    put(0, ent(pi(40), s_wait(pi(1)), s_none(), 0, fu_any, '0), a);
    cycle();
    clear_inputs();
    put(0, ent(pi(41), s_none(), s_wait(pi(1)), 0, fu_any, '0), b);
    cycle();
    // SIZE=2 では 3 個目は入らない
    if (SIZE >= 3) begin
      clear_inputs();
      put(0, ent(pi(42), s_wait(pi(1)), s_none(), 0, fu_any, '0), c);
      cycle();
    end
    tw = cyc;
    clear_inputs();
    ext(0, pi(1), 0);
    cycle();
    run_idle(5);
    expect_at(a, tw + 1);
    expect_at(b, tw + 2);
    if (SIZE >= 3) expect_at(c, tw + 3);

    // 若い方が先に ready になれば若い方が先
    d = nid();
    e = nid();
    clear_inputs();
    put(0, ent(pi(43), s_wait(pi(2)), s_none(), 0, fu_any, '0), d);
    cycle();
    clear_inputs();
    put(0, ent(pi(44), s_wait(pi(3)), s_none(), 0, fu_any, '0), e);
    cycle();
    tw2 = cyc;
    clear_inputs();
    ext(0, pi(3), 0);
    cycle();
    clear_inputs();
    ext(0, pi(2), 0);
    cycle();
    run_idle(3);
    expect_at(e, tw2 + 1);
    expect_at(d, tw2 + 2);

    // 同時に ready になったら古い方（ready になった順ではない）
    f = nid();
    g = nid();
    clear_inputs();
    put(0, ent(pi(45), s_wait(pi(4)), s_none(), 0, fu_any, '0), f);
    cycle();
    clear_inputs();
    put(0, ent(pi(46), s_wait(pi(5)), s_none(), 0, fu_any, '0), g);
    cycle();
    tw3 = cyc;
    clear_inputs();
    ext(0, pi(5), 0);
    ext(1, pi(4), 0);
    cycle();
    run_idle(3);
    expect_at(f, tw3 + 1);
    expect_at(g, tw3 + 2);
    end_test();
  endtask

  task automatic t_slow();
    int a, b, c, d, cons;
    cyc_t t0, tw, tw2;
    if (fu_slow < 0) return;
    begin_test("SLOW_WAKEUP_FU は issue 時に wakeup を出さず、外からの wakeup で起きる");
    cons = (fu_fast >= 0) ? fu_fast : fu_slow;
    a = nid();
    b = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(50), s_none(), s_none(), 0, fu_slow, '0), a);
    cycle();
    clear_inputs();
    put(0, ent(pi(51), s_wait(pi(50)), s_none(), 0, cons, '0), b);
    cycle();
    run_idle(6);
    expect_at(a, t0 + 1);
    expect_never(b);
    tw = cyc;
    clear_inputs();
    ext(0, pi(50), 0);
    cycle();
    run_idle(3);
    expect_at(b, tw + 1);

    // 外からの wakeup に latency が付いていたら従う
    c = nid();
    d = nid();
    clear_inputs();
    put(0, ent(pf(52), s_none(), s_none(), 0, fu_slow, '0), c);
    cycle();
    clear_inputs();
    put(0, ent(pi(53), s_none(), s_wait(pf(52)), 0, cons, '0), d);
    cycle();
    run_idle(4);
    tw2 = cyc;
    clear_inputs();
    ext(2, pf(52), 2);
    cycle();
    run_idle(5);
    expect_at(d, tw2 + 3);
    end_test();
  endtask

  task automatic t_blocking();
    int a, b, c, d, e;
    cyc_t t0, t1;
    if (fu_blk < 0) return;
    begin_test("BLOCKING_FU は issue 後 ISSUE_TO_FU サイクルと dest_fu_blocked の間は出さない");
    a = nid();
    b = nid();
    c = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pn(), s_none(), s_none(), 0, fu_blk, '0), a);
    cycle();
    clear_inputs();
    put(0, ent(pn(), s_none(), s_none(), 0, fu_blk, '0), b);
    cycle();
    // a は t0+1 に出て、t0+2, t0+3 は IQ 側で止める。t0+4〜t0+6 は FU が blocked を出す
    for (int k = 2; k <= 10; k++) begin
      clear_inputs();
      if (k == 2 && fu_blk2 >= 0) put(0, ent(pn(), s_none(), s_none(), 0, fu_blk2, '0), c);
      if (cyc >= t0 + 4 && cyc <= t0 + 6) dest_fu_blocked[fu_blk] = 1'b1;
      cycle();
    end
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 7);
    // 同じポートの別の blocking FU は止まらない
    if (fu_blk2 >= 0) expect_at(c, t0 + 3);

    // dest_fu_blocked が無ければ ISSUE_TO_FU サイクルだけ止まる
    d = nid();
    e = nid();
    t1 = cyc;
    clear_inputs();
    put(0, ent(pn(), s_none(), s_none(), 0, fu_blk, '0), d);
    cycle();
    clear_inputs();
    put(0, ent(pn(), s_none(), s_none(), 0, fu_blk, '0), e);
    cycle();
    run_idle(5);
    expect_at(d, t1 + 1);
    expect_at(e, t1 + 2 + ISSUE_TO_FU);
    end_test();
  endtask

  task automatic t_fu_blocked_input();
    int a;
    cyc_t t0;
    begin_test("dest_fu_blocked が立っている FU には出さない（blocking でない FU も）");
    a = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(40), s_none(), s_none(), 0, fu_any, '0), a);
    cycle();
    clear_inputs();
    dest_fu_blocked[fu_any] = 1'b1;
    cycle();
    clear_inputs();
    dest_fu_blocked[fu_any] = 1'b1;
    cycle();
    run_idle(3);
    expect_at(a, t0 + 3);
    end_test();
  endtask

  task automatic t_kill();
    int a, b, c, d, f;
    int fill[$];
    cyc_t t2, tk;
    begin_test("mispredict で依存するものが消える");
    // IQ で待っているもの
    a = nid();
    clear_inputs();
    put(0, ent(pi(40), s_wait(pi(1)), s_none(), 0, fu_any, bit_of(3)), a);
    cycle();
    clear_inputs();
    mispredict(3);
    cycle();
    clear_inputs();
    ext(0, pi(1), 0);
    cycle();
    run_idle(3);
    expect_never(a);

    // issue するはずのサイクルに消える
    b = nid();
    clear_inputs();
    put(0, ent(pi(41), s_none(), s_none(), 0, fu_any, bit_of(2) | bit_of(7)), b);
    cycle();
    clear_inputs();
    mispredict(2);
    cycle();
    run_idle(3);
    expect_never(b);

    // dispatch と同じサイクル
    c = nid();
    clear_inputs();
    put(0, ent(pi(42), s_none(), s_none(), 0, fu_any, bit_of(4)), c);
    mispredict(4);
    cycle();
    run_idle(3);
    expect_never(c);

    // 関係ないタグでは消えない
    d = nid();
    t2 = cyc;
    clear_inputs();
    put(0, ent(pi(43), s_none(), s_none(), 0, fu_any, bit_of(5)), d);
    cycle();
    clear_inputs();
    mispredict(6);
    cycle();
    run_idle(2);
    expect_at(d, t2 + 1);

    // 満杯でも消えた分はすぐ次に使える
    for (int k = 0; k < SIZE; k++) begin
      fill.push_back(nid());
      clear_inputs();
      put(0, ent(pn(), s_wait(pi(2)), s_none(), 0, fu_any, bit_of(1)), fill[k]);
      cycle();
    end
    expect_true(disp_full === 1'b1, "SIZE 個入れたのに disp_full が立たない");
    tk = cyc;
    clear_inputs();
    mispredict(1);
    cycle();
    expect_true(disp_full === 1'b0, "mispredict で全部消えたのに disp_full が下がらない");
    f = nid();
    clear_inputs();
    put(0, ent(pi(44), s_none(), s_none(), 0, fu_any, '0), f);
    cycle();
    clear_inputs();
    ext(0, pi(2), 0);
    cycle();
    run_idle(3);
    expect_at(f, tk + 2);
    foreach (fill[k]) expect_never(fill[k]);
    end_test();
  endtask

  task automatic t_resolve();
    int a, b, c, port;
    cyc_t t0, t2;
    begin_test("当たった分岐のビットが落ちる（IQ の中、rr_ff、dispatch 中）");
    a = nid();
    t0 = cyc;
    clear_inputs();
    put(0, ent(pi(40), s_wait(pi(1)), s_none(), 0, fu_any, bit_of(5)), a);
    cycle();
    clear_inputs();
    resolve(5);
    cycle();
    // タグ 5 が別の分岐に使い回されて外れても、a は消えない
    clear_inputs();
    mispredict(5);
    cycle();
    clear_inputs();
    ext(0, pi(1), 0);
    cycle();
    run_idle(2);
    expect_at(a, t0 + 4);

    // issue と同じサイクルの resolve は rr_ff の brmask に入る
    b = nid();
    port = port_of(fu_any);
    clear_inputs();
    put(0, ent(pi(41), s_none(), s_none(), 0, fu_any, bit_of(6) | bit_of(7)), b);
    cycle();
    clear_inputs();
    resolve(6);
    cycle();
    expect_true(rr_ff[port].valid === 1'b1 && rr_ff[port].brmask === bit_of(7),
                $sformatf("issue と同時の resolve が rr_ff に入っていない（brmask=%b）", rr_ff[port].brmask));
    run_idle(1);

    // dispatch と同じサイクルの resolve
    c = nid();
    t2 = cyc;
    clear_inputs();
    put(0, ent(pi(42), s_wait(pi(2)), s_none(), 0, fu_any, bit_of(3)), c);
    resolve(3);
    cycle();
    clear_inputs();
    mispredict(3);
    cycle();
    clear_inputs();
    ext(0, pi(2), 0);
    cycle();
    run_idle(2);
    expect_at(c, t2 + 3);
    end_test();
  endtask

  task automatic t_full();
    int fill[$];
    int x, y, z;
    cyc_t tw;
    begin_test("満杯のときは disp_full が立ち、来たものは入らない");
    for (int k = 0; k < SIZE; k++) begin
      fill.push_back(nid());
      clear_inputs();
      put(0, ent(pn(), s_wait(pi(3)), s_none(), 0, fu_any, '0), fill[k]);
      cycle();
    end
    expect_true(disp_full === 1'b1, "SIZE 個入れたのに disp_full が立たない");
    x = nid();
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(3)), s_none(), 0, fu_any, '0), x);
    cycle();
    tw = cyc;
    clear_inputs();
    ext(0, pi(3), 0);
    cycle();
    run_idle(SIZE + 2);
    // ポートが 1 本なので古い順に 1 個ずつ出る
    foreach (fill[k]) expect_at(fill[k], tw + 1 + cyc_t'(k));
    expect_never(x);
    end_test();

    if (DISPATCH_W < 2 || SIZE < 2) return;
    begin_test("2 レーン dispatch で空きが 1 個ならレーン 0 だけ入る");
    fill.delete();
    for (int k = 0; k < SIZE - 1; k++) begin
      fill.push_back(nid());
      clear_inputs();
      put(0, ent(pn(), s_wait(pi(3)), s_none(), 0, fu_any, '0), fill[k]);
      cycle();
    end
    expect_true(disp_full === 1'b1, "空きが 1 個（< DISPATCH_W）なのに disp_full が立たない");
    y = nid();
    z = nid();
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(3)), s_none(), 0, fu_any, '0), y);
    put(1, ent(pn(), s_wait(pi(3)), s_none(), 0, fu_any, '0), z);
    cycle();
    tw = cyc;
    clear_inputs();
    ext(0, pi(3), 0);
    cycle();
    run_idle(SIZE + 2);
    foreach (fill[k]) expect_at(fill[k], tw + 1 + cyc_t'(k));
    expect_at(y, tw + SIZE);
    expect_never(z);
    end_test();
  endtask

  task automatic t_flush();
    int a, b, c, d;
    cyc_t t3;
    begin_test("flush で中身も同じサイクルの dispatch も消える");
    a = nid();
    b = nid();
    c = nid();
    clear_inputs();
    put(0, ent(pi(40), s_wait(pi(1)), s_none(), 0, fu_any, '0), a);
    cycle();
    clear_inputs();
    put(0, ent(pi(41), s_none(), s_none(), 0, fu_any, '0), b);
    cycle();
    // b が issue するはずのサイクル
    clear_inputs();
    flush = 1'b1;
    put(0, ent(pi(42), s_none(), s_none(), 0, fu_any, '0), c);
    cycle();
    expect_true(disp_full === 1'b0, "flush の後に disp_full が立っている");
    for (int p = 0; p < ISSUE_W; p++) expect_true(rr_ff[p].valid === 1'b0, "flush の次のサイクルに rr_ff.valid が立っている");
    clear_inputs();
    ext(0, pi(1), 0);
    cycle();
    run_idle(3);
    expect_never(a);
    expect_never(b);
    expect_never(c);

    // flush の後は普通に使える
    d = nid();
    t3 = cyc;
    clear_inputs();
    put(0, ent(pi(43), s_none(), s_none(), 0, fu_any, '0), d);
    cycle();
    run_idle(2);
    expect_at(d, t3 + 1);
    end_test();
  endtask

  task automatic t_wakeup_match();
    int a, b, c, d, e;
    cyc_t t0, t1, t2, t3;
    begin_test("wakeup の当て方（種類違い、二重、2 ソース同時、dispatch と同時）");
    // 種類が違えば起きない
    a = nid();
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(5)), s_none(), 0, fu_any, '0), a);
    cycle();
    clear_inputs();
    ext(0, pf(5), 0);
    cycle();
    run_idle(3);
    expect_never(a);
    t0 = cyc;
    clear_inputs();
    ext(0, pi(5), 0);
    cycle();
    run_idle(2);
    expect_at(a, t0 + 1);

    // 起きた後の wakeup は無視（latency を上書きしない）
    b = nid();
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(6)), s_none(), 0, fu_any, '0), b);
    cycle();
    t1 = cyc;
    clear_inputs();
    ext(0, pi(6), 3);
    cycle();
    clear_inputs();
    ext(1, pi(6), 0);
    cycle();
    run_idle(5);
    expect_at(b, t1 + 4);

    // 2 つのソースが同じサイクルに別のレーンで起きる
    c = nid();
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(7)), s_wait(pf(7)), 0, fu_any, '0), c);
    cycle();
    t2 = cyc;
    clear_inputs();
    ext(0, pi(7), 0);
    ext(2, pf(7), 2);
    cycle();
    run_idle(4);
    expect_at(c, t2 + 3);

    // dispatch と同じサイクルの外からの wakeup
    d = nid();
    e = nid();
    t3 = cyc;
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(8)), s_none(), 0, fu_any, '0), d);
    ext(1, pi(8), 0);
    cycle();
    clear_inputs();
    put(0, ent(pn(), s_none(), s_wait(pf(9)), 0, fu_any, '0), e);
    ext(0, pf(9), 2);
    cycle();
    run_idle(5);
    expect_at(d, t3 + 1);
    expect_at(e, t3 + 4);
    end_test();
  endtask

  task automatic t_none_rd();
    int a, b;
    cyc_t t0;
    begin_test("rd が NONE の命令は wakeup を出さない（同じ番号を待つものは起きない）");
    a = nid();
    b = nid();
    clear_inputs();
    put(0, ent(pn(), s_none(), s_none(), 0, fu_any, '0), a);
    cycle();
    clear_inputs();
    put(0, ent(pi(40), s_wait(pi(0)), s_none(), 0, fu_any, '0), b);
    cycle();
    run_idle(3);
    expect_never(b);
    t0 = cyc;
    clear_inputs();
    ext(0, pi(0), 0);
    cycle();
    run_idle(2);
    expect_at(b, t0 + 1);
    end_test();
  endtask

  task automatic t_parallel();
    int ids[ISSUE_W];
    int fu_of_port[ISSUE_W];
    cyc_t tw;
    if (ISSUE_W < 2) return;
    begin_test("ポートが違えば同じサイクルに並んで issue");
    for (int p = 0; p < ISSUE_W; p++) begin
      fu_of_port[p] = -1;
      for (int f = DEST_FU_NUM - 1; f >= 0; f--) if (FU_LISTEN_PORT[f][p]) fu_of_port[p] = f;
    end
    for (int p = 0; p < ISSUE_W; p++) begin
      ids[p] = nid();
      clear_inputs();
      put(0, ent(pn(), s_wait(pi(10)), s_none(), 0, fu_of_port[p], '0), ids[p]);
      cycle();
    end
    tw = cyc;
    clear_inputs();
    ext(0, pi(10), 0);
    cycle();
    run_idle(3);
    for (int p = 0; p < ISSUE_W; p++) expect_at(ids[p], tw + 1);
    end_test();
  endtask

  task automatic t_dual_dispatch();
    int a, b, c, d, e;
    cyc_t tw, t2, t3;
    if (DISPATCH_W < 2) return;
    begin_test("2 レーン dispatch（レーン 0 が古い、同じサイクルの producer と consumer、レーン 1 だけ）");
    a = nid();
    b = nid();
    clear_inputs();
    put(0, ent(pn(), s_wait(pi(11)), s_none(), 0, fu_any, '0), a);
    put(1, ent(pn(), s_wait(pi(11)), s_none(), 0, fu_any, '0), b);
    cycle();
    tw = cyc;
    clear_inputs();
    ext(0, pi(11), 0);
    cycle();
    run_idle(3);
    expect_at(a, tw + 1);
    expect_at(b, tw + 2);

    if (fu_fast >= 0) begin
      c = nid();
      d = nid();
      t2 = cyc;
      clear_inputs();
      put(0, ent(pi(12), s_none(), s_none(), LAT_FAST, fu_fast, '0), c);
      put(1, ent(pi(13), s_wait(pi(12)), s_none(), LAT_FAST, fu_fast, '0), d);
      cycle();
      run_idle(3);
      expect_at(c, t2 + 1);
      expect_at(d, t2 + 2);
    end

    e = nid();
    t3 = cyc;
    clear_inputs();
    put(1, ent(pn(), s_none(), s_none(), 0, fu_any, '0), e);
    cycle();
    run_idle(2);
    expect_at(e, t3 + 1);
    end_test();
  endtask

  // ---------------- ランダムテスト ----------------

  typedef struct packed {
    cyc_t at;
    preg_t preg;
  } pend_t;

  pend_t pend[$];  // これから流す書き込み時の wakeup
  logic blk_v[DEST_FU_NUM];
  cyc_t blk_from[DEST_FU_NUM];
  cyc_t blk_to[DEST_FU_NUM];

  function automatic preg_t rand_preg(int base, int n);
    return rnd(2) ? pi(base + rnd(n)) : pf(base + rnd(n));
  endfunction

  function automatic logic rd_in_use(preg_t c, preg_t chosen[DISPATCH_W], int nchosen);
    for (int e = 0; e < SIZE; e++) if (m[e].valid && m[e].rd == c) return 1'b1;
    foreach (pend[k]) if (pend[k].preg == c) return 1'b1;
    for (int k = 0; k < nchosen; k++) if (chosen[k] == c) return 1'b1;
    return 1'b0;
  endfunction

  // ソースの作り方
  //   NONE / wakeup 済み（cnt はランダム）/ 外の preg を待つ（プール A: 番号 0〜3）/ IQ にいる命令の結果を待つ
  task automatic gen_src(inout brmask_t bm, output src_reg_t s);
    int r;
    int k;
    r = rnd(100);
    s = s_none();
    if (r < 20) begin
      s = s_none();
    end else if (r < 45) begin
      s = s_rdy(rand_preg(8, 56), rnd(4));
    end else if (r < 70) begin
      s = s_wait(rand_preg(0, 4));
    end else begin
      for (int tries = 0; tries < 8; tries++) begin
        k = rnd(SIZE);
        if (m[k].valid && m[k].rd.typ != PREG_TYPE_NONE) begin
          s = s_wait(m[k].rd);
          bm |= m[k].brmask;
          break;
        end
      end
    end
  endtask

  task automatic gen_random();
    int used;
    int i;
    preg_t chosen[DISPATCH_W];
    int nchosen;
    wrapper_ff_t e;
    brmask_t bm;
    preg_t c;
    src_reg_t s1, s2;

    clear_inputs();
    flush = rnd(1000) < 4;
    if (rnd(100) < 8) begin
      if (rnd(100) < 40) mispredict(rnd(MAX_BR));
      else resolve(rnd(MAX_BR));
    end

    // 書き込み時の wakeup（最後のレーン以外を使う）
    used = 0;
    i = 0;
    while (i < pend.size()) begin
      if (pend[i].at <= cyc && used < EXT_W - 1) begin
        ext(used, pend[i].preg, 0);
        used++;
        pend.delete(i);
      end else begin
        i++;
      end
    end
    // 外の preg（プール A）への wakeup
    if (rnd(100) < 50) ext(EXT_W - 1, rand_preg(0, 4), rnd(4));

    for (int f = 0; f < DEST_FU_NUM; f++)
      dest_fu_blocked[f] = (blk_v[f] && cyc >= blk_from[f] && cyc <= blk_to[f]) || (rnd(100) < 2);

    nchosen = 0;
    for (int lane = 0; lane < DISPATCH_W; lane++) begin
      if (rnd(100) >= 60) continue;
      bm = '0;
      for (int b = 0; b < MAX_BR; b++) if (rnd(16) == 0) bm[b] = 1'b1;
      e.rd = pn();
      if (rnd(100) >= 15) begin
        for (int tries = 0; tries < 8; tries++) begin
          c = rand_preg(8, 56);
          if (!rd_in_use(c, chosen, nchosen)) begin
            e.rd = c;
            chosen[nchosen++] = c;
            break;
          end
        end
      end
      gen_src(bm, s1);
      gen_src(bm, s2);
      e.rs1 = s1;
      e.rs2 = s2;
      e.lat = latency_t'(rnd(4));
      e.dest_fu = dest_fu_t'(rnd(DEST_FU_NUM));
      e.brmask = bm;
      put(lane, e, nid());
    end
  endtask

  // issue されたものに合わせて、FU の busy と書き込み時の wakeup を用意する
  task automatic after_random_cycle(cyc_t t);
    int f;
    int d;
    pend_t pe;
    for (int p = 0; p < ISSUE_W; p++) begin
      if (!exp_rr_valid[p]) continue;
      f = int'(exp_rr[p].fu);
      if (BLOCKING_FU[f]) begin
        if (blk_v[f] && t <= blk_to[f]) fail($sformatf("FU%0d が busy 中なのに issue した", f));
        // FU は t+2 に受け取り、t+3 から d サイクル blocked を出す
        d = 1 + rnd(8);
        blk_v[f] = 1'b1;
        blk_from[f] = t + 3;
        blk_to[f] = t + 2 + cyc_t'(d);
        if (SLOW_WAKEUP_FU[f] && exp_rr[p].rd.typ != PREG_TYPE_NONE) begin
          pe.at = t + 3 + cyc_t'(d);
          pe.preg = exp_rr[p].rd;
          pend.push_back(pe);
        end
      end else if (SLOW_WAKEUP_FU[f] && exp_rr[p].rd.typ != PREG_TYPE_NONE) begin
        pe.at = t + 2 + cyc_t'(rnd(10));
        pe.preg = exp_rr[p].rd;
        pend.push_back(pe);
      end
    end
  endtask

  task automatic random_test(int n);
    cyc_t t;
    begin_test("ランダム");
    for (int f = 0; f < DEST_FU_NUM; f++) blk_v[f] = 1'b0;
    pend.delete();
    st_kill = 0;
    st_drop_kill = 0;
    st_drop_full = 0;
    st_full_cycles = 0;
    st_alloc_wake = 0;
    st_rewake = 0;
    st_memo_block = 0;
    st_input_block = 0;
    st_flush = 0;
    st_resolve = 0;
    for (int p = 0; p < ISSUE_W; p++) st_issue[p] = 0;

    for (int k = 0; k < n; k++) begin
      gen_random();
      t = cyc;
      cycle();
      after_random_cycle(t);
    end

    $display("  ランダム %0d サイクル: kill %0d, dispatch で kill %0d, 満杯で捨てた %0d, 満杯サイクル %0d", n, st_kill,
             st_drop_kill, st_drop_full, st_full_cycles);
    $display("  dispatch と同時の wakeup %0d, 二重 wakeup %0d, ISSUE_TO_FU で止めた %0d, dest_fu_blocked で止めた %0d",
             st_alloc_wake, st_rewake, st_memo_block, st_input_block);
    $display("  flush %0d, resolve %0d", st_flush, st_resolve);
    for (int p = 0; p < ISSUE_W; p++) $display("  port%0d issue %0d", p, st_issue[p]);

    // 狙った状況が起きていなければテストとして意味が無いので落とす
    for (int p = 0; p < ISSUE_W; p++) expect_true(st_issue[p] > 0, $sformatf("port%0d が一度も issue していない", p));
    expect_true(st_kill > 0, "IQ 内の kill が起きていない");
    expect_true(st_drop_kill > 0, "dispatch 中の kill が起きていない");
    expect_true(st_drop_full > 0, "満杯で捨てる状況が起きていない");
    expect_true(st_alloc_wake > 0, "dispatch と同じサイクルの wakeup が起きていない");
    expect_true(st_rewake > 0, "二重 wakeup が起きていない");
    expect_true(st_flush > 0, "flush が起きていない");
    expect_true(st_resolve > 0, "resolve が起きていない");
    if (BLOCKING_FU != '0) expect_true(st_memo_block > 0, "ISSUE_TO_FU で止める状況が起きていない");
    end_test();
  endtask

  // ---------------- 本体 ----------------

  initial begin
    int ncycles;
    int seed;
    ncycles = 200000;
    seed = 1;
    void'($value$plusargs("cycles=%d", ncycles));
    void'($value$plusargs("seed=%d", seed));
    rng_state = 64'h9e3779b97f4a7c15 ^ (64'(seed) << 1);

    errors = 0;
    checks = 0;
    n_tests = 0;
    n_fail = 0;
    cyc = 0;
    next_seq = 0;
    next_id = 1;
    test_name = "リセット";
    for (int e = 0; e < SIZE; e++) m[e] = '0;
    for (int f = 0; f < DEST_FU_NUM; f++) begin
      memo_v[f] = 1'b0;
      memo_at[f] = '0;
    end

    fu_fast = -1;
    fu_slow = -1;
    fu_blk = -1;
    fu_blk2 = -1;
    for (int f = DEST_FU_NUM - 1; f >= 0; f--) begin
      if (!SLOW_WAKEUP_FU[f] && !BLOCKING_FU[f]) fu_fast = f;
      if (SLOW_WAKEUP_FU[f]) fu_slow = f;
      if (BLOCKING_FU[f]) fu_blk = f;
    end
    if (fu_blk >= 0)
      for (int f = 0; f < DEST_FU_NUM; f++)
        if (f != fu_blk && BLOCKING_FU[f] && port_of(f) == port_of(fu_blk)) fu_blk2 = f;
    fu_any = (fu_fast >= 0) ? fu_fast : 0;

    $display("iq_core: SIZE=%0d DISPATCH_W=%0d ISSUE_W=%0d DEST_FU_NUM=%0d FU_LISTEN_PORT=%b SLOW=%b BLOCKING=%b seed=%0d",
             SIZE, DISPATCH_W, ISSUE_W, DEST_FU_NUM, FU_LISTEN_PORT, SLOW_WAKEUP_FU, BLOCKING_FU, seed);

    clear_inputs();
    rst = 1'b1;
    cycle();
    rst = 1'b1;
    cycle();

    t_basic();
    t_back_to_back();
    t_latency();
    t_init_cnt();
    t_age();
    t_slow();
    t_blocking();
    t_fu_blocked_input();
    t_kill();
    t_resolve();
    t_full();
    t_flush();
    t_wakeup_match();
    t_none_rd();
    t_parallel();
    t_dual_dispatch();
    random_test(ncycles);

    $display("テスト %0d 個中 %0d 個 NG、チェック %0d 回、エラー %0d 個", n_tests, n_fail, checks, errors);
    if (errors != 0) $fatal(1, "FAIL");
    $display("PASS");
    $finish;
  end

endmodule

`default_nettype wire
