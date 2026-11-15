`timescale 1ns / 1ps
`default_nettype none

// lsu_top の通しのテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 300000）
//   +seed=N    乱数の種（既定 1）
//
// テストベンチが ROB・dispatch・AGU・分岐・D$ の役をやる。命令列は決めておかず、毎サイクルでたらめに
// load / store / 分岐 を dispatch する。mispredict や flush で消えた命令は捨てて、新しい命令を続ける。
//
// 期待値は commit の時点で決める（DUT の中の状態は見ない）
//   - store を commit したら「commit 順に書いたメモリ」に書く
//   - load を commit するとき、WB に出た値がそのメモリの値と同じであること
//     （違うなら load_violation が立って flush されていなければならない）
//   - MMIO の load は ROB の先頭のときにだけ D$ に出て、accept は 1 回だけ。値は accept の順番どおり
//   - STQ が空になったら、D$ のモデルの中身が「commit 順に書いたメモリ」と同じであること
//   - 先頭の命令が長い間 commit できなければ詰まったとみなす
//
// サイクルの進め方：posedge の 1ns 後に次の入力を決め（FF だけで決まる出力はここで読む）、negedge で DUT に写して、
// その 1ns 後に組合せの出力を確かめてからモデルを進める。
//
// テストの前提にしている仕様
//   - dispatch：スロットが小さい方が古い。LDQ / STQ が満杯なら出さない（STQ の空きは dut.stq_cnt から数える）。
//     mispredict / flush のサイクルは出さない。分岐の tag はそのサイクルの頭に空いているものだけ
//   - ex_lsu は生きている命令のものだけ（同じサイクルに kill されるものは来ない）。load はアドレス、
//     store は STA と STD を別々か同時に 1 回ずつ
//   - commit は complete（load は WB、store は complete_st、分岐は解決）の次のサイクル以降
//   - load を commit するとき、load_violation のどれかがその rob_idx で立っていたら commit せず、
//     次のサイクルに flush を出す（flush のサイクルは dispatch / AGU / commit / 分岐の解決をしない）
//   - rob_head_ld は ROB の先頭が load のとき
//   - 分岐は 1 サイクルに 2 つまで解決する。mispredict が 2 つなら古い方の tag を出す
//
// D$ のモデル
//   - dc_req_valid_ff の要求をでたらめなサイクルに accept する。accept したサイクルに kill される load は捨てる
//   - 返事は accept の次のサイクル以降に 1 サイクル 1 つ、順番はでたらめ、ack か nack
//   - kill された load（brmask と kill_mask が重なる、または kill_all）は次のサイクルから返事をしない。
//     kill のサイクルの返事は出ることがある
//   - store は ack のときに書く。同じアドレスの store は accept した順に書く（前のものが残っていたら ack しない）
//   - MMIO の load は nack しない

