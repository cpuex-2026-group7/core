`timescale 1ns / 1ps
`default_nettype none

module ldq
  import types::*;
  import ooo_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
#(
  parameter int DISP_W   = 1,
  parameter int COMMIT_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush(ROBのFF)

  // dispatch
  input wire disp_ldq_t disp_ld[DISP_W],
  output ldq_idx_t disp_ldq_idx[DISP_W],
  output logic disp_full[DISP_W],
  // dispatch(branch)
  input wire logic disp_br_valid[DISP_W],
  input wire br_tag_t disp_br_tag[DISP_W],

  // STQから
  input wire older_st_t older_st[DISP_W],
  input wire stq_mask_t stq_release_mask,  // このサイクルに解放したSTQのエントリ。older_st_maskから落とす

  // AGUから
  input wire ex_lsu_t ex_lsu,

  // controller
  input wire ldq_idx_with_valid_t ld_requested,
  input wire ldq_idx_with_valid_t ld_nack,
  input wire ldq_idx_with_valid_t ld_gone_to_wb,
  output ldq_idx_t ldq_head_idx,

  // searcher
  input wire ldq_mask_t violation_mask,  // WBに出た後のloadが違反
  input wire ldq_mask_t stale_mask,  // WBに出る前のloadでアドレス一致したもの
  input wire ld_fwd_t ld_fwd,  // AGUに来たloadのforward元

  // controller、searcherへ
  output ldq_controller_t ldq_controller_ff[LDQ_SIZE],
  output ldq_searcher_t   ldq_searcher_ff  [LDQ_SIZE],

  // EXから
  input wire br_update_t br_update_ff,

  // ROB
  input wire logic commit_ld[COMMIT_W],
  output load_violation_t load_violation[COMMIT_W]  // headからk番目のloadまでについて情報提供
);

  ldq_ptr_t ldq_head, ldq_tail;
  ldq_ptr_t ldq_tail_snapshot[MAX_BR];
  ldq_entry_t ldq_ff[LDQ_SIZE];

  assign ldq_head_idx = ldq_head.ldq_idx;

  // ldq_ffからcontroller,searcherへ
  always_comb begin
    for (int i = 0; i < LDQ_SIZE; i++) begin
      ldq_controller_ff[i].valid = ldq_ff[i].valid;
      ldq_controller_ff[i].addr_valid = ldq_ff[i].addr_valid;
      ldq_controller_ff[i].addr = ldq_ff[i].addr;
      ldq_controller_ff[i].mmio = ldq_ff[i].mmio;
      ldq_controller_ff[i].ld_requested = ldq_ff[i].ld_requested;
      ldq_controller_ff[i].stale = ldq_ff[i].stale;
      ldq_controller_ff[i].gone_to_wb = ldq_ff[i].gone_to_wb;
      ldq_controller_ff[i].fwd_hit = ldq_ff[i].fwd_hit;
      ldq_controller_ff[i].fwd_stq_idx = ldq_ff[i].fwd_stq_idx;
      ldq_controller_ff[i].rd = ldq_ff[i].rd;
      ldq_controller_ff[i].rob_idx = ldq_ff[i].rob_idx;
      ldq_controller_ff[i].brmask = ldq_ff[i].brmask;

      ldq_searcher_ff[i].valid = ldq_ff[i].valid;
      ldq_searcher_ff[i].addr_valid = ldq_ff[i].addr_valid;
      ldq_searcher_ff[i].addr = ldq_ff[i].addr;
      ldq_searcher_ff[i].ld_requested = ldq_ff[i].ld_requested;
      ldq_searcher_ff[i].gone_to_wb = ldq_ff[i].gone_to_wb;
      ldq_searcher_ff[i].older_st_mask = ldq_ff[i].older_st_mask;
      ldq_searcher_ff[i].tail_stq_idx = ldq_ff[i].tail_stq_idx;
      ldq_searcher_ff[i].fwd_hit = ldq_ff[i].fwd_hit;
      ldq_searcher_ff[i].fwd_stq_idx = ldq_ff[i].fwd_stq_idx;
    end
  end

  // disp_tailとtail_snapshot
  ldq_ptr_t disp_tail[DISP_W+1];
  ldq_ptr_t n_ldq_tail_snapshot[MAX_BR];
  always_comb begin
    for (int i = 0; i < MAX_BR; i++) begin
      n_ldq_tail_snapshot[i] = ldq_tail_snapshot[i];
    end
    disp_tail[0] = ldq_tail;
    for (int i = 0; i < DISP_W; i++) begin
      disp_ldq_idx[i] = disp_tail[i].ldq_idx;
      disp_full[i] = ldq_ptr_full(ldq_head, disp_tail[i]);

      // snapshotを詰める
      if (disp_br_valid[i]) begin
        n_ldq_tail_snapshot[disp_br_tag[i]] = disp_tail[i];
      end

      // 命令が入った場合disp_tailを進める
      if (disp_ld[i].valid && !disp_full[i]) begin
        disp_tail[i+1] = ldq_ptr_inc(disp_tail[i]);
      end else begin
        disp_tail[i+1] = disp_tail[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < MAX_BR; i++) begin
        ldq_tail_snapshot[i] <= '0;
      end
    end else begin
      for (int i = 0; i < MAX_BR; i++) begin
        ldq_tail_snapshot[i] <= n_ldq_tail_snapshot[i];
      end
    end
  end

  // ldq_ffとhead,tail
  ldq_ptr_t n_ldq_head, n_ldq_tail;
  ldq_entry_t n_ldq_ff[LDQ_SIZE];
  always_comb begin
    for (int i = 0; i < LDQ_SIZE; i++) begin
      n_ldq_ff[i] = ldq_ff[i];
    end
    n_ldq_head = ldq_head;
    n_ldq_tail = disp_tail[DISP_W];

    // resolve_mask
    for (int i = 0; i < LDQ_SIZE; i++) begin
      n_ldq_ff[i].brmask = apply_br_resolve(ldq_ff[i].brmask, br_update_ff);
    end
    // kill_mask
    for (int i = 0; i < LDQ_SIZE; i++) begin
      n_ldq_ff[i].valid &= !br_kill_check(ldq_ff[i].brmask, br_update_ff);
    end
    // store resolve
    for (int i = 0; i < LDQ_SIZE; i++) begin
      n_ldq_ff[i].older_st_mask = apply_st_resolve(ldq_ff[i].older_st_mask, stq_release_mask);
    end

    // requested
    if (ld_requested.valid) begin
      n_ldq_ff[ld_requested.ldq_idx].ld_requested = 1'b1;
    end
    // gone_to_wb
    if (ld_gone_to_wb.valid) begin
      n_ldq_ff[ld_gone_to_wb.ldq_idx].ld_requested = 1'b0;
      n_ldq_ff[ld_gone_to_wb.ldq_idx].gone_to_wb   = 1'b1;
    end
    // violation,stale
    for (int i = 0; i < LDQ_SIZE; i++) begin
      n_ldq_ff[i].violated |= violation_mask[i];  // wbまで行った救いようのない違反
      n_ldq_ff[i].stale |= n_ldq_ff[i].ld_requested & stale_mask[i];  // wbに行く前なのでstaleにして救う
    end
    // nack
    if (ld_nack.valid) begin
      n_ldq_ff[ld_nack.ldq_idx].ld_requested = 1'b0;
      n_ldq_ff[ld_nack.ldq_idx].stale = 1'b0;
    end

    // dispatch
    if (!br_update_ff.mispredict && !flush) begin
      for (int i = 0; i < DISP_W; i++) begin
        if (disp_ld[i].valid && !disp_full[i]) begin
          n_ldq_ff[disp_ldq_idx[i]].valid = 1'b1;
          n_ldq_ff[disp_ldq_idx[i]].addr_valid = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].mmio = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].ld_requested = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].stale = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].older_st_mask = older_st[i].older_st_mask; //同じサイクルのreleaseは除外済み
          n_ldq_ff[disp_ldq_idx[i]].tail_stq_idx = older_st[i].tail_stq_idx;
          n_ldq_ff[disp_ldq_idx[i]].violated = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].fwd_hit = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].gone_to_wb = 1'b0;
          n_ldq_ff[disp_ldq_idx[i]].rd = disp_ld[i].rd;
          n_ldq_ff[disp_ldq_idx[i]].rob_idx = disp_ld[i].rob_idx;
          n_ldq_ff[disp_ldq_idx[i]].brmask = apply_br_resolve(disp_ld[i].brmask, br_update_ff);
        end
      end
    end

    // AGUから
    if (!ex_lsu.is_store && ex_lsu.addr_valid) begin
      // loadのアドレスが来た場合
      n_ldq_ff[ex_lsu.ldq_idx].addr_valid = 1'b1;
      n_ldq_ff[ex_lsu.ldq_idx].addr = ex_lsu.addr;
      n_ldq_ff[ex_lsu.ldq_idx].fwd_hit = ld_fwd.hit;
      n_ldq_ff[ex_lsu.ldq_idx].fwd_stq_idx = ld_fwd.stq_idx;
      n_ldq_ff[ex_lsu.ldq_idx].mmio = (ex_lsu.addr == MMIO_RX_ADDR);
    end
    if (ex_lsu.is_store && ex_lsu.addr_valid) begin
      // storeのアドレスが来た場合
      for (int i = 0; i < LDQ_SIZE; i++) begin
        if (stale_mask[i]) begin
          n_ldq_ff[i].fwd_hit = 1'b1;
          n_ldq_ff[i].fwd_stq_idx = ex_lsu.stq_idx;
        end
      end
    end

    // stq_releaseによるforward元の解放
    for (int i = 0; i < LDQ_SIZE; i++) begin
      if (stq_release_mask[n_ldq_ff[i].fwd_stq_idx]) begin
        n_ldq_ff[i].fwd_hit = 1'b0;
        n_ldq_ff[i].fwd_stq_idx = '0;
      end
    end

    // commitでheadを進める
    for (int i = 0; i < COMMIT_W; i++) begin
      if (commit_ld[i]) begin
        n_ldq_ff[n_ldq_head.ldq_idx].valid = 1'b0;
        n_ldq_head = ldq_ptr_inc(n_ldq_head);
      end
    end

    // 最後にflush確認
    if (flush) begin
      n_ldq_tail = n_ldq_head;
      for (int i = 0; i < LDQ_SIZE; i++) begin
        n_ldq_ff[i].valid = 1'b0;
      end
    end else if (br_update_ff.mispredict) begin
      n_ldq_tail = ldq_tail_snapshot[br_update_ff.tag];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < LDQ_SIZE; i++) begin
        ldq_ff[i] <= '0;
      end
      ldq_head <= '0;
      ldq_tail <= '0;
    end else begin
      for (int i = 0; i < LDQ_SIZE; i++) begin
        ldq_ff[i] <= n_ldq_ff[i];
      end
      ldq_head <= n_ldq_head;
      ldq_tail <= n_ldq_tail;
    end
  end

  // violation
  ldq_ptr_t violation_ptr[COMMIT_W+1];
  always_comb begin
    violation_ptr[0] = ldq_head;
    for (int i = 0; i < COMMIT_W; i++) begin
      load_violation[i].valid = ldq_ff[violation_ptr[i].ldq_idx].valid && ldq_ff[violation_ptr[i].ldq_idx].violated;
      load_violation[i].rob_idx = ldq_ff[violation_ptr[i].ldq_idx].rob_idx;
      violation_ptr[i+1] = ldq_ptr_inc(violation_ptr[i]);
    end
  end

endmodule

`default_nettype wire
