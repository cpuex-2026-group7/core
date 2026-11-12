`timescale 1ns / 1ps
`default_nettype none

module lsu_searcher
  import types::*;
  import ooo_types::*;
  import ex_types::*;
  import lsu_types::*;
(
  // bypassとかload違反を探す

  // LDQ
  input wire ldq_searcher_t ldq[LDQ_SIZE],
  output ldq_mask_t violation_mask,  // WBに出た後のloadが違反
  output ldq_mask_t stale_mask,  // WBに出る前のloadが違反
  output ld_fwd_t ld_fwd,  // AGUに来たloadのforward元

  // STQから
  input wire stq_searcher_t stq[STQ_SIZE],

  // AGUから
  input wire ex_lsu_t ex_lsu

);

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
    stq_ptr_t p;
    ld_fwd = '0;
    p = '0;
    if (!ex_lsu.is_store && ex_lsu.addr_valid) begin
      p.wrap = 1'b0;
      p.stq_idx = ldq[ex_lsu.ldq_idx].tail_stq_idx;
      // tailから一周して最後に当たったものを採用
      for (int i = 0; i < STQ_SIZE; i++) begin
        if (ldq[ex_lsu.ldq_idx].older_st_mask[p.stq_idx] && stq[p.stq_idx].addr_valid && stq[p.stq_idx].addr == ex_lsu.addr && ex_lsu.addr != MMIO_RX_ADDR) begin
          ld_fwd.hit = 1'b1;
          ld_fwd.stq_idx = p.stq_idx;
        end
        p = stq_ptr_inc(p);
      end
    end
  end

endmodule

`default_nettype wire
