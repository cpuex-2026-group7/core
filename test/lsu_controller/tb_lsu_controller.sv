`timescale 1ns / 1ps
`default_nettype none

// lsu_controller の単体テストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 300000）
//   +seed=N    乱数の種（既定 1）
//
// controller が持つ状態は dc_req_ff と「次は load の番か」だけなので、LDQ / STQ の見え方は毎サイクルでたらめに作る。
// 次のサイクルの入力を決めておき、negedge で DUT に写して、1ns 待ってから出力をモデルと比べる。
// モデルは load を head からの古い順に並べて選ぶ（RTL のポインタの回し方は使わない）。
//
// テストの前提にしている仕様
//   - 出せる load：valid、addr_valid、ld_requested でない、gone_to_wb でない、このサイクルに kill されない。
//     MMIO は rob_head_ld かつ LDQ の head のときだけ。flush のサイクルは出さない
//   - D$ に出すのは fwd_hit でない load のうち一番古いもの
//   - forward するのは fwd_hit かつ forward 元の data_valid な load のうち一番古いもの（MMIO は fwd_hit にならない）
//     fwd_hit で data がまだの load は飛ばす
//   - dc_req_ff は accept されるまで保持する。load は kill_mask / flush で消し、brmask に resolve を当てる
//     空いた（valid でない、kill された、accept された）サイクルに次を選ぶ
//     load の番か store が無ければ load、そうでなければ store。
//     load を出したら stq_cnt < STQ_SIZE/2 のときだけ次も load の番、store を出したら次は load の番
//   - WB は D$ の返事（load の ack で、stale でも stale_mask でもない）が優先。無ければ forward
//     （stale_mask が立っていたら出さない）。slow_wakeup_mem と ld_gone_to_wb も同時に出す
//   - ld_nack は load の返事が nack か、stale か、stale_mask のとき。store の返事はそのまま st_ack / st_nack
//   - D$ の load の返事は ld_requested なエントリにだけ来る

module tb_lsu_controller
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import ex_types::*;
  import lsu_types::*;
