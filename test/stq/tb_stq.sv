`timescale 1ns / 1ps
`default_nettype none

// stq の単体テストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 次のサイクルの入力を決めておき、negedge で DUT に写して、1ns 待ってから組合せの出力をモデルと比べる。
// モデルはポインタを回り込まない通し番号（pos）で持つ。エントリの番号は pos % STQ_SIZE。
//
// テストの前提にしている仕様
//   - dispatch：スロットが小さい方が古い。満杯のスロットの store は無視される。
//     mispredict / flush のサイクルの dispatch は入らない
//   - 分岐の tag は、そのサイクルの頭に空いているものだけを dispatch に出す
//   - mispredict で tail を br_update_ff.tag の snapshot に戻す。flush は tail を commit_head に戻す
//     （同じサイクルの commit も含む。flush が優先）
//   - ex_lsu は生きている store のものだけが来る（同じサイクルに kill される store のものは来ない）
//   - commit は complete の次のサイクル以降で、古い分岐が全部解決した後
//   - st_requested は stq_controller.valid のときだけ。同じエントリの要求は同時に 1 つ
//   - D$ の返事は 1 サイクルに 1 つ。順番は入れ替わるが、同じアドレスの store は accept 順に書く
//   - nack（stale でない）で exec_head をそこに戻し、戻した範囲で返事がまだのものは stale にして返事を捨てる
//   - head のエントリが stored なら、次のサイクルに解放して stq_release_mask を出す
//
// 通しの確認：STQ が空になったとき、D$ のモデルの中身が「commit した store を順に書いたメモリ」と一致する

module tb_stq
  import types::*;
  import ooo_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
