`timescale 1ns / 1ps
`default_nettype none

module lsu_searcher
  import types::*;
  import ooo_types::*;
  import ex_types::*;
  import lsu_types::*;
(
  // forward元とload違反を探す

  // LDQ
  input wire ldq_searcher_t ldq[LDQ_SIZE],
  output ldq_mask_t violation_mask,  // WBに出た後のloadが違反
  output ldq_mask_t stale_mask,  // WBに出る前のloadが違反
  output nload_fwd_src_t nload_fwd_src,  // AGUに来たloadのforward元

  // STQから
  input wire stq_searcher_t stq[STQ_SIZE],

  // AGUから
  input wire ex_lsu_t ex_lsu

);

  // 最上位の1を取り出す
  function automatic stq_mask_t msb_one(input stq_mask_t x);
    stq_mask_t r;
    for (int i = 0; i < STQ_SIZE; i++) r[i] = x[STQ_SIZE-1-i];  //反転させる
    r = r & -r;
    for (int i = 0; i < STQ_SIZE; i++) msb_one[i] = r[STQ_SIZE-1-i];
  endfunction

  logic ex_st_addr_valid;
  assign ex_st_addr_valid = ex_lsu.is_store && ex_lsu.addr_valid;

  // loadのtail基準のofs
  function automatic stq_cnt_t ofs_from_tail(input stq_idx_t tail, input stq_idx_t st);
    stq_ptr_t from;
    from.wrap = 1'b0;
    from.stq_idx = tail;
    ofs_from_tail = stq_ptr_ofs(st, from);
  endfunction

  // violation,stale
  // AGUに来たstoreより新しくて同じアドレスのload
  always_comb begin
    violation_mask = '0;
    stale_mask = '0;
    if (ex_st_addr_valid) begin
      for (int i = 0; i < LDQ_SIZE; i++) begin
        // 依存したstoreのアドレスが来た?
        if (ldq[i].valid && ldq [i].addr_valid && ldq[i].addr == ex_lsu.addr && ldq[i].older_st_mask[ex_lsu.stq_idx]) begin
          if (ldq[i].gone_to_wb) begin
            // もっと新しいstoreからforwardしている場合以外違反
            violation_mask[i] = !(ldq[i].fwd_hit && ofs_from_tail(ldq[i].tail_stq_idx, ldq[i].fwd_stq_idx) >
                                  ofs_from_tail(ldq[i].tail_stq_idx, ex_lsu.stq_idx));
            stale_mask[i] = 1'b0;
          end else begin
            violation_mask[i] = 1'b0;
            // もっと新しいstoreがforward元の場合以外stale
            stale_mask[i] = !(ldq[i].fwd_hit && ofs_from_tail(ldq[i].tail_stq_idx, ldq[i].fwd_stq_idx) >
                              ofs_from_tail(ldq[i].tail_stq_idx, ex_lsu.stq_idx));
          end
        end
      end
    end
  end

  // loadのアドレスが来た時、
  // loadより古いstoreのうち一番新しいものをfoward元とする
  always_comb begin
    stq_mask_t src_cand, src_cand_half, src_grant;
    nload_fwd_src = '0;
    src_grant = '0;
    for (int i = 0; i < STQ_SIZE; i++) begin
      src_cand[i] = !ex_lsu.is_store && ex_lsu.addr_valid && ldq[ex_lsu.ldq_idx].older_st_mask[i] &&
                    stq[i].addr_valid && stq[i].addr == ex_lsu.addr;
      src_cand_half[i] = src_cand[i] && stq_idx_t'(i) < ldq[ex_lsu.ldq_idx].tail_stq_idx;
    end

    // 条件満たす一番新しいものをgrant
    if (|src_cand_half) begin
      src_grant = msb_one(src_cand_half);
    end else begin
      src_grant = msb_one(src_cand);
    end

    for (int i = 0; i < STQ_SIZE; i++) begin
      if (src_grant[i]) begin
        nload_fwd_src.hit = 1'b1;
        nload_fwd_src.stq_idx |= stq_idx_t'(i);
        nload_fwd_src.data_valid |= stq[i].data_valid;
      end
    end
  end

endmodule

`default_nettype wire
