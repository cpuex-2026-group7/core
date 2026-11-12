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

  // ROBから
  input wire logic rob_head_ld,

  // LDQ
  input wire ldq_controller_t ldq[LDQ_SIZE],
  input wire ldq_idx_t ldq_head_idx,  // loadの先頭(MMIO用)
  output ldq_idx_with_valid_t ld_requested,
  output ldq_idx_with_valid_t ld_nack,
  output ldq_idx_with_valid_t ld_gone_to_wb,

  // STQ
  input wire stq_controller_t head_store,  // 次にD$に送るstore
  input wire stq_cnt_t stq_cnt,  // STQの中身の数
  input wire stq_forward_t stq_forward[STQ_SIZE],  // forwardするデータ
  output logic st_requested,
  output stq_idx_with_valid_t st_ack,
  output stq_idx_with_valid_t st_nack,

  // searcher
  input wire ldq_mask_t stale_mask,  // WBに出すloadが当たっていたら出さない

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

  // ack,nackをつなぐ
  always_comb begin
    st_ack  = '0;
    st_nack = '0;
    ld_nack = '0;
    if (dc_resp.valid) begin
      if (dc_resp.tag.is_store) begin
        st_ack.valid = dc_resp.ack;
        st_ack.stq_idx = dc_resp.tag.stq_idx;
        st_nack.valid = !dc_resp.ack;
        st_nack.stq_idx = dc_resp.tag.stq_idx;
      end else begin
        ld_nack.valid   = !dc_resp.ack || ldq[dc_resp.tag.ldq_idx].stale || stale_mask[dc_resp.tag.ldq_idx];
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
  dc_req_t load_req;
  always_comb begin
    ldq_ptr_t p;
    logic     ld_ready;
    load_req = '0;
    p.wrap = 1'b0;
    p.ldq_idx = ldq_head_idx;
    for (int i = 0; i < LDQ_SIZE; i++) begin
      p = ldq_ptr_dec(p);
      ld_ready = ldq[p.ldq_idx].valid && ldq[p.ldq_idx].addr_valid && !ldq[p.ldq_idx].ld_requested
          && !ldq[p.ldq_idx].gone_to_wb && !br_kill_check(ldq[p.ldq_idx].brmask, br_update_ff);
      // MMIOはROBの先頭のみ
      if (ldq[p.ldq_idx].mmio && !(rob_head_ld && p.ldq_idx == ldq_head_idx)) begin
        ld_ready = 1'b0;
      end
      // flushのときはloadは消す
      if (ld_ready && !flush) begin
        load_req.valid = 1'b1;
        load_req.addr = ldq[p.ldq_idx].addr;
        load_req.tag.ldq_idx = p.ldq_idx;
        load_req.brmask = apply_br_resolve(ldq[p.ldq_idx].brmask, br_update_ff);
      end
    end
  end

  // とりあえずload_reqでfowardしとく
  always_comb begin
    forward_ldq_idx = '0;
    if (load_req.valid) begin
      forward_ldq_idx = load_req.tag.ldq_idx;
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
      if (load_req.valid && !forward_result.hit && (load_turn_ff || !store_req.valid)) begin
        // loadをreq
        n_dc_req_ff = load_req;
        ld_requested.valid = 1'b1;
        ld_requested.ldq_idx = load_req.tag.ldq_idx;
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
    if (rst) begin
      dc_req_ff <= '0;
      load_turn_ff <= 1'b1;
    end else begin
      dc_req_ff <= n_dc_req_ff;
      load_turn_ff <= n_load_turn_ff;
    end
  end

  // WBへ
  ldq_idx_t resp_ldq_idx;
  assign resp_ldq_idx = dc_resp.tag.ldq_idx;

  logic forwarded;
  always_comb begin
    forwarded = 1'b0;
    wb_mem = '0;
    if (dc_resp.valid && !dc_resp.tag.is_store && dc_resp.ack && !ldq[resp_ldq_idx].stale && !stale_mask[resp_ldq_idx]) begin
      // loadをWBへ送る
      wb_mem.valid = 1'b1;
      wb_mem.rd = ldq[resp_ldq_idx].rd;
      wb_mem.value = dc_resp.rdata;
      wb_mem.rob_idx = ldq[resp_ldq_idx].rob_idx;
    end else if (load_req.valid && forward_result.hit && forward_result.data_valid && !stale_mask[forward_ldq_idx]) begin
      // 空いていればforward
      wb_mem.valid = 1'b1;
      wb_mem.rd = ldq[forward_ldq_idx].rd;
      wb_mem.value = forward_result.data;
      wb_mem.rob_idx = ldq[forward_ldq_idx].rob_idx;
      forwarded = 1'b1;
    end
  end

  assign slow_wakeup_mem = wakeup_t'{valid: wb_mem.valid, preg: wb_mem.rd, latency: LAT_FAST};

  // LDQへ報告
  always_comb begin
    ld_gone_to_wb = '0;
    ld_gone_to_wb.valid = wb_mem.valid;
    ld_gone_to_wb.ldq_idx = forwarded ? forward_ldq_idx : resp_ldq_idx;
    ld_gone_to_wb.forwarded = forwarded;
    ld_gone_to_wb.forward_stq_idx = forward_result.stq_idx;
  end

endmodule

`default_nettype wire