();

  localparam int DISP_W = 2;
  localparam int COMMIT_W = 2;
  localparam int N = STQ_SIZE;
  localparam int MEM_N = 16;
  localparam int MAX_ERRORS = 30;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic                rst;
  logic                flush;
  disp_stq_t           disp_st         [  DISP_W];
  stq_idx_t            disp_stq_idx    [  DISP_W];
  logic                disp_full       [  DISP_W];
  logic                disp_br_valid   [  DISP_W];
  br_tag_t             disp_br_tag     [  DISP_W];
  older_st_t           older_st        [  DISP_W];
  stq_mask_t           stq_release_mask;
  ex_lsu_t             ex_lsu;
  logic                st_requested;
  stq_idx_with_valid_t st_ack;
  stq_idx_with_valid_t st_nack;
  stq_controller_t     stq_controller;
  stq_cnt_t            stq_cnt;
  stq_searcher_t       stq_searcher_ff [STQ_SIZE];
  br_update_t          br_update_ff;
  logic                commit_st       [COMMIT_W];
  complete_t           complete_st;
  logic                stq_empty;

  stq #(
    .DISP_W  (DISP_W),
    .COMMIT_W(COMMIT_W)
  ) dut (
    .*
  );

  // テストが書く側。initial の中から DUT の入力を直接書くと Verilator 5.020 の --timing で
  // DUT の組合せ回路が評価し直されないことがあるので、立ち下がりで写す
  logic                t_flush;
  disp_stq_t           t_disp_st       [  DISP_W];
  logic                t_disp_br_valid [  DISP_W];
  br_tag_t             t_disp_br_tag   [  DISP_W];
  ex_lsu_t             t_ex_lsu;
  logic                t_st_requested;
  stq_idx_with_valid_t t_st_ack;
  stq_idx_with_valid_t t_st_nack;
  br_update_t          t_br_update_ff;
  logic                t_commit_st     [COMMIT_W];

  always @(negedge clk) begin
    flush <= t_flush;
    disp_st <= t_disp_st;
    disp_br_valid <= t_disp_br_valid;
    disp_br_tag <= t_disp_br_tag;
    ex_lsu <= t_ex_lsu;
    st_requested <= t_st_requested;
    st_ack <= t_st_ack;
    st_nack <= t_st_nack;
    br_update_ff <= t_br_update_ff;
    commit_st <= t_commit_st;
  end

  // ---------------- 乱数 ----------------

  function automatic int rnd(int n);
    return int'($urandom_range(n - 1, 0));
  endfunction

  // アドレスは少なくして同じアドレスへの store を多く作る
  function automatic addr_t rnd_addr();
    if (rnd(8) == 0) return MMIO_TX_ADDR;
    return addr_t'(rnd(8));
  endfunction

  function automatic int mem_idx(addr_t a);
    return int'(a[3:0]);
  endfunction

  // ---------------- モデル ----------------

  int head_pos, commit_pos, exec_pos, tail_pos;
  bit m_addr_valid[N], m_data_valid[N], m_requested[N], m_stale[N], m_stored[N];
  addr_t m_addr[N];
  word_t m_data[N];
  rob_idx_t m_rob[N];

  // 生きている分岐（古い順）
  int br_tag_q[$];
  int br_snap_q[$];
  bit tag_used[MAX_BR];

  // D$ が抱えている要求（accept 順）
  int infl_idx[$];
  addr_t infl_addr[$];
  word_t infl_data[$];

  word_t arch_mem[MEM_N];  // commit した store を順に書いたもの
  word_t dc_mem[MEM_N];  // D$ が ack した順に書いたもの

  // ---------------- 入力の出し方（一定サイクルごとに変える） ----------------

  int disp_rate, br_disp_rate, br_rate, mis_rate, commit_rate, agu_rate, req_rate, resp_rate, nack_rate;
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
    commit_rate = rnd(2) == 0 ? 30 : 90;
    agu_rate = rnd(2) == 0 ? 40 : 95;
    req_rate = rnd(2) == 0 ? 30 : 95;
    resp_rate = rnd(2) == 0 ? 30 : 95;
    case (rnd(3))
      0: nack_rate = 0;
      1: nack_rate = 10;
      default: nack_rate = 45;
    endcase
    flush_en = 1'b1;
  endtask

  // ---------------- 集計 ----------------

  int unsigned cycles;
  int unsigned seed;
  int unsigned cyc;
  int errors;

  int n_disp, n_full, n_commit, n_release, n_mispredict, n_flush, n_kill_disp;
  int n_nack, n_nack_multi, n_stale_resp, n_ooo_resp, n_empty_check, n_wrap;

  task automatic err(string msg);
    errors++;
    $display("[cycle %0d] %s", cyc, msg);
    if (errors >= MAX_ERRORS) begin
      $display("FAIL（%0d 件で打ち切り）", errors);
      $finish;
    end
  endtask

  // ---------------- 1 サイクル ----------------

  task automatic one_cycle();
    bit do_flush, kill_cycle, stop, resp, resp_nack, was_stale, rel;
    bit exp_ctrl_valid, exp_complete;
    bit res_tag[MAX_BR];
    bit tag_tmp[MAX_BR];
    bit slot_store[DISP_W];
    bit slot_br[DISP_W];
    int slot_tag[DISP_W];
    int exp_idx[DISP_W];
    bit exp_full[DISP_W];
    stq_mask_t exp_older[DISP_W];
    stq_mask_t exp_rel;
    int mis_i, c, min_snap, limit, acc, p, idx, j, k_pos, t;
    int cand[$];
    br_update_t u;
    ex_lsu_t ex;
    disp_stq_t d_st[DISP_W];
    logic d_br_valid[DISP_W];
    br_tag_t d_br_tag[DISP_W];
    logic d_commit[COMMIT_W];

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
      p = commit_pos + c;
      d_commit[i] = 1'b0;
      if (p < tail_pos && p < min_snap && m_addr_valid[p%N] && m_data_valid[p%N] && rnd(100) < commit_rate) begin
        d_commit[i] = 1'b1;
        c++;
      end
    end

    // ---- AGU ----
    // 同じサイクルに kill される store のものは出さない
    if (do_flush) limit = commit_pos + c;
    else if (u.mispredict) limit = br_snap_q[mis_i];
    else limit = tail_pos;
    ex = '0;
    ex.is_store = rnd(2) == 1;
    ex.addr = $urandom();
    ex.data = $urandom();
    ex.ldq_idx = ldq_idx_t'($urandom());
    ex.stq_idx = stq_idx_t'(rnd(N));
    if (rnd(100) < agu_rate) begin
      for (int q = head_pos; q < limit; q++) begin
        if (!m_addr_valid[q%N] || !m_data_valid[q%N]) cand.push_back(q);
      end
    end
    if (cand.size() > 0) begin
      p = cand[rnd(cand.size())];
      ex.is_store = 1'b1;
      ex.stq_idx = stq_idx_t'(p % N);
      ex.addr = rnd_addr();
      if (!m_addr_valid[p%N] && !m_data_valid[p%N]) begin
        case (rnd(3))
          0: {ex.addr_valid, ex.data_valid} = 2'b11;
          1: {ex.addr_valid, ex.data_valid} = 2'b10;
          default: {ex.addr_valid, ex.data_valid} = 2'b01;
        endcase
      end else begin
        ex.addr_valid = !m_addr_valid[p%N];
        ex.data_valid = !m_data_valid[p%N];
      end
    end else if (rnd(3) == 0) begin
      // load。STQ は無視するはず
      ex.is_store = 1'b0;
      ex.addr_valid = 1'b1;
      ex.data_valid = rnd(2) == 1;
    end

    // ---- dispatch ----
    acc = 0;
    stop = 1'b0;
    for (int i = 0; i < MAX_BR; i++) tag_tmp[i] = tag_used[i];
    for (int i = 0; i < DISP_W; i++) begin
      d_st[i].valid = 1'b0;
      d_st[i].rob_idx = rob_idx_t'($urandom());
      d_br_valid[i] = 1'b0;
      d_br_tag[i] = br_tag_t'($urandom());
      slot_store[i] = 1'b0;
      slot_br[i] = 1'b0;
      slot_tag[i] = 0;
      exp_idx[i] = (tail_pos + acc) % N;
      exp_full[i] = tail_pos + acc - head_pos == N;
      exp_older[i] = '0;
      for (int q = head_pos; q < tail_pos + acc; q++) exp_older[i][q%N] = 1'b1;
      if (!stop) begin
        j = rnd(100);
        if (j < disp_rate) begin
          d_st[i].valid = 1'b1;
          if (exp_full[i]) begin
            // 満杯でも valid を出す（STQ が無視するはず）。後ろのスロットは出さない
            stop = 1'b1;
            n_full++;
          end else begin
            slot_store[i] = 1'b1;
            acc++;
          end
        end else if (j < disp_rate + br_disp_rate) begin
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
          end
        end
      end
    end

    // ---- controller と D$ ----
    exp_ctrl_valid = exec_pos != commit_pos && !m_requested[exec_pos%N];
    t_st_requested = exp_ctrl_valid && rnd(100) < req_rate;
    t_st_ack.valid = 1'b0;
    t_st_ack.stq_idx = stq_idx_t'(rnd(N));
    t_st_nack.valid = 1'b0;
    t_st_nack.stq_idx = stq_idx_t'(rnd(N));
    resp = infl_idx.size() > 0 && rnd(100) < resp_rate;
    resp_nack = 1'b0;
    j = 0;
    if (resp) begin
      if (rnd(10) >= 7) begin
        j = rnd(infl_idx.size());
        // 同じアドレスの store は追い越さない
        for (int k = 0; k < j; k++) begin
          if (infl_addr[k] == infl_addr[j]) j = 0;
        end
      end
      if (j != 0) n_ooo_resp++;
      resp_nack = rnd(100) < nack_rate;
      if (resp_nack) begin
        t_st_nack.valid = 1'b1;
        t_st_nack.stq_idx = stq_idx_t'(infl_idx[j]);
      end else begin
        t_st_ack.valid = 1'b1;
        t_st_ack.stq_idx = stq_idx_t'(infl_idx[j]);
      end
    end

    t_disp_st = d_st;
    t_disp_br_valid = d_br_valid;
    t_disp_br_tag = d_br_tag;
    t_commit_st = d_commit;
    t_flush = do_flush;
    t_br_update_ff = u;
    t_ex_lsu = ex;

    @(negedge clk);
    #1;

    // ---- 出力の確認 ----
    for (int i = 0; i < DISP_W; i++) begin
      if (int'(disp_stq_idx[i]) != exp_idx[i])
        err($sformatf("disp_stq_idx[%0d] = %0d、期待値 %0d", i, disp_stq_idx[i], exp_idx[i]));
      if (disp_full[i] != exp_full[i])
        err($sformatf("disp_full[%0d] = %0b、期待値 %0b", i, disp_full[i], exp_full[i]));
      if (int'(older_st[i].tail_stq_idx) != exp_idx[i])
        err($sformatf("older_st[%0d].tail_stq_idx = %0d、期待値 %0d", i, older_st[i].tail_stq_idx, exp_idx[i]));
    end

    rel = m_stored[head_pos%N];
    exp_rel = '0;
    if (rel) exp_rel[head_pos%N] = 1'b1;
    if (stq_release_mask != exp_rel)
      err($sformatf("stq_release_mask = %b、期待値 %b", stq_release_mask, exp_rel));
    for (int i = 0; i < DISP_W; i++) begin
      if (older_st[i].older_st_mask != (exp_older[i] & ~exp_rel))
        err($sformatf("older_st[%0d].older_st_mask = %b、期待値 %b", i, older_st[i].older_st_mask,
                      exp_older[i] & ~exp_rel));
    end

    if (stq_empty != (head_pos == tail_pos))
      err($sformatf("stq_empty = %0b、期待値 %0b", stq_empty, head_pos == tail_pos));
    if (int'(stq_cnt) != tail_pos - head_pos)
      err($sformatf("stq_cnt = %0d、期待値 %0d", stq_cnt, tail_pos - head_pos));

    if (stq_controller.valid != exp_ctrl_valid)
      err($sformatf("stq_controller.valid = %0b、期待値 %0b", stq_controller.valid, exp_ctrl_valid));
    if (exp_ctrl_valid) begin
      idx = exec_pos % N;
      if (int'(stq_controller.stq_idx) != idx)
        err($sformatf("stq_controller.stq_idx = %0d、期待値 %0d", stq_controller.stq_idx, idx));
      if (stq_controller.addr != m_addr[idx])
        err($sformatf("stq_controller.addr = %h、期待値 %h", stq_controller.addr, m_addr[idx]));
      if (stq_controller.data != m_data[idx])
        err($sformatf("stq_controller.data = %h、期待値 %h", stq_controller.data, m_data[idx]));
    end

    exp_complete = 1'b0;
    if (ex.is_store && (ex.addr_valid || ex.data_valid)) begin
      idx = int'(ex.stq_idx);
      exp_complete = (ex.addr_valid || m_addr_valid[idx]) && (ex.data_valid || m_data_valid[idx]);
      if (exp_complete && complete_st.rob_idx != m_rob[idx])
        err($sformatf("complete_st.rob_idx = %0d、期待値 %0d", complete_st.rob_idx, m_rob[idx]));
    end
    if (complete_st.valid != exp_complete)
      err($sformatf("complete_st.valid = %0b、期待値 %0b", complete_st.valid, exp_complete));

    for (int q = head_pos; q < tail_pos; q++) begin
      idx = q % N;
      if (stq_searcher_ff[idx].addr_valid != m_addr_valid[idx])
        err($sformatf("stq_searcher_ff[%0d].addr_valid = %0b、期待値 %0b", idx, stq_searcher_ff[idx].addr_valid,
                      m_addr_valid[idx]));
      else if (m_addr_valid[idx] && stq_searcher_ff[idx].addr != m_addr[idx])
        err($sformatf("stq_searcher_ff[%0d].addr = %h、期待値 %h", idx, stq_searcher_ff[idx].addr, m_addr[idx]));
      if (stq_searcher_ff[idx].data_valid != m_data_valid[idx])
        err($sformatf("stq_searcher_ff[%0d].data_valid = %0b、期待値 %0b", idx, stq_searcher_ff[idx].data_valid,
                      m_data_valid[idx]));
      else if (m_data_valid[idx] && stq_searcher_ff[idx].data != m_data[idx])
        err($sformatf("stq_searcher_ff[%0d].data = %h、期待値 %h", idx, stq_searcher_ff[idx].data, m_data[idx]));
    end

    // ---- モデルを進める ----
    if (kill_cycle) begin
      for (int i = 0; i < DISP_W; i++) begin
        if (slot_store[i] || slot_br[i]) n_kill_disp++;
      end
    end else begin
      for (int i = 0; i < DISP_W; i++) begin
        if (slot_store[i]) begin
          idx = tail_pos % N;
          m_addr_valid[idx] = 1'b0;
          m_data_valid[idx] = 1'b0;
          m_requested[idx] = 1'b0;
          m_stale[idx] = 1'b0;
          m_stored[idx] = 1'b0;
          m_rob[idx] = d_st[i].rob_idx;
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

    if (ex.is_store) begin
      idx = int'(ex.stq_idx);
      if (ex.addr_valid) begin
        m_addr_valid[idx] = 1'b1;
        m_addr[idx] = ex.addr;
      end
      if (ex.data_valid) begin
        m_data_valid[idx] = 1'b1;
        m_data[idx] = ex.data;
      end
    end

    for (int i = 0; i < c; i++) begin
      idx = commit_pos % N;
      arch_mem[mem_idx(m_addr[idx])] = m_data[idx];
      commit_pos++;
      n_commit++;
    end

    if (resp) begin
      idx = infl_idx[j];
      was_stale = m_stale[idx];
      // D$ は stale かどうかを知らないので、ack したものは書いている
      if (!resp_nack) dc_mem[mem_idx(infl_addr[j])] = infl_data[j];
    end

    if (t_st_requested) begin
      idx = exec_pos % N;
      m_requested[idx] = 1'b1;
      infl_idx.push_back(idx);
      infl_addr.push_back(m_addr[idx]);
      infl_data.push_back(m_data[idx]);
      exec_pos++;
    end

    if (resp) begin
      idx = infl_idx[j];
      if (was_stale) begin
        m_requested[idx] = 1'b0;
        m_stale[idx] = 1'b0;
        n_stale_resp++;
      end else if (!resp_nack) begin
        m_requested[idx] = 1'b0;
        m_stored[idx] = 1'b1;
      end else begin
        k_pos = -1;
        for (int q = head_pos; q < exec_pos; q++) begin
          if (q % N == idx) k_pos = q;
        end
        if (k_pos < 0) begin
          err("テスト側の誤り：nack した store が head と exec_head の間に無い");
        end else begin
          if (exec_pos - k_pos > 1) n_nack_multi++;
          for (int q = k_pos; q < exec_pos; q++) begin
            m_stored[q%N] = 1'b0;
            m_stale[q%N]  = m_requested[q%N];
          end
          m_requested[idx] = 1'b0;
          m_stale[idx] = 1'b0;
          exec_pos = k_pos;
        end
        n_nack++;
      end
      infl_idx.delete(j);
      infl_addr.delete(j);
      infl_data.delete(j);
    end

    if (rel) begin
      m_stored[head_pos%N] = 1'b0;
      head_pos++;
      n_release++;
    end

    if (do_flush) begin
      tail_pos = commit_pos;
      br_tag_q.delete();
      br_snap_q.delete();
      for (int i = 0; i < MAX_BR; i++) tag_used[i] = 1'b0;
      n_flush++;
    end else begin
      if (u.mispredict) begin
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

    if (!(head_pos <= exec_pos && exec_pos <= commit_pos && commit_pos <= tail_pos && tail_pos - head_pos <= N))
      err($sformatf("テスト側の誤り：モデルのポインタの順番が崩れた（head %0d exec %0d commit %0d tail %0d）",
                    head_pos, exec_pos, commit_pos, tail_pos));

    // ---- 空になったら D$ の中身を確かめる ----
    if (head_pos == tail_pos) begin
      n_empty_check++;
      if (infl_idx.size() != 0) err("STQ が空なのに D$ に要求が残っている");
      for (int i = 0; i < MEM_N; i++) begin
        if (dc_mem[i] != arch_mem[i])
          err($sformatf("D$ の中身が違う：mem[%0d] = %h、commit 順に書いた値 %h", i, dc_mem[i], arch_mem[i]));
      end
    end
  endtask

  // ---------------- 本体 ----------------

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("stq: seed=%0d cycles=%0d", seed, cycles);

    rst = 1'b1;
    t_flush = 1'b0;
    t_br_update_ff = '0;
    t_ex_lsu = '0;
    t_st_requested = 1'b0;
    t_st_ack = '0;
    t_st_nack = '0;
    for (int i = 0; i < DISP_W; i++) begin
      t_disp_st[i] = '0;
      t_disp_br_valid[i] = 1'b0;
      t_disp_br_tag[i] = '0;
    end
    for (int i = 0; i < COMMIT_W; i++) t_commit_st[i] = 1'b0;
    for (int i = 0; i < N; i++) begin
      m_addr_valid[i] = 1'b0;
      m_data_valid[i] = 1'b0;
      m_requested[i] = 1'b0;
      m_stale[i] = 1'b0;
      m_stored[i] = 1'b0;
      m_addr[i] = '0;
      m_data[i] = '0;
      m_rob[i] = '0;
    end
    for (int i = 0; i < MEM_N; i++) begin
      arch_mem[i] = '0;
      dc_mem[i] = '0;
    end
    repeat (3) @(negedge clk);
    rst = 1'b0;
    // 入力を写す always より後に次の入力を決める
    #1;

    for (cyc = 0; cyc < cycles; cyc++) begin
      if (cyc % 512 == 0) pick_rates();
      one_cycle();
    end

    // 最後に全部吐き出させる
    disp_rate = 0;
    br_disp_rate = 0;
    br_rate = 100;
    mis_rate = 0;
    commit_rate = 100;
    agu_rate = 100;
    req_rate = 100;
    resp_rate = 100;
    nack_rate = 0;
    flush_en = 1'b0;
    for (int i = 0; i < 2000; i++) begin
      if (!(head_pos == tail_pos && br_tag_q.size() == 0)) begin
        one_cycle();
        cyc++;
      end
    end
    if (head_pos != tail_pos) err("最後に STQ が空にならなかった");

    $display("dispatch %0d（満杯で断った %0d、kill のサイクルで捨てた %0d、一周 %0d 回）", n_disp, n_full,
             n_kill_disp, n_wrap);
    $display("commit %0d、解放 %0d、mispredict %0d、flush %0d", n_commit, n_release, n_mispredict, n_flush);
    $display("nack %0d（後ろも巻き込んだ %0d）、stale の返事 %0d、順番が入れ替わった返事 %0d、空での確認 %0d 回",
             n_nack, n_nack_multi, n_stale_resp, n_ooo_resp, n_empty_check);
    if (errors == 0) $display("PASS");
    else $display("FAIL（%0d 件）", errors);
    $finish;
  end

endmodule

`default_nettype wire
