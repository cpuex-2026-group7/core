`timescale 1ns / 1ps
`default_nettype none

// ldq の単体テストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 次のサイクルの入力を決めておき、negedge で DUT に写して、1ns 待ってから組合せの出力をモデルと比べる。
// モデルはポインタを回り込まない通し番号（pos）で持つ。エントリの番号は pos % LDQ_SIZE。
//
// テストの前提にしている仕様
//   - dispatch：スロットが小さい方が古い。満杯のスロットの load は無視される。
//     mispredict / flush のサイクルの dispatch は入らない。入れた brmask には同じサイクルの resolve を当てる
//   - older_st_mask は dispatch のサイクルの stq_release_mask を当てずにそのまま入れ、次のサイクルから当てる
//   - 分岐の tag は、そのサイクルの頭に空いているものだけを dispatch に出す
//   - mispredict で tail を br_update_ff.tag の snapshot に戻し、kill_mask で valid を落とす。
//     flush は全部の valid を落として tail を head に戻す（同じサイクルの commit も含む。flush が優先）
//   - ex_lsu は生きている load のものだけが来る。store のもの、addr_valid でないものは無視する。
//     mmio はアドレスが MMIO_RX_ADDR のときだけ
//   - commit は古い分岐が全部解決した後
//   - controller からの ld_requested / ld_gone_to_wb / ld_nack は同じサイクルに別のエントリに来る
//     ld_requested：ld_requested=1、stale |= ld_requested.stale
//     ld_gone_to_wb：ld_requested=0、gone_to_wb=1、forwarded / forward_stq_idx を入れる
//     violation_mask：violated を立てる
//     stale_mask：上の更新の後で ld_requested なら stale を立てる
//     ld_nack：ld_requested=0、stale=0（stale_mask より優先）
//   - load_violation[k] は head から k 番目のエントリで、valid は valid && violated

module tb_ldq
  import types::*;
  import ooo_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