();

  localparam int LN = LDQ_SIZE;
  localparam int SN = STQ_SIZE;
  localparam int MAX_ERRORS = 30;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic                rst;
  logic                flush;
  br_update_t          br_update_ff;
  logic                rob_head_ld;
  ldq_controller_t     ldq            [LN];
  ldq_idx_t            ldq_head_idx;
  ldq_idx_with_valid_t ld_requested;
  ldq_idx_with_valid_t ld_nack;
  ldq_idx_with_valid_t ld_gone_to_wb;
  stq_controller_t     head_store;
  stq_cnt_t            stq_cnt;
  stq_fwd_t            stq_fwd        [SN];
  logic                st_requested;
  stq_idx_with_valid_t st_ack;
  stq_idx_with_valid_t st_nack;
  ldq_mask_t           stale_mask;
  lsu_wb_t             wb_mem;
  wakeup_t             slow_wakeup_mem;
  dc_req_t             dc_req_ff;
  logic                dc_accepted;
  dc_resp_t            dc_resp;

  lsu_controller dut (.*);

  // initial の中から DUT の入力を直接書くと Verilator 5.020 の --timing で
  // DUT の組合せ回路が評価し直されないことがあるので、立ち下がりで写す
  logic            t_flush;
  br_update_t      t_br_update_ff;
  logic            t_rob_head_ld;
  ldq_controller_t t_ldq         [LN];
  ldq_idx_t        t_ldq_head_idx;
  stq_controller_t t_head_store;
  stq_cnt_t        t_stq_cnt;
  stq_fwd_t        t_stq_fwd     [SN];
  ldq_mask_t       t_stale_mask;
  logic            t_dc_accepted;
  dc_resp_t        t_dc_resp;

  always @(negedge clk) begin
    flush <= t_flush;
    br_update_ff <= t_br_update_ff;
    rob_head_ld <= t_rob_head_ld;
    ldq <= t_ldq;
    ldq_head_idx <= t_ldq_head_idx;
    head_store <= t_head_store;
    stq_cnt <= t_stq_cnt;
    stq_fwd <= t_stq_fwd;
    stale_mask <= t_stale_mask;
    dc_accepted <= t_dc_accepted;
    dc_resp <= t_dc_resp;
  end

  // ---------------- 乱数 ----------------

  function automatic int rnd(int n);
    return int'($urandom_range(n - 1, 0));
  endfunction

  // 立っているビットが少ない mask
  function automatic brmask_t rnd_brmask(int rate);
    brmask_t m;
    m = '0;
    for (int i = 0; i < MAX_BR; i++) begin
      if (rnd(100) < rate) m[i] = 1'b1;
    end
    return m;
  endfunction

  // ---------------- モデル（FF の中身） ----------------

  bit       m_valid, m_we;
  addr_t    m_addr;
  word_t    m_wdata;
  lsu_tag_t m_tag;
  brmask_t  m_brmask;
  bit       m_load_turn;

  // ---------------- 入力の出し方 ----------------

  int ready_rate, fwd_rate, data_rate, store_rate, accept_rate, resp_rate, kill_rate, stale_rate, mmio_rate;

  task automatic pick_rates();
    ready_rate = rnd(3) == 0 ? 15 : 60;
    fwd_rate = rnd(3) == 0 ? 90 : 40;
    data_rate = rnd(3) == 0 ? 10 : 70;
    store_rate = rnd(3) == 0 ? 95 : 40;
    accept_rate = rnd(3) == 0 ? 20 : 80;
    resp_rate = rnd(2) == 0 ? 20 : 70;
    kill_rate = rnd(2) == 0 ? 2 : 10;
    stale_rate = rnd(2) == 0 ? 2 : 15;
    mmio_rate = rnd(2) == 0 ? 5 : 30;
  endtask

  // ---------------- 集計 ----------------

  int unsigned cycles;
  int unsigned seed;
  int unsigned cyc;
  int errors;

  int n_ld_req, n_st_req, n_hold, n_kill_req, n_flush_req, n_accept;
  int n_wb_resp, n_wb_fwd, n_fwd_lost_resp, n_fwd_lost_stale, n_resp_stale, n_nack, n_both, n_skip_wait, n_mmio_req;
  int n_turn_store;

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
    ldq_controller_t l[LN];
    stq_fwd_t f[SN];
    stq_controller_t hs;
    br_update_t u;
    dc_resp_t rsp;
    ldq_mask_t sm;
    bit do_flush, head_ld, acc;
    int head, cnt, idx, ri;
    int dc_cand, fw_cand;
    bit ready, waiting_older;
    bit after_kill, free_slot, exp_ld_req, exp_st_req;
    bit exp_ld_nack, exp_st_ack, exp_st_nack, exp_wb, exp_wb_fwd, resp_ok;
    preg_t exp_rd;
    word_t exp_value;
    rob_idx_t exp_rob;
    int exp_gone_idx;
    bit n_valid, n_we, n_turn;
    addr_t n_addr;
    word_t n_wdata;
    lsu_tag_t n_tag;
    brmask_t n_brmask;

    // ---- 入力 ----
    do_flush = rnd(40) == 0;
    u = '0;
    u.pc = pc_t'($urandom());
    u.target = pc_t'($urandom());
    u.rob_idx = rob_idx_t'($urandom());
    u.tag = br_tag_t'($urandom());
    u.kill_mask = rnd_brmask(kill_rate);
    u.resolve_mask = rnd_brmask(10) & ~u.kill_mask;
    u.mispredict = |u.kill_mask;
    head_ld = rnd(2) == 1;
    head = rnd(LN);
    cnt = rnd(SN + 1);

    for (int i = 0; i < LN; i++) begin
      l[i] = '0;
      l[i].valid = rnd(8) != 0;
      l[i].addr_valid = rnd(100) < ready_rate + 30;
      l[i].addr = $urandom();
      l[i].mmio = rnd(100) < mmio_rate;
      case (rnd(100) < ready_rate ? 0 : 1 + rnd(2))
        0: ;
        1: begin
          l[i].ld_requested = 1'b1;
          l[i].stale = rnd(4) == 0;
        end
        default: l[i].gone_to_wb = 1'b1;
      endcase
      l[i].fwd_hit = !l[i].mmio && rnd(100) < fwd_rate;
      l[i].fwd_stq_idx = stq_idx_t'($urandom());
      l[i].rd.typ = preg_type_t'(rnd(3));
      l[i].rd.idx = preg_idx_t'($urandom());
      l[i].rob_idx = rob_idx_t'($urandom());
      l[i].brmask = rnd_brmask(8);
    end
    for (int i = 0; i < SN; i++) begin
      f[i].data_valid = rnd(100) < data_rate;
      f[i].data = $urandom();
    end
    hs.valid = rnd(100) < store_rate;
    hs.stq_idx = stq_idx_t'($urandom());
    hs.addr = $urandom();
    hs.data = $urandom();
    sm = '0;
    for (int i = 0; i < LN; i++) begin
      if (rnd(100) < stale_rate) sm[i] = 1'b1;
    end

    rsp = '0;
    rsp.tag = lsu_tag_t'($urandom());
    rsp.ack = rnd(4) != 0;
    rsp.rdata = $urandom();
    if (rnd(100) < resp_rate) begin
      rsp.valid = 1'b1;
      if (!rsp.tag.is_store) begin
        // load の返事は出してあるエントリに来る
        ri = int'(rsp.tag.ldq_idx);
        l[ri].valid = 1'b1;
        l[ri].addr_valid = 1'b1;
        l[ri].ld_requested = 1'b1;
        l[ri].gone_to_wb = 1'b0;
        l[ri].stale = rnd(4) == 0;
      end
    end
    acc = m_valid && rnd(100) < accept_rate;

    t_flush = do_flush;
    t_br_update_ff = u;
    t_rob_head_ld = head_ld;
    t_ldq = l;
    t_ldq_head_idx = ldq_idx_t'(head);
    t_head_store = hs;
    t_stq_cnt = stq_cnt_t'(cnt);
    t_stq_fwd = f;
    t_stale_mask = sm;
    t_dc_accepted = acc;
    t_dc_resp = rsp;

    @(negedge clk);
    #1;

    // ---- FF の出力 ----
    if (dc_req_ff.valid != m_valid) err($sformatf("dc_req_ff.valid = %0b、期待値 %0b", dc_req_ff.valid, m_valid));
    else if (m_valid) begin
      if (dc_req_ff.we != m_we) err($sformatf("dc_req_ff.we = %0b、期待値 %0b", dc_req_ff.we, m_we));
      if (dc_req_ff.tag.is_store != m_we)
        err($sformatf("dc_req_ff.tag.is_store = %0b、期待値 %0b", dc_req_ff.tag.is_store, m_we));
      if (dc_req_ff.addr != m_addr) err($sformatf("dc_req_ff.addr = %h、期待値 %h", dc_req_ff.addr, m_addr));
      if (dc_req_ff.brmask != m_brmask)
        err($sformatf("dc_req_ff.brmask = %b、期待値 %b", dc_req_ff.brmask, m_brmask));
      if (m_we) begin
        if (dc_req_ff.wdata != m_wdata) err($sformatf("dc_req_ff.wdata = %h、期待値 %h", dc_req_ff.wdata, m_wdata));
        if (dc_req_ff.tag.stq_idx != m_tag.stq_idx)
          err($sformatf("dc_req_ff.tag.stq_idx = %0d、期待値 %0d", dc_req_ff.tag.stq_idx, m_tag.stq_idx));
      end else begin
        if (dc_req_ff.tag.ldq_idx != m_tag.ldq_idx)
          err($sformatf("dc_req_ff.tag.ldq_idx = %0d、期待値 %0d", dc_req_ff.tag.ldq_idx, m_tag.ldq_idx));
      end
    end

    // ---- 返事 ----
    exp_st_ack = rsp.valid && rsp.tag.is_store && rsp.ack;
    exp_st_nack = rsp.valid && rsp.tag.is_store && !rsp.ack;
    ri = int'(rsp.tag.ldq_idx);
    resp_ok = rsp.valid && !rsp.tag.is_store && rsp.ack && !l[ri].stale && !sm[ri];
    exp_ld_nack = rsp.valid && !rsp.tag.is_store && !resp_ok;
    if (st_ack.valid != exp_st_ack) err($sformatf("st_ack.valid = %0b、期待値 %0b", st_ack.valid, exp_st_ack));
    else if (exp_st_ack && st_ack.stq_idx != rsp.tag.stq_idx)
      err($sformatf("st_ack.stq_idx = %0d、期待値 %0d", st_ack.stq_idx, rsp.tag.stq_idx));
    if (st_nack.valid != exp_st_nack) err($sformatf("st_nack.valid = %0b、期待値 %0b", st_nack.valid, exp_st_nack));
    else if (exp_st_nack && st_nack.stq_idx != rsp.tag.stq_idx)
      err($sformatf("st_nack.stq_idx = %0d、期待値 %0d", st_nack.stq_idx, rsp.tag.stq_idx));
    if (ld_nack.valid != exp_ld_nack)
      err($sformatf("ld_nack.valid = %0b、期待値 %0b（ack %0b stale %0b stale_mask %0b）", ld_nack.valid, exp_ld_nack,
                    rsp.ack, l[ri].stale, sm[ri]));
    else if (exp_ld_nack && int'(ld_nack.ldq_idx) != ri)
      err($sformatf("ld_nack.ldq_idx = %0d、期待値 %0d", ld_nack.ldq_idx, ri));
    if (exp_ld_nack) begin
      n_nack++;
      if (rsp.ack) n_resp_stale++;
    end

    // ---- load を古い順に見て選ぶ ----
    dc_cand = -1;
    fw_cand = -1;
    waiting_older = 1'b0;
    for (int k = 0; k < LN; k++) begin
      idx = (head + k) % LN;
      ready = l[idx].valid && l[idx].addr_valid && !l[idx].ld_requested && !l[idx].gone_to_wb
          && (l[idx].brmask & u.kill_mask) == '0 && !do_flush;
      if (l[idx].mmio && !(head_ld && k == 0)) ready = 1'b0;
      if (!ready) continue;
      if (!l[idx].fwd_hit) begin
        if (dc_cand < 0) begin
          dc_cand = idx;
          if (waiting_older) n_skip_wait++;
        end
      end else if (f[l[idx].fwd_stq_idx].data_valid) begin
        if (fw_cand < 0) fw_cand = idx;
      end else begin
        if (dc_cand < 0) waiting_older = 1'b1;
      end
    end

    // ---- D$ への要求 ----
    after_kill = m_valid && (m_brmask & u.kill_mask) == '0 && !(do_flush && !m_we);
    free_slot = !after_kill || acc;
    exp_ld_req = 1'b0;
    exp_st_req = 1'b0;
    n_valid = m_valid;
    n_we = m_we;
    n_addr = m_addr;
    n_wdata = m_wdata;
    n_tag = m_tag;
    n_brmask = m_brmask & ~u.resolve_mask;
    n_turn = m_load_turn;
    if (m_valid && !after_kill) begin
      if (do_flush && !m_we) n_flush_req++;
      else n_kill_req++;
    end
    if (acc) n_accept++;
    if (free_slot) begin
      n_valid = 1'b0;
      if (dc_cand >= 0 && (m_load_turn || !hs.valid)) begin
        exp_ld_req = 1'b1;
        n_valid = 1'b1;
        n_we = 1'b0;
        n_addr = l[dc_cand].addr;
        n_tag = '0;
        n_tag.ldq_idx = ldq_idx_t'(dc_cand);
        n_brmask = l[dc_cand].brmask & ~u.resolve_mask;
        n_turn = cnt < SN / 2;
        n_ld_req++;
        if (l[dc_cand].mmio) n_mmio_req++;
      end else if (hs.valid) begin
        exp_st_req = 1'b1;
        n_valid = 1'b1;
        n_we = 1'b1;
        n_addr = hs.addr;
        n_wdata = hs.data;
        n_tag = '0;
        n_tag.is_store = 1'b1;
        n_tag.stq_idx = hs.stq_idx;
        n_brmask = '0;
        n_turn = 1'b1;
        n_st_req++;
        if (dc_cand >= 0) n_turn_store++;
      end
    end else begin
      n_hold++;
    end
    if (ld_requested.valid != exp_ld_req)
      err($sformatf("ld_requested.valid = %0b、期待値 %0b（空き %0b、load の候補 %0d、load の番 %0b、store %0b）",
                    ld_requested.valid, exp_ld_req, free_slot, dc_cand, m_load_turn, hs.valid));
    else if (exp_ld_req && int'(ld_requested.ldq_idx) != dc_cand)
      err($sformatf("ld_requested.ldq_idx = %0d、期待値 %0d（head %0d）", ld_requested.ldq_idx, dc_cand, head));
    if (st_requested != exp_st_req)
      err($sformatf("st_requested = %0b、期待値 %0b（空き %0b、load の候補 %0d、load の番 %0b、store %0b）", st_requested,
                    exp_st_req, free_slot, dc_cand, m_load_turn, hs.valid));

    // ---- WB ----
    exp_wb = 1'b0;
    exp_wb_fwd = 1'b0;
    exp_rd = '0;
    exp_value = '0;
    exp_rob = '0;
    exp_gone_idx = 0;
    if (resp_ok) begin
      exp_wb = 1'b1;
      exp_rd = l[ri].rd;
      exp_value = rsp.rdata;
      exp_rob = l[ri].rob_idx;
      exp_gone_idx = ri;
      n_wb_resp++;
      if (fw_cand >= 0) n_fwd_lost_resp++;
    end else if (fw_cand >= 0) begin
      if (sm[fw_cand]) n_fwd_lost_stale++;
      else begin
        exp_wb = 1'b1;
        exp_wb_fwd = 1'b1;
        exp_rd = l[fw_cand].rd;
        exp_value = f[l[fw_cand].fwd_stq_idx].data;
        exp_rob = l[fw_cand].rob_idx;
        exp_gone_idx = fw_cand;
        n_wb_fwd++;
      end
    end
    if (exp_wb_fwd && exp_ld_req) n_both++;
    if (wb_mem.valid != exp_wb)
      err($sformatf("wb_mem.valid = %0b、期待値 %0b（返事 %0b、forward の候補 %0d）", wb_mem.valid, exp_wb, resp_ok,
                    fw_cand));
    else if (exp_wb) begin
      if (wb_mem.rd != exp_rd) err($sformatf("wb_mem.rd = %h、期待値 %h", wb_mem.rd, exp_rd));
      if (wb_mem.value != exp_value)
        err($sformatf("wb_mem.value = %h、期待値 %h（forward %0b）", wb_mem.value, exp_value, exp_wb_fwd));
      if (wb_mem.rob_idx != exp_rob) err($sformatf("wb_mem.rob_idx = %h、期待値 %h", wb_mem.rob_idx, exp_rob));
      if (slow_wakeup_mem.preg != exp_rd)
        err($sformatf("slow_wakeup_mem.preg = %h、期待値 %h", slow_wakeup_mem.preg, exp_rd));
      if (slow_wakeup_mem.latency != LAT_FAST)
        err($sformatf("slow_wakeup_mem.latency = %0d、期待値 %0d", slow_wakeup_mem.latency, LAT_FAST));
      if (int'(ld_gone_to_wb.ldq_idx) != exp_gone_idx)
        err($sformatf("ld_gone_to_wb.ldq_idx = %0d、期待値 %0d（forward %0b）", ld_gone_to_wb.ldq_idx, exp_gone_idx,
                      exp_wb_fwd));
    end
    if (slow_wakeup_mem.valid != exp_wb)
      err($sformatf("slow_wakeup_mem.valid = %0b、期待値 %0b", slow_wakeup_mem.valid, exp_wb));
    if (ld_gone_to_wb.valid != exp_wb)
      err($sformatf("ld_gone_to_wb.valid = %0b、期待値 %0b", ld_gone_to_wb.valid, exp_wb));

    // ---- モデルを進める ----
    m_valid = n_valid;
    m_we = n_we;
    m_addr = n_addr;
    m_wdata = n_wdata;
    m_tag = n_tag;
    m_brmask = n_brmask;
    m_load_turn = n_turn;
  endtask

  // ---------------- 本体 ----------------

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 300000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("lsu_controller: seed=%0d cycles=%0d", seed, cycles);

    rst = 1'b1;
    t_flush = 1'b0;
    t_br_update_ff = '0;
    t_rob_head_ld = 1'b0;
    for (int i = 0; i < LN; i++) t_ldq[i] = '0;
    t_ldq_head_idx = '0;
    t_head_store = '0;
    t_stq_cnt = '0;
    for (int i = 0; i < SN; i++) t_stq_fwd[i] = '0;
    t_stale_mask = '0;
    t_dc_accepted = 1'b0;
    t_dc_resp = '0;
    m_valid = 1'b0;
    m_we = 1'b0;
    m_addr = '0;
    m_wdata = '0;
    m_tag = '0;
    m_brmask = '0;
    m_load_turn = 1'b1;
    repeat (3) @(negedge clk);
    rst = 1'b0;
    // 入力を写す always より後に次の入力を決める
    #1;

    for (cyc = 0; cyc < cycles; cyc++) begin
      if (cyc % 512 == 0) pick_rates();
      one_cycle();
    end

    $display("D$ への要求：load %0d（MMIO %0d、forward 待ちの古い load を飛ばした %0d）、store %0d（load を待たせた %0d）",
             n_ld_req, n_mmio_req, n_skip_wait, n_st_req, n_turn_store);
    $display("accept %0d、accept 待ちで保持 %0d、kill_mask で消えた要求 %0d、flush で消えた load の要求 %0d", n_accept,
             n_hold, n_kill_req, n_flush_req);
    $display("WB：D$ の返事 %0d、forward %0d（同じサイクルに別の load を D$ にも出した %0d）", n_wb_resp, n_wb_fwd,
             n_both);
    $display("forward を見送った：返事と重なった %0d、stale_mask %0d。ld_nack %0d（ack だが stale %0d）",
             n_fwd_lost_resp, n_fwd_lost_stale, n_nack, n_resp_stale);
    if (errors == 0) $display("PASS");
    else $display("FAIL（%0d 件）", errors);
    $finish;
  end

endmodule

`default_nettype wire
