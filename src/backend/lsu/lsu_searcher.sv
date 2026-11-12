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

  // STQから
  input wire stq_searcher_t stq[STQ_SIZE],

  // controller
  input  wire ldq_idx_t   forward_ldq_idx,  // forward元のstoreを探す
  output forward_result_t forward_result,

  // AGUから(順序違反探す用)
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
            violation_mask[i] = !(ldq[i].forwarded && ofs_from_tail(ldq[i].tail_stq_idx, ldq[i].forward_stq_idx) >
                                  ofs_from_tail(ldq[i].tail_stq_idx, ex_lsu.stq_idx));
            stale_mask[i] = 1'b0;
          end else begin
            violation_mask[i] = 1'b0;
            stale_mask[i] = ldq[i].ld_requested;
          end
        end
      end
    end
  end

  // loadより古いstoreのうち一番新しいものからfoward
  stq_ptr_t p;
  always_comb begin
    forward_result = '0;
    p.wrap = 1'b0;
    p.stq_idx = ldq[forward_ldq_idx].tail_stq_idx;
    // tailから一周して最後に当たったものが採用
    for (int i = 0; i < STQ_SIZE; i++) begin
      if (ldq[forward_ldq_idx].older_st_mask[p.stq_idx] && stq[p.stq_idx].addr_valid && stq[p.stq_idx].addr == ldq[forward_ldq_idx].addr) begin
        forward_result.hit = 1'b1;
        forward_result.data_valid = stq[p.stq_idx].data_valid;
        forward_result.stq_idx = p.stq_idx;
        forward_result.data = stq[p.stq_idx].data;
      end
      p = stq_ptr_inc(p);
    end
  end

endmodule

`default_nettype wire
