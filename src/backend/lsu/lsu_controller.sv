`timescale 1ns / 1ps
`default_nettype none

module lsu_controller
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import ex_types::*;
  import lsu_types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // EXから
  input wire br_update_t br_update_ff,

  // LDQ
  input wire ldq_controller_t ldq[LDQ_SIZE],
  input wire ldq_idx_t ldq_head_idx,  // loadの先頭
  output ldq_idx_with_valid_t ld_requested,
  output ldq_idx_with_valid_t ld_nack,
  output ldq_idx_with_valid_t ld_gone_to_wb,

  // STQ
  input wire stq_controller_t head_store,  // 次にD$に送るstore
  input wire stq_cnt_t stq_cnt,  // STQの中身の数
  input wire stq_fwd_t stq_fwd[STQ_SIZE],  // forwardするデータ
  output logic st_requested,
  output stq_idx_with_valid_t st_ack,
  output stq_idx_with_valid_t st_nack,

  // RFへ
  output lsu_wb_t wb_mem,

  // IQへ
  output wakeup_t slow_wakeup_mem,

  // D$
  // ここ3つはFF
  output dc_req_t dc_req_ff,  // acceptされるまで保持。毎サイクルbr_update_ffを当てる
  input wire logic dc_accepted,
  input wire dc_resp_t dc_resp
);

  // 今のところはコア側がrespのkillを担当する。
  // acceptと同じサイクルにkillしたloadのrespは捨てる
  logic resp_killed_ff;
  logic resp_valid;
  assign resp_valid = dc_resp.valid && !(resp_killed_ff && !dc_resp.tag.is_store);

  // ack,nackをつなぐ
  always_comb begin
    st_ack  = '0;
    st_nack = '0;
    ld_nack = '0;
    if (resp_valid) begin
      if (dc_resp.tag.is_store) begin
        st_ack.valid = dc_resp.ack;
        st_ack.stq_idx = dc_resp.tag.stq_idx;
        st_nack.valid = !dc_resp.ack;
        st_nack.stq_idx = dc_resp.tag.stq_idx;
      end else begin
        ld_nack.valid   = !dc_resp.ack || ldq[dc_resp.tag.ldq_idx].stale;
        ld_nack.ldq_idx = dc_resp.tag.ldq_idx;
      end
    end
  end

  // storeからのreq
  dc_req_t store_req;
  always_comb begin
    store_req = '0;
    if (head_store.valid) begin
      store_req.valid = 1'b1;
      store_req.we = 1'b1;
      store_req.addr = head_store.addr;
      store_req.wdata = head_store.data;
      store_req.tag.is_store = 1'b1;
      store_req.tag.stq_idx = head_store.stq_idx;
    end
  end

  // loadからのreq
  dc_req_t ld_req;
  always_comb begin
    ldq_mask_t ld_cand, ld_cand_half, ld_grant;
    ld_req = '0;
    for (int i = 0; i < LDQ_SIZE; i++) begin
      // forward待ちはD$にreqしない
      // flushのときはloadは消す
      ld_cand[i] = ldq[i].valid && ldq[i].addr_valid && !ldq[i].ld_requested && !ldq[i].gone_to_wb &&
        !ldq[i].fwd_hit && !br_kill_check(ldq[i].brmask, br_update_ff) && !flush;
      ld_cand_half[i] = ld_cand[i] && ldq_idx_t'(i) >= ldq_head_idx;
    end

    // 条件満たす一番古いものをgrant
    if (|ld_cand_half) begin
      ld_grant = ld_cand_half & -ld_cand_half;
    end else begin
      ld_grant = ld_cand & -ld_cand;
    end

    for (int i = 0; i < LDQ_SIZE; i++) begin
      if (ld_grant[i]) begin
        ld_req.valid |= 1'b1;
        ld_req.addr |= ldq[i].addr;
        ld_req.tag.ldq_idx |= ldq_idx_t'(i);
        ld_req.brmask |= ldq[i].brmask;
      end
    end
    ld_req.brmask = apply_br_resolve(ld_req.brmask, br_update_ff);
  end

  // fwdのreq
  fwd_cand_t fwd_req;
  always_comb begin
    ldq_mask_t fwd_cand, fwd_cand_half, fwd_grant;
    fwd_req = '0;
    for (int i = 0; i < LDQ_SIZE; i++) begin
      // 今のサイクルのkillとflush当てる
      fwd_cand[i] = ldq[i].fwd_ready && !br_kill_check(ldq[i].brmask, br_update_ff) && !flush;
      fwd_cand_half[i] = fwd_cand[i] && ldq_idx_t'(i) >= ldq_head_idx;
    end

    // 条件満たす一番古いものをgrant
    if (|fwd_cand_half) begin
      fwd_grant = fwd_cand_half & -fwd_cand_half;
    end else begin
      fwd_grant = fwd_cand & -fwd_cand;
    end

    for (int i = 0; i < LDQ_SIZE; i++) begin
      if (fwd_grant[i]) begin
        fwd_req.valid |= 1'b1;
        fwd_req.ldq_idx |= ldq_idx_t'(i);
        fwd_req.stq_idx |= ldq[i].fwd_stq_idx;
      end
    end
  end

  logic load_turn_ff;

  dc_req_t n_dc_req_ff;
  logic n_load_turn_ff;

  always_comb begin
    n_dc_req_ff = dc_req_ff;
    n_load_turn_ff = load_turn_ff;
    ld_requested = '0;
    st_requested = 1'b0;

    // loadはbr_killやflushでkill
    if (br_kill_check(dc_req_ff.brmask, br_update_ff) || (flush && !dc_req_ff.we)) begin
      n_dc_req_ff.valid = 1'b0;
    end
    n_dc_req_ff.brmask = apply_br_resolve(dc_req_ff.brmask, br_update_ff);

    if (!n_dc_req_ff.valid || dc_accepted) begin
      n_dc_req_ff.valid = 1'b0;
      if (ld_req.valid && (load_turn_ff || !store_req.valid)) begin
        // loadをreq
        n_dc_req_ff = ld_req;
        ld_requested.valid = 1'b1;
        ld_requested.ldq_idx = ld_req.tag.ldq_idx;
        // storeが詰まりそうでなければ次もload
        n_load_turn_ff = stq_cnt < stq_cnt_t'(STQ_SIZE >> 1);
      end else if (store_req.valid) begin
        // storeをreq
        n_dc_req_ff = store_req;
        st_requested = 1'b1;
        // 次はload
        n_load_turn_ff = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    dc_req_ff <= n_dc_req_ff;
    if (rst) begin
      dc_req_ff.valid <= 1'b0;
      load_turn_ff <= 1'b1;
      resp_killed_ff <= 1'b0;
    end else begin
      load_turn_ff   <= n_load_turn_ff;
      // 一旦コアがkillを担当
      resp_killed_ff <= dc_accepted && !dc_req_ff.we && (br_kill_check(dc_req_ff.brmask, br_update_ff) || flush);
    end
  end

  // WBへ
  ldq_idx_t resp_ldq_idx;
  assign resp_ldq_idx = dc_resp.tag.ldq_idx;

  logic forwarded;
  always_comb begin
    forwarded = 1'b0;
    wb_mem = '0;
    if (resp_valid && !dc_resp.tag.is_store && dc_resp.ack && !ldq[resp_ldq_idx].stale) begin
      // loadをWBへ送る
      wb_mem.valid = 1'b1;
      wb_mem.rd = ldq[resp_ldq_idx].rd;
      wb_mem.value = dc_resp.rdata;
      wb_mem.rob_idx = ldq[resp_ldq_idx].rob_idx;
    end else if (fwd_req.valid) begin
      // 空いていればforward
      wb_mem.valid = 1'b1;
      wb_mem.rd = ldq[fwd_req.ldq_idx].rd;
      wb_mem.value = stq_fwd[fwd_req.stq_idx].data;
      wb_mem.rob_idx = ldq[fwd_req.ldq_idx].rob_idx;
      forwarded = 1'b1;
    end
  end

  assign slow_wakeup_mem = wakeup_t'{valid: wb_mem.valid, preg: wb_mem.rd, latency: LAT_FAST};

  // LDQへ報告
  always_comb begin
    ld_gone_to_wb = '0;
    ld_gone_to_wb.valid = wb_mem.valid;
    ld_gone_to_wb.ldq_idx = forwarded ? fwd_req.ldq_idx : resp_ldq_idx;
  end

endmodule

`default_nettype wire