module tb_lsu_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
();

  localparam int DISP_W = 2;
  localparam int COMMIT_W = 2;
  localparam int LN = LDQ_SIZE;
  localparam int SN = STQ_SIZE;
  localparam int NID = 1 << $bits(rob_idx_t);
  localparam int ROB_CAP = 24;
  localparam int MEM_N = 6;
  localparam int STALL_LIMIT = 4000;
  localparam int MAX_ERRORS = 30;
  localparam int K_LD = 0;
  localparam int K_ST = 1;
  localparam int K_BR = 2;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic                         rst;
  logic                         flush;
  disp_ldq_t                    disp_ld               [  DISP_W];
  ldq_idx_t                     disp_ldq_idx          [  DISP_W];
  logic                         disp_ld_full          [  DISP_W];
  disp_stq_t                    disp_st               [  DISP_W];
  stq_idx_t                     disp_stq_idx          [  DISP_W];
  logic                         disp_st_full          [  DISP_W];
  logic                         disp_br_valid         [  DISP_W];
  br_tag_t                      disp_br_tag           [  DISP_W];
  ex_lsu_t                      ex_lsu                [       1];
  br_update_t                   br_update_ff;
  logic                         commit_ld             [COMMIT_W];
  logic                         commit_st             [COMMIT_W];
  logic                         rob_head_ld;
  complete_t                    complete_st;
  logic                         stq_empty;
  load_violation_t              load_violation        [COMMIT_W];
  lsu_wb_t                      wb_mem                [       1];
  wakeup_t                      slow_wakeup_mem;
  logic                         dc_req_valid_ff;
  logic                         dc_req_we_ff;
  logic            [      31:0] dc_req_addr_ff;
  logic            [      31:0] dc_req_wdata_ff;
  logic            [DC_TAG_W-1:0] dc_req_tag_ff;
  logic            [MAX_BR-1:0] dc_req_brmask_ff;
  logic                         dc_req_accepted;
  logic                         dc_resp_valid;
  logic                         dc_resp_ack;
  logic            [      31:0] dc_resp_rdata;
  logic            [DC_TAG_W-1:0] dc_resp_tag;
  logic            [MAX_BR-1:0] dc_br_kill_mask_ff;
  logic            [MAX_BR-1:0] dc_br_resolve_mask_ff;
  logic                         dc_kill_all_ff;

  lsu_top #(
    .DISP_W  (DISP_W),
    .COMMIT_W(COMMIT_W)
  ) dut (
    .*
  );

  // テストが書く側。initial の中から DUT の入力を直接書くと Verilator 5.020 の --timing で
  // DUT の組合せ回路が評価し直されないことがあるので、立ち下がりで写す
  logic                         t_flush;
  disp_ldq_t                    t_disp_ld      [  DISP_W];
  disp_stq_t                    t_disp_st      [  DISP_W];
  logic                         t_disp_br_valid[  DISP_W];
  br_tag_t                      t_disp_br_tag  [  DISP_W];
  ex_lsu_t                      t_ex_lsu;
  br_update_t                   t_br_update_ff;
  logic                         t_commit_ld    [COMMIT_W];
  logic                         t_commit_st    [COMMIT_W];
  logic                         t_rob_head_ld;
  logic                         t_dc_req_accepted;
  logic                         t_dc_resp_valid;
  logic                         t_dc_resp_ack;
  logic          [        31:0] t_dc_resp_rdata;
  logic          [DC_TAG_W-1:0] t_dc_resp_tag;

  always @(negedge clk) begin
    flush <= t_flush;
    disp_ld <= t_disp_ld;
    disp_st <= t_disp_st;
    disp_br_valid <= t_disp_br_valid;
    disp_br_tag <= t_disp_br_tag;
    ex_lsu[0] <= t_ex_lsu;
    br_update_ff <= t_br_update_ff;
    commit_ld <= t_commit_ld;
    commit_st <= t_commit_st;
    rob_head_ld <= t_rob_head_ld;
    dc_req_accepted <= t_dc_req_accepted;
    dc_resp_valid <= t_dc_resp_valid;
    dc_resp_ack <= t_dc_resp_ack;
    dc_resp_rdata <= t_dc_resp_rdata;
    dc_resp_tag <= t_dc_resp_tag;
  end

  // ---------------- 乱数とアドレス ----------------

  function automatic int rnd(int n);
    return int'($urandom_range(n - 1, 0));
  endfunction

  // アドレスは少なくして load と store をぶつける。上位ビットだけ違うものも混ぜる
  function automatic addr_t addr_of(int ai);
    case (ai)
      4: return 32'h8000_0001;
      5: return 32'h0001_0000;
      default: return addr_t'(ai);
    endcase
  endfunction

  function automatic int ai_of(addr_t a);
    for (int i = 0; i < MEM_N; i++) begin
      if (addr_of(i) == a) return i;
    end
    return -1;
  endfunction

  function automatic word_t mmio_val(int n);
    return 32'hcafe_0000 + word_t'(n);
  endfunction

  // ---------------- 命令（番号は rob_idx の値） ----------------

  int rob_q[$];  // 生きている命令。古い順
  bit in_use[NID];
  int i_kind[NID];
  int i_ldq[NID];
  int i_stq[NID];
  int i_tag[NID];
  int i_ai[NID];
  bit i_mmio[NID];
  word_t i_data[NID];
  preg_t i_rd[NID];
  bit i_addr_sent[NID];
  bit i_data_sent[NID];
  bit i_resolved[NID];
  int i_done[NID];  // complete したサイクル。まだなら -1
  word_t i_value[NID];
  bit i_fwd[NID];
  int i_disp_cyc[NID];
  int next_id;

  int ldq_owner[LN];  // LDQ のエントリを使っている命令。空なら -1
  // STQ のエントリの中身（commit 後も D$ に書くまで残る）
  bit s_live[SN];
  bit s_committed[SN];
  int s_ai[SN];
  word_t s_data[SN];

  bit tag_used[MAX_BR];
  bit flush_next;

  word_t arch_mem[MEM_N];  // commit 順に書いたメモリ
  word_t dc_mem[MEM_N];  // D$ のモデル
  int mmio_acc_n, mmio_commit_n;

  // D$ が accept して返事をしていない要求（accept 順）
  bit p_we[$];
  bit p_mmio[$];
  int p_ai[$];
  int p_idx[$];
  int p_cyc[$];
  word_t p_data[$];
  brmask_t p_brmask[$];

  // ---------------- 入力の出し方（一定サイクルごとに変える） ----------------

  int ld_rate, st_rate, br_rate_d, res_rate, mis_rate, commit_rate, agu_rate, acc_rate, resp_rate, nack_rate;
  int mmio_rate, agu_ld_first;
  bit draining;

  task automatic pick_rates();
    case (rnd(3))
      0: begin
        ld_rate = 45;
        st_rate = 15;
      end
      1: begin
        ld_rate = 15;
        st_rate = 45;
      end
      default: begin
        ld_rate = 30;
        st_rate = 30;
      end
    endcase
    br_rate_d = rnd(2) == 0 ? 5 : 20;
    res_rate = rnd(2) == 0 ? 15 : 60;
    mis_rate = rnd(3) == 0 ? 50 : 10;
    commit_rate = rnd(3) == 0 ? 30 : 90;
    agu_rate = rnd(3) == 0 ? 40 : 95;
    acc_rate = rnd(3) == 0 ? 25 : 85;
    resp_rate = rnd(3) == 0 ? 25 : 85;
    nack_rate = rnd(3) == 0 ? 35 : 5;
    mmio_rate = rnd(2) == 0 ? 0 : 8;
    // load のアドレスを先に出しがちにすると順序違反が増える
    agu_ld_first = rnd(3) == 0 ? 80 : 0;
  endtask

  // ---------------- 集計 ----------------

  int unsigned cycles;
  int unsigned seed;
  int cyc;
  int errors;
  int last_progress;

  int n_disp_ld, n_disp_st, n_disp_br, n_full_ld, n_full_st;
  int n_commit_ld, n_commit_st, n_commit_br, n_mispredict, n_kill_ins, n_flush;
  int n_wb_dc, n_wb_fwd, n_wb_killed, n_mmio;
  int n_dc_ld, n_dc_st, n_dc_drop, n_dc_kill, n_ld_nack, n_st_nack, n_st_hold, n_resp_killed;
  int n_empty_check, n_ld_wait_max, n_both;

  task automatic err(string msg);
    errors++;
    $display("[cycle %0d] %s", cyc, msg);
    if (errors >= MAX_ERRORS) begin
      $display("FAIL（%0d 件で打ち切り）", errors);
      $finish;
    end
  endtask

  function automatic int pos_of(int id);
    for (int p = 0; p < rob_q.size(); p++) begin
      if (rob_q[p] == id) return p;
    end
    return -1;
  endfunction

  function automatic string ins_str(int id);
    case (i_kind[id])
      K_LD:
      return $sformatf(
          "load（rob %0d、LDQ %0d、addr %h、アドレス送った %0b、complete %0d、dispatch %0d）",
          id,
          i_ldq[id],
          i_mmio[id] ? MMIO_RX_ADDR : addr_of(
              i_ai[id]
          ),
          i_addr_sent[id],
          i_done[id],
          i_disp_cyc[id]
      );
      K_ST:
      return $sformatf(
          "store（rob %0d、STQ %0d、addr %h、STA %0b STD %0b、complete %0d）",
          id,
          i_stq[id],
          addr_of(
              i_ai[id]
          ),
          i_addr_sent[id],
          i_data_sent[id],
          i_done[id]
      );
      default: return $sformatf("分岐（rob %0d、tag %0d、解決 %0b）", id, i_tag[id], i_resolved[id]);
    endcase
  endfunction

  // ---------------- このサイクルの入力（decide で決めて advance で使う） ----------------

  bit c_flush;
  br_update_t c_u;
  int c_mis_pos, c_kill_from, c_n_commit;
  bit c_res_tag[MAX_BR];
  bit c_viol;
  ex_lsu_t c_ex;
  int c_ex_id;
  int c_d_kind[DISP_W];
  int c_d_id[DISP_W];
  bit c_acc;
  int c_resp_j;
  bit c_resp_ack;
  word_t c_resp_rdata;

  function automatic int alloc_id();
    for (int k = 0; k < NID; k++) begin
      next_id = (next_id + 1) % NID;
      if (!in_use[next_id]) begin
        in_use[next_id] = 1'b1;
        return next_id;
      end
    end
    return -1;
  endfunction

  task automatic decide();
    int cand[$];
    int j, p, id, t, ld_cnt, st_room, n_new, r;
    brmask_t cur_mask;
    bit tag_tmp[MAX_BR];
    bit blocked, stop;
    lsu_tag_t tg;
    disp_ldq_t d_ld[DISP_W];
    disp_stq_t d_st[DISP_W];
    logic d_br_valid[DISP_W];
    br_tag_t d_br_tag[DISP_W];
    logic d_c_ld[COMMIT_W];
    logic d_c_st[COMMIT_W];

    // ---- STQ が空なら D$ の中身を確かめる ----
    if (stq_empty) begin
      foreach (rob_q[k]) begin
        if (i_kind[rob_q[k]] == K_ST) err($sformatf("stq_empty なのに生きている store がある：%s", ins_str(rob_q[k])));
      end
      n_empty_check++;
      for (int i = 0; i < MEM_N; i++) begin
        if (dc_mem[i] != arch_mem[i])
          err($sformatf("stq_empty なのに D$ の中身が違う：mem[%h] = %h、commit 順に書いた値 %h", addr_of(i), dc_mem[i],
                        arch_mem[i]));
      end
    end

    // ---- flush と分岐の解決 ----
    c_flush = flush_next;
    c_u = '0;
    c_u.pc = pc_t'($urandom());
    c_u.target = pc_t'($urandom());
    c_u.taken = rnd(2) == 1;
    c_u.rob_idx = rob_idx_t'($urandom());
    c_u.tag = br_tag_t'($urandom());
    c_mis_pos = -1;
    for (int i = 0; i < MAX_BR; i++) c_res_tag[i] = 1'b0;
    if (!c_flush) begin
      foreach (rob_q[k]) begin
        if (i_kind[rob_q[k]] == K_BR && !i_resolved[rob_q[k]]) cand.push_back(k);
      end
      for (int k = 0; k < 2; k++) begin
        if (cand.size() > 0 && rnd(100) < res_rate) begin
          p = cand[rnd(cand.size())];
          t = i_tag[rob_q[p]];
          if (!c_u.kill_mask[t] && !c_u.resolve_mask[t]) begin
            if (rnd(100) < mis_rate) begin
              c_u.kill_mask[t] = 1'b1;
              if (c_mis_pos < 0 || p < c_mis_pos) c_mis_pos = p;
            end else begin
              c_u.resolve_mask[t] = 1'b1;
            end
            c_res_tag[t] = 1'b1;
          end
        end
      end
      cand.delete();
      if (c_mis_pos >= 0) begin
        c_u.mispredict = 1'b1;
        c_u.tag = br_tag_t'(i_tag[rob_q[c_mis_pos]]);
      end
    end
    if (c_flush) c_kill_from = 0;
    else if (c_mis_pos >= 0) c_kill_from = c_mis_pos + 1;
    else c_kill_from = rob_q.size();

    // ---- commit ----
    c_n_commit = 0;
    c_viol = 1'b0;
    stop = c_flush;
    for (int i = 0; i < COMMIT_W; i++) begin
      d_c_ld[i] = 1'b0;
      d_c_st[i] = 1'b0;
      if (stop || c_n_commit >= c_kill_from) continue;
      id = rob_q[c_n_commit];
      if (i_done[id] < 0 || i_done[id] >= cyc || rnd(100) >= commit_rate) begin
        stop = 1'b1;
        continue;
      end
      if (i_kind[id] == K_LD) begin
        for (int k = 0; k < COMMIT_W; k++) begin
          if (load_violation[k].valid && load_violation[k].rob_idx == rob_idx_t'(id)) c_viol = 1'b1;
        end
        if (c_viol) begin
          stop = 1'b1;
          continue;
        end
        d_c_ld[i] = 1'b1;
      end else if (i_kind[id] == K_ST) begin
        d_c_st[i] = 1'b1;
      end
      c_n_commit++;
    end

    // ---- AGU ----
    c_ex = '0;
    c_ex.addr = $urandom();
    c_ex.data = $urandom();
    c_ex.ldq_idx = ldq_idx_t'($urandom());
    c_ex.stq_idx = stq_idx_t'($urandom());
    c_ex_id = -1;
    if (!c_flush && rnd(100) < agu_rate) begin
      if (rnd(100) < agu_ld_first) begin
        for (p = 0; p < c_kill_from; p++) begin
          id = rob_q[p];
          if (i_kind[id] == K_LD && !i_addr_sent[id]) cand.push_back(id);
        end
      end
      if (cand.size() == 0) begin
        for (p = 0; p < c_kill_from; p++) begin
          id = rob_q[p];
          if (i_kind[id] == K_LD && !i_addr_sent[id]) cand.push_back(id);
          if (i_kind[id] == K_ST && (!i_addr_sent[id] || !i_data_sent[id])) cand.push_back(id);
        end
      end
      if (cand.size() > 0) begin
        id = cand[rnd(cand.size())];
        c_ex_id = id;
        if (i_kind[id] == K_LD) begin
          c_ex.is_store = 1'b0;
          c_ex.addr_valid = 1'b1;
          c_ex.data_valid = 1'b0;
          c_ex.addr = i_mmio[id] ? MMIO_RX_ADDR : addr_of(i_ai[id]);
          c_ex.ldq_idx = ldq_idx_t'(i_ldq[id]);
        end else begin
          c_ex.is_store = 1'b1;
          c_ex.stq_idx = stq_idx_t'(i_stq[id]);
          // まだ出していない方を出す。両方まだなら STA だけ / STD だけ / 同時
          if (i_addr_sent[id]) c_ex.data_valid = 1'b1;
          else if (i_data_sent[id]) c_ex.addr_valid = 1'b1;
          else begin
            case (rnd(3))
              0: c_ex.addr_valid = 1'b1;
              1: c_ex.data_valid = 1'b1;
              default: begin
                c_ex.addr_valid = 1'b1;
                c_ex.data_valid = 1'b1;
              end
            endcase
          end
          if (c_ex.addr_valid) c_ex.addr = addr_of(i_ai[id]);
          if (c_ex.data_valid) c_ex.data = i_data[id];
        end
      end
      cand.delete();
    end

    // ---- dispatch ----
    cur_mask = '0;
    ld_cnt = 0;
    foreach (rob_q[k]) begin
      id = rob_q[k];
      if (i_kind[id] == K_BR && !i_resolved[id]) cur_mask[i_tag[id]] = 1'b1;
      if (i_kind[id] == K_LD) ld_cnt++;
    end
    st_room = SN - int'(dut.stq_cnt);
    for (int i = 0; i < MAX_BR; i++) tag_tmp[i] = tag_used[i];
    n_new = 0;
    stop = c_flush || c_mis_pos >= 0 || draining;
    for (int i = 0; i < DISP_W; i++) begin
      d_ld[i] = '0;
      d_ld[i].rd.typ = preg_type_t'(rnd(2));
      d_ld[i].rd.idx = preg_idx_t'($urandom());
      d_ld[i].rob_idx = rob_idx_t'($urandom());
      d_ld[i].brmask = brmask_t'($urandom());
      d_st[i] = '0;
      d_st[i].rob_idx = rob_idx_t'($urandom());
      d_br_valid[i] = 1'b0;
      d_br_tag[i] = br_tag_t'($urandom());
      c_d_kind[i] = -1;
      c_d_id[i] = -1;
      if (stop || rob_q.size() + n_new >= ROB_CAP) continue;
      r = rnd(100);
      if (r < ld_rate) begin
        if (ld_cnt >= LN) begin
          // 満杯。後ろのスロットも出さない
          n_full_ld++;
          stop = 1'b1;
          continue;
        end
        id = alloc_id();
        i_kind[id] = K_LD;
        i_mmio[id] = rnd(100) < mmio_rate;
        i_ai[id] = rnd(MEM_N);
        i_rd[id] = d_ld[i].rd;
        d_ld[i].valid = 1'b1;
        d_ld[i].rob_idx = rob_idx_t'(id);
        d_ld[i].brmask = cur_mask;
        ld_cnt++;
      end else if (r < ld_rate + st_rate) begin
        if (st_room <= 0) begin
          n_full_st++;
          stop = 1'b1;
          continue;
        end
        id = alloc_id();
        i_kind[id] = K_ST;
        i_mmio[id] = 1'b0;
        i_ai[id] = rnd(MEM_N);
        i_data[id] = $urandom();
        d_st[i].valid = 1'b1;
        d_st[i].rob_idx = rob_idx_t'(id);
        st_room--;
      end else if (r < ld_rate + st_rate + br_rate_d) begin
        t = -1;
        for (int k = 0; k < MAX_BR; k++) begin
          if (t < 0 && !tag_tmp[k]) t = k;
        end
        if (t < 0) continue;
        id = alloc_id();
        i_kind[id] = K_BR;
        i_tag[id] = t;
        tag_tmp[t] = 1'b1;
        cur_mask[t] = 1'b1;
        d_br_valid[i] = 1'b1;
        d_br_tag[i] = br_tag_t'(t);
      end else begin
        continue;
      end
      i_addr_sent[id] = 1'b0;
      i_data_sent[id] = 1'b0;
      i_resolved[id] = 1'b0;
      i_done[id] = -1;
      i_fwd[id] = 1'b0;
      i_disp_cyc[id] = cyc;
      c_d_kind[i] = i_kind[id];
      c_d_id[i] = id;
      n_new++;
    end

    // ---- D$ ----
    c_acc = dc_req_valid_ff && rnd(100) < acc_rate;
    c_resp_j = -1;
    c_resp_ack = rnd(2) == 1;
    c_resp_rdata = $urandom();
    tg = lsu_tag_t'($urandom());
    if (rnd(100) < resp_rate) begin
      for (j = 0; j < p_cyc.size(); j++) begin
        if (p_cyc[j] < cyc) cand.push_back(j);
      end
      if (cand.size() > 0) begin
        j = cand[rnd(cand.size())];
        c_resp_j = j;
        tg = '0;
        if (p_we[j]) begin
          // 同じアドレスの store は accept 順に書く
          blocked = 1'b0;
          for (int k = 0; k < j; k++) begin
            if (p_we[k] && p_ai[k] == p_ai[j]) blocked = 1'b1;
          end
          c_resp_ack = !blocked && rnd(100) >= nack_rate;
          if (blocked && rnd(2) == 0) begin
            c_resp_j = -1;
            n_st_hold++;
          end
          tg.is_store = 1'b1;
          tg.stq_idx = stq_idx_t'(p_idx[j]);
          tg.ldq_idx = ldq_idx_t'($urandom());
        end else begin
          c_resp_ack = p_mmio[j] || rnd(100) >= nack_rate;
          c_resp_rdata = p_mmio[j] ? p_data[j] : dc_mem[p_ai[j]];
          tg.is_store = 1'b0;
          tg.ldq_idx = ldq_idx_t'(p_idx[j]);
          tg.stq_idx = stq_idx_t'($urandom());
        end
      end
      cand.delete();
    end

    t_flush = c_flush;
    t_br_update_ff = c_u;
    t_commit_ld = d_c_ld;
    t_commit_st = d_c_st;
    t_rob_head_ld = rob_q.size() > 0 && i_kind[rob_q[0]] == K_LD;
    t_ex_lsu = c_ex;
    t_disp_ld = d_ld;
    t_disp_st = d_st;
    t_disp_br_valid = d_br_valid;
    t_disp_br_tag = d_br_tag;
    t_dc_req_accepted = c_acc;
    t_dc_resp_valid = c_resp_j >= 0;
    t_dc_resp_ack = c_resp_ack;
    t_dc_resp_rdata = c_resp_rdata;
    t_dc_resp_tag = tg;
  endtask

  // ---------------- 出力の確認とモデルの更新 ----------------

  task automatic kill_ins(int id);
    case (i_kind[id])
      K_LD: ldq_owner[i_ldq[id]] = -1;
      K_ST: s_live[i_stq[id]] = 1'b0;
      default: tag_used[i_tag[id]] = 1'b0;
    endcase
    in_use[id] = 1'b0;
    n_kill_ins++;
  endtask

  task automatic advance();
    lsu_tag_t tg;
    int id, idx, ai, p, j;
    bit dkill, tkill, exp_complete, resp_ld_ack;
    word_t exp_value;

    // ---- D$ に出ている要求 ----
    tg = lsu_tag_t'(dc_req_tag_ff);
    if (dc_req_valid_ff && !dc_req_we_ff) begin
      idx = int'(tg.ldq_idx);
      id = ldq_owner[idx];
      if (tg.is_store) err("load の要求なのに tag.is_store = 1");
      if (id < 0) err($sformatf("生きていない load の要求が D$ に出ている（LDQ %0d）", idx));
      else begin
        if (!i_addr_sent[id]) err($sformatf("アドレスが来ていない load の要求が出ている：%s", ins_str(id)));
        else if (dc_req_addr_ff != (i_mmio[id] ? MMIO_RX_ADDR : addr_of(i_ai[id])))
          err($sformatf("load の要求のアドレスが違う：dc_req_addr_ff = %h、%s", dc_req_addr_ff, ins_str(id)));
        if (i_done[id] >= 0) err($sformatf("WB 済みの load の要求が出ている：%s", ins_str(id)));
        if (i_mmio[id] && rob_q[0] != id) err($sformatf("ROB の先頭でない MMIO の load の要求が出ている：%s", ins_str(id)));
        if (c_acc) begin
          for (j = 0; j < p_idx.size(); j++) begin
            if (!p_we[j] && p_idx[j] == idx) err($sformatf("返事がまだの load をもう一度 D$ に出した：%s", ins_str(id)));
          end
          tkill = pos_of(id) >= c_kill_from;
          dkill = (dc_req_brmask_ff & c_u.kill_mask) != '0 || c_flush;
          if (tkill != dkill)
            err($sformatf("load の要求の brmask が合わない：brmask %b、kill_mask %b、kill されるか %0b：%s",
                          dc_req_brmask_ff, c_u.kill_mask, tkill, ins_str(id)));
          if (dkill) n_dc_drop++;
          else begin
            p_we.push_back(1'b0);
            p_mmio.push_back(i_mmio[id]);
            p_ai.push_back(i_ai[id]);
            p_idx.push_back(idx);
            p_cyc.push_back(cyc);
            p_data.push_back(mmio_val(mmio_acc_n));
            p_brmask.push_back(dc_req_brmask_ff & ~c_u.resolve_mask);
            if (i_mmio[id]) mmio_acc_n++;
            n_dc_ld++;
          end
        end
      end
    end
    if (dc_req_valid_ff && dc_req_we_ff && c_acc) begin
      idx = int'(tg.stq_idx);
      ai = ai_of(dc_req_addr_ff);
      if (!tg.is_store) err("store の要求なのに tag.is_store = 0");
      if (dc_req_brmask_ff != '0) err($sformatf("store の要求の brmask = %b、期待値 0", dc_req_brmask_ff));
      if (!s_live[idx] || !s_committed[idx]) err($sformatf("commit していない store の要求が D$ に出た（STQ %0d）", idx));
      else if (ai != s_ai[idx] || dc_req_wdata_ff != s_data[idx])
        err($sformatf("store の要求の中身が違う（STQ %0d）：addr %h data %h、期待値 addr %h data %h", idx, dc_req_addr_ff,
                      dc_req_wdata_ff, addr_of(s_ai[idx]), s_data[idx]));
      for (j = 0; j < p_idx.size(); j++) begin
        if (p_we[j] && p_idx[j] == idx) err($sformatf("返事がまだの store をもう一度 D$ に出した（STQ %0d）", idx));
      end
      if (ai >= 0) begin
        p_we.push_back(1'b1);
        p_mmio.push_back(1'b0);
        p_ai.push_back(ai);
        p_idx.push_back(idx);
        p_cyc.push_back(cyc);
        p_data.push_back(dc_req_wdata_ff);
        p_brmask.push_back('0);
        n_dc_st++;
      end
    end

    // ---- D$ の返事 ----
    resp_ld_ack = 1'b0;
    if (c_resp_j >= 0) begin
      j = c_resp_j;
      if (p_we[j]) begin
        if (c_resp_ack) dc_mem[p_ai[j]] = p_data[j];
        else n_st_nack++;
      end else begin
        resp_ld_ack = c_resp_ack;
        if (!c_resp_ack) n_ld_nack++;
        if ((p_brmask[j] & c_u.kill_mask) != '0 || c_flush) n_resp_killed++;
      end
    end

    // ---- WB ----
    if (wb_mem[0].valid) begin
      id = int'(wb_mem[0].rob_idx);
      if (!in_use[id] || i_kind[id] != K_LD) err($sformatf("生きている load でない rob_idx %0d が WB に出た", id));
      else begin
        if (!i_addr_sent[id]) err($sformatf("アドレスが来ていない load が WB に出た：%s", ins_str(id)));
        if (i_done[id] >= 0) err($sformatf("同じ load が 2 回 WB に出た：%s", ins_str(id)));
        if (wb_mem[0].rd != i_rd[id]) err($sformatf("wb_mem.rd = %h、期待値 %h：%s", wb_mem[0].rd, i_rd[id], ins_str(id)));
        i_done[id] = cyc;
        i_value[id] = wb_mem[0].value;
        if (resp_ld_ack && p_idx[c_resp_j] == i_ldq[id]) begin
          n_wb_dc++;
          if (wb_mem[0].value != c_resp_rdata)
            err($sformatf("D$ の返事の WB の値 %h が rdata %h と違う：%s", wb_mem[0].value, c_resp_rdata, ins_str(id)));
        end else begin
          i_fwd[id] = 1'b1;
          n_wb_fwd++;
          if (i_mmio[id]) err($sformatf("MMIO の load を forward した：%s", ins_str(id)));
          if (dc_req_valid_ff && !dc_req_we_ff) n_both++;
        end
        if (pos_of(id) >= c_kill_from) n_wb_killed++;
        if (cyc - i_disp_cyc[id] > n_ld_wait_max) n_ld_wait_max = cyc - i_disp_cyc[id];
      end
      if (!slow_wakeup_mem.valid || slow_wakeup_mem.preg != wb_mem[0].rd || slow_wakeup_mem.latency != LAT_FAST)
        err($sformatf("slow_wakeup_mem = {%0b, %h, %0d}、期待値 {1, %h, %0d}", slow_wakeup_mem.valid, slow_wakeup_mem.preg,
                      slow_wakeup_mem.latency, wb_mem[0].rd, LAT_FAST));
    end else begin
      if (slow_wakeup_mem.valid) err("WB が無いのに slow_wakeup_mem.valid = 1");
    end

    // ---- AGU と complete_st ----
    exp_complete = 1'b0;
    if (c_ex_id >= 0) begin
      id = c_ex_id;
      if (i_kind[id] == K_LD) begin
        i_addr_sent[id] = 1'b1;
      end else begin
        idx = i_stq[id];
        if (c_ex.addr_valid) i_addr_sent[id] = 1'b1;
        if (c_ex.data_valid) i_data_sent[id] = 1'b1;
        if (i_addr_sent[id] && i_data_sent[id]) begin
          exp_complete = 1'b1;
          i_done[id] = cyc;
          if (complete_st.rob_idx != rob_idx_t'(id))
            err($sformatf("complete_st.rob_idx = %0d、期待値 %0d", complete_st.rob_idx, id));
        end
      end
    end
    if (complete_st.valid != exp_complete)
      err($sformatf("complete_st.valid = %0b、期待値 %0b", complete_st.valid, exp_complete));

    // ---- mispredict / flush で消す ----
    if (c_flush) n_flush++;
    if (c_mis_pos >= 0) n_mispredict++;
    for (int i = 0; i < MAX_BR; i++) begin
      if (c_res_tag[i]) tag_used[i] = 1'b0;
    end
    foreach (rob_q[k]) begin
      id = rob_q[k];
      if (i_kind[id] == K_BR && !i_resolved[id] && c_res_tag[i_tag[id]] && k < c_kill_from) begin
        i_resolved[id] = 1'b1;
        i_done[id] = cyc;
      end
    end
    while (rob_q.size() > c_kill_from) begin
      kill_ins(rob_q[rob_q.size()-1]);
      rob_q.pop_back();
    end
    if (c_flush || c_mis_pos >= 0) last_progress = cyc;
    flush_next = c_viol;

    // ---- commit ----
    for (int i = 0; i < c_n_commit; i++) begin
      id = rob_q.pop_front();
      in_use[id] = 1'b0;
      last_progress = cyc;
      case (i_kind[id])
        K_LD: begin
          ldq_owner[i_ldq[id]] = -1;
          if (i_mmio[id]) begin
            exp_value = mmio_val(mmio_commit_n);
            mmio_commit_n++;
            n_mmio++;
          end else begin
            exp_value = arch_mem[i_ai[id]];
          end
          if (i_value[id] != exp_value)
            err($sformatf("commit した load の値が違う：WB の値 %h、期待値 %h（forward %0b、WB は cycle %0d）：%s", i_value[id],
                          exp_value, i_fwd[id], i_done[id], ins_str(id)));
          n_commit_ld++;
        end
        K_ST: begin
          arch_mem[i_ai[id]] = i_data[id];
          s_committed[i_stq[id]] = 1'b1;
          n_commit_st++;
        end
        default: n_commit_br++;
      endcase
    end

    // ---- dispatch ----
    for (int i = 0; i < DISP_W; i++) begin
      id = c_d_id[i];
      if (id < 0) continue;
      case (c_d_kind[i])
        K_LD: begin
          idx = int'(disp_ldq_idx[i]);
          if (disp_ld_full[i]) err($sformatf("disp_ld_full[%0d] = 1、LDQ には空きがあるはず", i));
          if (ldq_owner[idx] >= 0)
            err($sformatf("disp_ldq_idx[%0d] = %0d は使用中：%s", i, idx, ins_str(ldq_owner[idx])));
          i_ldq[id] = idx;
          ldq_owner[idx] = id;
          n_disp_ld++;
        end
        K_ST: begin
          idx = int'(disp_stq_idx[i]);
          if (disp_st_full[i]) err($sformatf("disp_st_full[%0d] = 1、STQ には空きがあるはず", i));
          i_stq[id] = idx;
          s_live[idx] = 1'b1;
          s_committed[idx] = 1'b0;
          s_ai[idx] = i_ai[id];
          s_data[idx] = i_data[id];
          n_disp_st++;
        end
        default: begin
          tag_used[i_tag[id]] = 1'b1;
          n_disp_br++;
        end
      endcase
      rob_q.push_back(id);
    end

    // ---- D$ の中の要求 ----
    if (c_resp_j >= 0) begin
      j = c_resp_j;
      p_we.delete(j);
      p_mmio.delete(j);
      p_ai.delete(j);
      p_idx.delete(j);
      p_cyc.delete(j);
      p_data.delete(j);
      p_brmask.delete(j);
    end
    for (j = p_we.size() - 1; j >= 0; j--) begin
      if (p_we[j]) continue;
      if ((p_brmask[j] & c_u.kill_mask) != '0 || c_flush) begin
        if (p_mmio[j]) err("accept した MMIO の load が kill された");
        p_we.delete(j);
        p_mmio.delete(j);
        p_ai.delete(j);
        p_idx.delete(j);
        p_cyc.delete(j);
        p_data.delete(j);
        p_brmask.delete(j);
        n_dc_kill++;
      end else begin
        p_brmask[j] = p_brmask[j] & ~c_u.resolve_mask;
      end
    end

    // ---- 詰まっていないか ----
    if (rob_q.size() == 0) last_progress = cyc;
    if (cyc - last_progress > STALL_LIMIT) begin
      err($sformatf("%0d サイクル commit が進まない。先頭：%s", STALL_LIMIT, ins_str(rob_q[0])));
      foreach (rob_q[k]) $display("    %0d: %s", k, ins_str(rob_q[k]));
      $display("    D$ に残っている要求 %0d、dc_req_valid_ff %0b（we %0b）", p_we.size(), dc_req_valid_ff, dc_req_we_ff);
      $display("FAIL（詰まったので打ち切り）");
      $finish;
    end
  endtask

  // ---------------- 本体 ----------------

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 300000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("lsu_top: seed=%0d cycles=%0d", seed, cycles);

    rst = 1'b1;
    t_flush = 1'b0;
    t_br_update_ff = '0;
    t_ex_lsu = '0;
    t_rob_head_ld = 1'b0;
    t_dc_req_accepted = 1'b0;
    t_dc_resp_valid = 1'b0;
    t_dc_resp_ack = 1'b0;
    t_dc_resp_rdata = '0;
    t_dc_resp_tag = '0;
    for (int i = 0; i < DISP_W; i++) begin
      t_disp_ld[i] = '0;
      t_disp_st[i] = '0;
      t_disp_br_valid[i] = 1'b0;
      t_disp_br_tag[i] = '0;
    end
    for (int i = 0; i < COMMIT_W; i++) begin
      t_commit_ld[i] = 1'b0;
      t_commit_st[i] = 1'b0;
    end
    for (int i = 0; i < NID; i++) begin
      in_use[i] = 1'b0;
      i_done[i] = -1;
    end
    for (int i = 0; i < LN; i++) ldq_owner[i] = -1;
    for (int i = 0; i < SN; i++) begin
      s_live[i] = 1'b0;
      s_committed[i] = 1'b0;
    end
    for (int i = 0; i < MAX_BR; i++) tag_used[i] = 1'b0;
    for (int i = 0; i < MEM_N; i++) begin
      arch_mem[i] = 32'h1000_0000 + word_t'(i);
      dc_mem[i] = arch_mem[i];
    end
    flush_next = 1'b0;
    draining = 1'b0;
    next_id = 0;
    cyc = 0;
    last_progress = 0;
    repeat (3) @(negedge clk);
    rst = 1'b0;

    while (cyc < int'(cycles) || rob_q.size() > 0 || p_we.size() > 0 || !stq_empty || flush_next) begin
      @(posedge clk);
      #1;
      if (cyc >= int'(cycles)) draining = 1'b1;
      if (cyc % 1024 == 0) pick_rates();
      decide();
      @(negedge clk);
      #1;
      advance();
      cyc++;
      if (cyc > int'(cycles) + 20000) begin
        err("終わりの掃き出しが終わらない");
        break;
      end
    end

    // 最後に D$ の中身を確かめる
    @(posedge clk);
    #1;
    for (int i = 0; i < MEM_N; i++) begin
      if (dc_mem[i] != arch_mem[i])
        err($sformatf("最後の D$ の中身が違う：mem[%h] = %h、commit 順に書いた値 %h", addr_of(i), dc_mem[i], arch_mem[i]));
    end

    $display("dispatch：load %0d、store %0d、分岐 %0d（LDQ が満杯で待った %0d、STQ が満杯で待った %0d）", n_disp_ld,
             n_disp_st, n_disp_br, n_full_ld, n_full_st);
    $display("commit：load %0d（MMIO %0d）、store %0d、分岐 %0d。mispredict %0d、順序違反の flush %0d、消えた命令 %0d",
             n_commit_ld, n_mmio, n_commit_st, n_commit_br, n_mispredict, n_flush, n_kill_ins);
    $display("WB：D$ の返事 %0d、forward %0d（同じサイクルに D$ にも load の要求が出ていた %0d）、kill と同じサイクル %0d、dispatch から最長 %0d サイクル",
             n_wb_dc, n_wb_fwd, n_both, n_wb_killed, n_ld_wait_max);
    $display("D$：load の accept %0d（accept と同時に kill %0d、後から kill %0d、kill のサイクルに返事 %0d）、nack %0d",
             n_dc_ld, n_dc_drop, n_dc_kill, n_resp_killed, n_ld_nack);
    $display("D$：store の accept %0d、nack %0d、同じアドレスの前の store を待った %0d、空での確認 %0d 回", n_dc_st,
             n_st_nack, n_st_hold, n_empty_check);
    if (errors == 0) $display("PASS");
    else $display("FAIL（%0d 件）", errors);
    $finish;
  end

endmodule

`default_nettype wire