();

  localparam int DISP_W = 2;
  localparam int COMMIT_W = 2;
  localparam int N = LDQ_SIZE;
  localparam int MAX_ERRORS = 30;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic                rst;
  logic                flush;
  disp_ldq_t           disp_ld          [  DISP_W];
  ldq_idx_t            disp_ldq_idx     [  DISP_W];
  logic                disp_full        [  DISP_W];
  logic                disp_br_valid    [  DISP_W];
  br_tag_t             disp_br_tag      [  DISP_W];
  older_st_t           older_st         [  DISP_W];
  stq_mask_t           stq_release_mask;
  ex_lsu_t             ex_lsu;
  ld_requested_t       ld_requested;
  ldq_idx_with_valid_t ld_nack;
  ld_wb_notice_t       ld_gone_to_wb;
  ldq_idx_t            ldq_head_idx;
  ldq_mask_t           violation_mask;
  ldq_mask_t           stale_mask;
  ldq_controller_t     ldq_controller_ff[  LDQ_SIZE];
  ldq_searcher_t       ldq_searcher_ff  [  LDQ_SIZE];
  br_update_t          br_update_ff;
  logic                commit_ld        [COMMIT_W];
  load_violation_t     load_violation   [COMMIT_W];

  ldq #(
    .DISP_W  (DISP_W),
    .COMMIT_W(COMMIT_W)
  ) dut (
    .*
  );

  // テストが書く側。initial の中から DUT の入力を直接書くと Verilator 5.020 の --timing で
  // DUT の組合せ回路が評価し直されないことがあるので、立ち下がりで写す
  logic                t_flush;
  disp_ldq_t           t_disp_ld        [  DISP_W];
  logic                t_disp_br_valid  [  DISP_W];
  br_tag_t             t_disp_br_tag    [  DISP_W];
  older_st_t           t_older_st       [  DISP_W];
  stq_mask_t           t_stq_release_mask;
  ex_lsu_t             t_ex_lsu;
  ld_requested_t       t_ld_requested;
  ldq_idx_with_valid_t t_ld_nack;
  ld_wb_notice_t       t_ld_gone_to_wb;
  ldq_mask_t           t_violation_mask;
  ldq_mask_t           t_stale_mask;
  br_update_t          t_br_update_ff;
  logic                t_commit_ld      [COMMIT_W];

  always @(negedge clk) begin
    flush <= t_flush;
    disp_ld <= t_disp_ld;
    disp_br_valid <= t_disp_br_valid;
    disp_br_tag <= t_disp_br_tag;
    older_st <= t_older_st;
    stq_release_mask <= t_stq_release_mask;
    ex_lsu <= t_ex_lsu;
    ld_requested <= t_ld_requested;
    ld_nack <= t_ld_nack;
    ld_gone_to_wb <= t_ld_gone_to_wb;
    violation_mask <= t_violation_mask;
    stale_mask <= t_stale_mask;
    br_update_ff <= t_br_update_ff;
    commit_ld <= t_commit_ld;
  end

  // ---------------- 乱数 ----------------

  function automatic int rnd(int n);
    return int'($urandom_range(n - 1, 0));
  endfunction

  function automatic addr_t rnd_addr();
    case (rnd(6))
      0: return MMIO_RX_ADDR;
      1: return MMIO_TX_ADDR;
      default: return addr_t'($urandom());
    endcase
  endfunction

  // ---------------- モデル ----------------

  int head_pos, tail_pos;
  bit m_addr_valid[N], m_mmio[N], m_req[N], m_stale[N], m_viol[N], m_fwd[N], m_gone[N];
  addr_t m_addr[N];
  stq_mask_t m_older[N];
  stq_idx_t m_tail_stq[N];
  stq_idx_t m_fwd_idx[N];
  preg_t m_rd[N];
  rob_idx_t m_rob[N];
  brmask_t m_brmask[N];

  // 生きている分岐（古い順）
  int br_tag_q[$];
  int br_snap_q[$];
  bit tag_used[MAX_BR];

  // ---------------- 入力の出し方（一定サイクルごとに変える） ----------------

  int disp_rate, br_disp_rate, br_rate, mis_rate, commit_rate, agu_rate;
  int req_rate, gone_rate, nack_rate, stale_rate, viol_rate, rel_rate;
  bit flush_en;

  task automatic pick_rates();
    case (rnd(4))
      0: disp_rate = 5;
      1: disp_rate = 30;
      2: disp_rate = 60;
      default: disp_rate = 95;
    endcase
    br_disp_rate = rnd(2) == 0 ? 3 : 25;
    br_rate = rnd(2) == 0 ? 10 : 60;
    mis_rate = rnd(3) == 0 ? 60 : 15;
    commit_rate = rnd(2) == 0 ? 20 : 80;
    agu_rate = rnd(2) == 0 ? 30 : 90;
    req_rate = rnd(2) == 0 ? 30 : 90;
    gone_rate = rnd(2) == 0 ? 20 : 70;
    nack_rate = rnd(2) == 0 ? 5 : 40;
    stale_rate = rnd(2) == 0 ? 2 : 20;
    viol_rate = rnd(2) == 0 ? 1 : 10;
    rel_rate = rnd(2) == 0 ? 10 : 50;
    flush_en = 1'b1;
  endtask

  // ---------------- 集計 ----------------

  int unsigned cycles;
  int unsigned seed;
  int unsigned cyc;
  int errors;

  int n_disp, n_full, n_kill_disp, n_wrap, n_commit, n_mispredict, n_flush;
  int n_agu, n_mmio, n_req, n_req_stale, n_gone, n_nack, n_stale_set, n_viol_out, n_kill_entry;

  task automatic err(string msg);
    errors++;
    $display("[cycle %0d] %s", cyc, msg);
    if (errors >= MAX_ERRORS) begin
      $display("FAIL（%0d 件で打ち切り）", errors);
      $finish;
    end
  endtask

  function automatic bit live(int i);
    for (int q = head_pos; q < tail_pos; q++) begin
      if (q % N == i) return 1'b1;
    end
    return 1'b0;
  endfunction

  // ---------------- 出力の確認 ----------------

  task automatic check_entries();
    int idx;
    bit exp_v;
    for (int i = 0; i < N; i++) begin
      if (!live(i)) begin
        if (ldq_controller_ff[i].valid)
          err($sformatf("ldq_controller_ff[%0d].valid = 1、空のエントリのはず（head %0d tail %0d）", i, head_pos % N,
                        tail_pos % N));
        if (ldq_searcher_ff[i].valid) err($sformatf("ldq_searcher_ff[%0d].valid = 1、空のエントリのはず", i));
        continue;
      end
      if (!ldq_controller_ff[i].valid) err($sformatf("ldq_controller_ff[%0d].valid = 0、期待値 1", i));
      if (!ldq_searcher_ff[i].valid) err($sformatf("ldq_searcher_ff[%0d].valid = 0、期待値 1", i));
      if (ldq_controller_ff[i].addr_valid != m_addr_valid[i])
        err($sformatf("ldq_controller_ff[%0d].addr_valid = %0b、期待値 %0b", i, ldq_controller_ff[i].addr_valid,
                      m_addr_valid[i]));
      if (ldq_searcher_ff[i].addr_valid != m_addr_valid[i])
        err($sformatf("ldq_searcher_ff[%0d].addr_valid = %0b、期待値 %0b", i, ldq_searcher_ff[i].addr_valid,
                      m_addr_valid[i]));
      if (m_addr_valid[i]) begin
        if (ldq_controller_ff[i].addr != m_addr[i])
          err($sformatf("ldq_controller_ff[%0d].addr = %h、期待値 %h", i, ldq_controller_ff[i].addr, m_addr[i]));
        if (ldq_searcher_ff[i].addr != m_addr[i])
          err($sformatf("ldq_searcher_ff[%0d].addr = %h、期待値 %h", i, ldq_searcher_ff[i].addr, m_addr[i]));
      end
      if (ldq_controller_ff[i].mmio != m_mmio[i])
        err($sformatf("ldq_controller_ff[%0d].mmio = %0b、期待値 %0b", i, ldq_controller_ff[i].mmio, m_mmio[i]));
      if (ldq_controller_ff[i].ld_requested != m_req[i])
        err($sformatf("ldq_controller_ff[%0d].ld_requested = %0b、期待値 %0b", i, ldq_controller_ff[i].ld_requested,
                      m_req[i]));
      if (ldq_searcher_ff[i].ld_requested != m_req[i])
        err($sformatf("ldq_searcher_ff[%0d].ld_requested = %0b、期待値 %0b", i, ldq_searcher_ff[i].ld_requested,
                      m_req[i]));
      if (ldq_controller_ff[i].stale != m_stale[i])
        err($sformatf("ldq_controller_ff[%0d].stale = %0b、期待値 %0b", i, ldq_controller_ff[i].stale, m_stale[i]));
      if (ldq_controller_ff[i].gone_to_wb != m_gone[i])
        err($sformatf("ldq_controller_ff[%0d].gone_to_wb = %0b、期待値 %0b", i, ldq_controller_ff[i].gone_to_wb,
                      m_gone[i]));
      if (ldq_searcher_ff[i].gone_to_wb != m_gone[i])
        err($sformatf("ldq_searcher_ff[%0d].gone_to_wb = %0b、期待値 %0b", i, ldq_searcher_ff[i].gone_to_wb,
                      m_gone[i]));
      if (ldq_controller_ff[i].rd != m_rd[i])
        err($sformatf("ldq_controller_ff[%0d].rd = %h、期待値 %h", i, ldq_controller_ff[i].rd, m_rd[i]));
      if (ldq_controller_ff[i].rob_idx != m_rob[i])
        err($sformatf("ldq_controller_ff[%0d].rob_idx = %h、期待値 %h", i, ldq_controller_ff[i].rob_idx, m_rob[i]));
      if (ldq_controller_ff[i].brmask != m_brmask[i])
        err($sformatf("ldq_controller_ff[%0d].brmask = %b、期待値 %b", i, ldq_controller_ff[i].brmask, m_brmask[i]));
      if (ldq_searcher_ff[i].older_st_mask != m_older[i])
        err($sformatf("ldq_searcher_ff[%0d].older_st_mask = %b、期待値 %b", i, ldq_searcher_ff[i].older_st_mask,
                      m_older[i]));
      if (ldq_searcher_ff[i].tail_stq_idx != m_tail_stq[i])
        err($sformatf("ldq_searcher_ff[%0d].tail_stq_idx = %0d、期待値 %0d", i, ldq_searcher_ff[i].tail_stq_idx,
                      m_tail_stq[i]));
      if (ldq_searcher_ff[i].forwarded != m_fwd[i])
        err($sformatf("ldq_searcher_ff[%0d].forwarded = %0b、期待値 %0b", i, ldq_searcher_ff[i].forwarded, m_fwd[i]));
      else if (m_fwd[i] && ldq_searcher_ff[i].forward_stq_idx != m_fwd_idx[i])
        err($sformatf("ldq_searcher_ff[%0d].forward_stq_idx = %0d、期待値 %0d", i, ldq_searcher_ff[i].forward_stq_idx,
                      m_fwd_idx[i]));
    end

    for (int k = 0; k < COMMIT_W; k++) begin
      idx = (head_pos + k) % N;
      exp_v = head_pos + k < tail_pos && m_viol[idx];
      if (load_violation[k].valid != exp_v)
        err($sformatf("load_violation[%0d].valid = %0b、期待値 %0b", k, load_violation[k].valid, exp_v));
      else if (exp_v && load_violation[k].rob_idx != m_rob[idx])
        err($sformatf("load_violation[%0d].rob_idx = %h、期待値 %h", k, load_violation[k].rob_idx, m_rob[idx]));
      if (exp_v) n_viol_out++;
    end
  endtask

  // ---------------- 1 サイクル ----------------

  task automatic one_cycle();
    bit do_flush, kill_cycle, stop;
    bit res_tag[MAX_BR];
    bit tag_tmp[MAX_BR];
    bit slot_ld[DISP_W];
    bit slot_br[DISP_W];
    int slot_tag[DISP_W];
    int exp_idx[DISP_W];
    bit exp_full[DISP_W];
    brmask_t cur_mask;
    int mis_i, c, min_snap, limit, p, idx, j, t, r_idx, g_idx, n_idx;
    int cand[$];
    br_update_t u;
    ex_lsu_t ex;
    disp_ldq_t d_ld[DISP_W];
    logic d_br_valid[DISP_W];
    br_tag_t d_br_tag[DISP_W];
    older_st_t d_older[DISP_W];
    logic d_commit[COMMIT_W];
    ld_requested_t lr;
    ldq_idx_with_valid_t ln;
    ld_wb_notice_t lg;
    ldq_mask_t vm, sm;
    stq_mask_t rel;

    // ---- 分岐の解決と flush ----
    do_flush = flush_en && rnd(300) == 0;
    u = '0;
    u.pc = pc_t'($urandom());
    u.target = pc_t'($urandom());
    u.taken = rnd(2) == 1;
    u.rob_idx = rob_idx_t'($urandom());
    u.tag = br_tag_t'($urandom());
    mis_i = -1;
    for (int i = 0; i < MAX_BR; i++) res_tag[i] = 1'b0;
    // 分岐を解決する EU は 2 つなので、同じサイクルに 2 つまで
    for (int k = 0; k < 2; k++) begin
      if (br_tag_q.size() > 0 && rnd(100) < br_rate) begin
        j = rnd(br_tag_q.size());
        t = br_tag_q[j];
        if (!u.kill_mask[t] && !u.resolve_mask[t]) begin
          if (rnd(100) < mis_rate) begin
            u.kill_mask[t] = 1'b1;
            if (mis_i < 0 || j < mis_i) mis_i = j;
          end else begin
            u.resolve_mask[t] = 1'b1;
            res_tag[t] = 1'b1;
          end
        end
      end
    end
    if (mis_i >= 0) begin
      u.mispredict = 1'b1;
      u.tag = br_tag_t'(br_tag_q[mis_i]);
    end
    kill_cycle = do_flush || u.mispredict;

    // ---- commit ----
    min_snap = 32'h7fff_ffff;
    for (int i = 0; i < br_snap_q.size(); i++) begin
      if (br_snap_q[i] < min_snap) min_snap = br_snap_q[i];
    end
    c = 0;
    for (int i = 0; i < COMMIT_W; i++) begin
      p = head_pos + c;
      d_commit[i] = 1'b0;
      if (p < tail_pos && p < min_snap && rnd(100) < commit_rate) begin
        d_commit[i] = 1'b1;
        c++;
      end
    end

    // ---- AGU ----
    // 同じサイクルに kill される load のものは出さない
    if (do_flush) limit = head_pos + c;
    else if (u.mispredict) limit = br_snap_q[mis_i];
    else limit = tail_pos;
    ex = '0;
    ex.addr = $urandom();
    ex.data = $urandom();
    ex.ldq_idx = ldq_idx_t'(rnd(N));
    ex.stq_idx = stq_idx_t'($urandom());
    if (rnd(100) < agu_rate) begin
      for (int q = head_pos; q < limit; q++) begin
        if (!m_addr_valid[q%N]) cand.push_back(q);
      end
    end
    if (cand.size() > 0) begin
      p = cand[rnd(cand.size())];
      ex.is_store = 1'b0;
      ex.addr_valid = 1'b1;
      ex.data_valid = 1'b0;
      ex.ldq_idx = ldq_idx_t'(p % N);
      ex.addr = rnd_addr();
    end else if (rnd(2) == 0) begin
      // store か、addr_valid でない load。LDQ は無視するはず
      if (rnd(2) == 0) begin
        ex.is_store = 1'b1;
        ex.addr_valid = rnd(2) == 1;
        ex.data_valid = rnd(2) == 1;
      end else begin
        ex.is_store = 1'b0;
        ex.addr_valid = 1'b0;
        ex.data_valid = 1'b1;
      end
    end
    cand.delete();

    // ---- controller と searcher ----
    r_idx = -1;
    g_idx = -1;
    n_idx = -1;
    lr = '0;
    lr.idx = ldq_idx_t'(rnd(N));
    ln = '0;
    ln.idx = ldq_idx_t'(rnd(N));
    lg = '0;
    lg.idx = ldq_idx_t'(rnd(N));
    lg.forward_stq_idx = stq_idx_t'($urandom());
    if (rnd(100) < req_rate) begin
      for (int q = head_pos; q < tail_pos; q++) begin
        idx = q % N;
        if (m_addr_valid[idx] && !m_req[idx] && !m_gone[idx]) cand.push_back(idx);
      end
      if (cand.size() > 0) begin
        r_idx = cand[rnd(cand.size())];
        lr.valid = 1'b1;
        lr.idx = ldq_idx_t'(r_idx);
        lr.stale = rnd(8) == 0;
      end
      cand.delete();
    end
    if (rnd(100) < gone_rate) begin
      for (int q = head_pos; q < tail_pos; q++) begin
        idx = q % N;
        if (m_addr_valid[idx] && !m_gone[idx] && idx != r_idx) cand.push_back(idx);
      end
      if (cand.size() > 0) begin
        g_idx = cand[rnd(cand.size())];
        lg.valid = 1'b1;
        lg.idx = ldq_idx_t'(g_idx);
        // D$ の返事なら forward ではない。出していなければ forward
        lg.forwarded = m_req[g_idx] ? 1'b0 : 1'b1;
      end
      cand.delete();
    end
    if (rnd(100) < nack_rate) begin
      for (int q = head_pos; q < tail_pos; q++) begin
        idx = q % N;
        if (m_req[idx] && idx != r_idx && idx != g_idx) cand.push_back(idx);
      end
      if (cand.size() > 0) begin
        n_idx = cand[rnd(cand.size())];
        ln.valid = 1'b1;
        ln.idx = ldq_idx_t'(n_idx);
      end
      cand.delete();
    end
    vm = '0;
    sm = '0;
    for (int q = head_pos; q < tail_pos; q++) begin
      idx = q % N;
      if (m_gone[idx] && rnd(100) < viol_rate) vm[idx] = 1'b1;
      // ld_requested でないものにも当てる（LDQ が and を取るはず）
      if (rnd(100) < stale_rate) sm[idx] = 1'b1;
    end
    rel = '0;
    if (rnd(100) < rel_rate) rel[rnd(STQ_SIZE)] = 1'b1;

    // ---- dispatch ----
    cur_mask = '0;
    foreach (br_tag_q[k]) cur_mask[br_tag_q[k]] = 1'b1;
    stop = 1'b0;
    j = 0;
    for (int i = 0; i < MAX_BR; i++) tag_tmp[i] = tag_used[i];
    for (int i = 0; i < DISP_W; i++) begin
      d_ld[i].valid = 1'b0;
      d_ld[i].rd.typ = preg_type_t'(rnd(3));
      d_ld[i].rd.idx = preg_idx_t'($urandom());
      d_ld[i].rob_idx = rob_idx_t'($urandom());
      d_ld[i].brmask = cur_mask;
      d_br_valid[i] = 1'b0;
      d_br_tag[i] = br_tag_t'($urandom());
      d_older[i].older_st_mask = stq_mask_t'($urandom());
      d_older[i].tail_stq_idx = stq_idx_t'($urandom());
      slot_ld[i] = 1'b0;
      slot_br[i] = 1'b0;
      slot_tag[i] = 0;
      exp_idx[i] = (tail_pos + j) % N;
      exp_full[i] = tail_pos + j - head_pos == N;
      if (!stop) begin
        t = rnd(100);
        if (t < disp_rate) begin
          d_ld[i].valid = 1'b1;
          if (exp_full[i]) begin
            // 満杯でも valid を出す（LDQ が無視するはず）。後ろのスロットは出さない
            stop = 1'b1;
            n_full++;
          end else begin
            slot_ld[i] = 1'b1;
            j++;
          end
        end else if (t < disp_rate + br_disp_rate) begin
          t = -1;
          for (int k = 0; k < MAX_BR; k++) begin
            if (t < 0 && !tag_tmp[k]) t = k;
          end
          if (t >= 0) begin
            tag_tmp[t] = 1'b1;
            d_br_valid[i] = 1'b1;
            d_br_tag[i] = br_tag_t'(t);
            slot_br[i] = 1'b1;
            slot_tag[i] = t;
            cur_mask[t] = 1'b1;
          end
        end
      end
    end

    t_disp_ld = d_ld;
    t_disp_br_valid = d_br_valid;
    t_disp_br_tag = d_br_tag;
    t_older_st = d_older;
    t_stq_release_mask = rel;
    t_commit_ld = d_commit;
    t_flush = do_flush;
    t_br_update_ff = u;
    t_ex_lsu = ex;
    t_ld_requested = lr;
    t_ld_nack = ln;
    t_ld_gone_to_wb = lg;
    t_violation_mask = vm;
    t_stale_mask = sm;

    @(negedge clk);
    #1;

    // ---- 出力の確認 ----
    for (int i = 0; i < DISP_W; i++) begin
      if (int'(disp_ldq_idx[i]) != exp_idx[i])
        err($sformatf("disp_ldq_idx[%0d] = %0d、期待値 %0d", i, disp_ldq_idx[i], exp_idx[i]));
      if (disp_full[i] != exp_full[i])
        err($sformatf("disp_full[%0d] = %0b、期待値 %0b", i, disp_full[i], exp_full[i]));
    end
    if (int'(ldq_head_idx) != head_pos % N)
      err($sformatf("ldq_head_idx = %0d、期待値 %0d", ldq_head_idx, head_pos % N));
    check_entries();

    // ---- モデルを進める ----
    for (int q = head_pos; q < tail_pos; q++) begin
      idx = q % N;
      m_brmask[idx] &= ~u.resolve_mask;
      m_older[idx] &= ~rel;
    end

    if (r_idx >= 0) begin
      m_req[r_idx] = 1'b1;
      m_stale[r_idx] |= lr.stale;
      n_req++;
      if (lr.stale) n_req_stale++;
    end
    if (g_idx >= 0) begin
      m_req[g_idx] = 1'b0;
      m_gone[g_idx] = 1'b1;
      m_fwd[g_idx] = lg.forwarded;
      m_fwd_idx[g_idx] = lg.forward_stq_idx;
      n_gone++;
    end
    for (int q = head_pos; q < tail_pos; q++) begin
      idx = q % N;
      if (vm[idx]) m_viol[idx] = 1'b1;
      if (sm[idx] && m_req[idx] && !m_stale[idx] && idx != n_idx) begin
        m_stale[idx] = 1'b1;
        n_stale_set++;
      end
    end
    if (n_idx >= 0) begin
      m_req[n_idx] = 1'b0;
      m_stale[n_idx] = 1'b0;
      n_nack++;
    end

    if (!ex.is_store && ex.addr_valid) begin
      idx = int'(ex.ldq_idx);
      m_addr_valid[idx] = 1'b1;
      m_addr[idx] = ex.addr;
      m_mmio[idx] = ex.addr == MMIO_RX_ADDR;
      n_agu++;
      if (m_mmio[idx]) n_mmio++;
    end

    if (kill_cycle) begin
      for (int i = 0; i < DISP_W; i++) begin
        if (slot_ld[i] || slot_br[i]) n_kill_disp++;
      end
    end else begin
      for (int i = 0; i < DISP_W; i++) begin
        if (slot_ld[i]) begin
          idx = tail_pos % N;
          m_addr_valid[idx] = 1'b0;
          m_mmio[idx] = 1'b0;
          m_req[idx] = 1'b0;
          m_stale[idx] = 1'b0;
          m_viol[idx] = 1'b0;
          m_fwd[idx] = 1'b0;
          m_gone[idx] = 1'b0;
          m_older[idx] = d_older[i].older_st_mask;
          m_tail_stq[idx] = d_older[i].tail_stq_idx;
          m_rd[idx] = d_ld[i].rd;
          m_rob[idx] = d_ld[i].rob_idx;
          m_brmask[idx] = d_ld[i].brmask & ~u.resolve_mask;
          tail_pos++;
          n_disp++;
          if (tail_pos % N == 0) n_wrap++;
        end
        if (slot_br[i]) begin
          br_tag_q.push_back(slot_tag[i]);
          br_snap_q.push_back(tail_pos);
          tag_used[slot_tag[i]] = 1'b1;
        end
      end
    end

    head_pos += c;
    n_commit += c;

    if (do_flush) begin
      n_kill_entry += tail_pos - head_pos;
      tail_pos = head_pos;
      br_tag_q.delete();
      br_snap_q.delete();
      for (int i = 0; i < MAX_BR; i++) tag_used[i] = 1'b0;
      n_flush++;
    end else begin
      if (u.mispredict) begin
        n_kill_entry += tail_pos - br_snap_q[mis_i];
        tail_pos = br_snap_q[mis_i];
        while (br_tag_q.size() > mis_i) begin
          tag_used[br_tag_q[br_tag_q.size()-1]] = 1'b0;
          br_tag_q.pop_back();
          br_snap_q.pop_back();
        end
        n_mispredict++;
      end
      for (int i = br_tag_q.size() - 1; i >= 0; i--) begin
        if (res_tag[br_tag_q[i]]) begin
          tag_used[br_tag_q[i]] = 1'b0;
          br_tag_q.delete(i);
          br_snap_q.delete(i);
        end
      end
    end

    if (!(head_pos <= tail_pos && tail_pos - head_pos <= N))
      err($sformatf("テスト側の誤り：モデルのポインタの順番が崩れた（head %0d tail %0d）", head_pos, tail_pos));
  endtask

  // ---------------- 本体 ----------------

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("ldq: seed=%0d cycles=%0d", seed, cycles);

    rst = 1'b1;
    t_flush = 1'b0;
    t_br_update_ff = '0;
    t_ex_lsu = '0;
    t_ld_requested = '0;
    t_ld_nack = '0;
    t_ld_gone_to_wb = '0;
    t_violation_mask = '0;
    t_stale_mask = '0;
    t_stq_release_mask = '0;
    for (int i = 0; i < DISP_W; i++) begin
      t_disp_ld[i] = '0;
      t_disp_br_valid[i] = 1'b0;
      t_disp_br_tag[i] = '0;
      t_older_st[i] = '0;
    end
    for (int i = 0; i < COMMIT_W; i++) t_commit_ld[i] = 1'b0;
    for (int i = 0; i < N; i++) begin
      m_addr_valid[i] = 1'b0;
      m_mmio[i] = 1'b0;
      m_req[i] = 1'b0;
      m_stale[i] = 1'b0;
      m_viol[i] = 1'b0;
      m_fwd[i] = 1'b0;
      m_gone[i] = 1'b0;
      m_addr[i] = '0;
      m_older[i] = '0;
      m_tail_stq[i] = '0;
      m_fwd_idx[i] = '0;
      m_rd[i] = '0;
      m_rob[i] = '0;
      m_brmask[i] = '0;
    end
    repeat (3) @(negedge clk);
    rst = 1'b0;
    // 入力を写す always より後に次の入力を決める
    #1;

    for (cyc = 0; cyc < cycles; cyc++) begin
      if (cyc % 512 == 0) pick_rates();
      one_cycle();
    end

    $display("dispatch %0d（満杯で断った %0d、kill のサイクルで捨てた %0d、一周 %0d 回）", n_disp, n_full,
             n_kill_disp, n_wrap);
    $display("commit %0d、mispredict %0d、flush %0d、kill したエントリ %0d", n_commit, n_mispredict, n_flush,
             n_kill_entry);
    $display("AGU %0d（mmio %0d）、requested %0d（stale 付き %0d）、gone_to_wb %0d、nack %0d", n_agu, n_mmio, n_req,
             n_req_stale, n_gone, n_nack);
    $display("stale_mask で stale になった %0d、load_violation を出した %0d", n_stale_set, n_viol_out);
    if (errors == 0) $display("PASS");
    else $display("FAIL（%0d 件）", errors);
    $finish;
  end

endmodule

`default_nettype wire
