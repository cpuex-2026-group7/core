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

  // controller
  input wire ld_addr_t ld_addr,
  input wire ld_requested_t ld_requested,
  input wire ldq_idx_with_valid_t ld_nack,
  input wire ld_wb_notice_t ld_gone_to_wb,
  output ldq_idx_t ldq_head,

  // searcher
  input wire ldq_mask_t violation_mask,

  // controller、searcherへ
  output ldq_controller_t ldq_controller_ff[LDQ_SIZE],
  output ldq_searcher_t   ldq_searcher_ff  [LDQ_SIZE],

  // EXから
  input wire br_update_t br_update_ff,

  // ROB
  input wire logic commit_ld[COMMIT_W],
  output logic head_load_violation  // LDQの先頭のloadが順序違反
);

  ldq_idx_t ldq_tail;
  logic ldq_full;  // ldq_head == ldq_tailのとき空か満杯かを区別する
  ldq_idx_t ldq_tail_snapshot[MAX_BR];
  ldq_entry_t ldq_ff[LDQ_SIZE];

  always_comb begin
    for (int i = 0; i < LDQ_SIZE; i++) begin
      ldq_controller_ff[i].valid = ldq_ff[i].valid;
      ldq_controller_ff[i].addr_valid = ldq_ff[i].addr_valid;
      ldq_controller_ff[i].addr = ldq_ff[i].addr;
      ldq_controller_ff[i].mmio = ldq_ff[i].mmio;
      ldq_controller_ff[i].cache_requested = ldq_ff[i].cache_requested;
      ldq_controller_ff[i].stale = ldq_ff[i].stale;
      ldq_controller_ff[i].gone_to_wb = ldq_ff[i].gone_to_wb;
      ldq_controller_ff[i].rd = ldq_ff[i].rd;
      ldq_controller_ff[i].rob_idx = ldq_ff[i].rob_idx;
      ldq_controller_ff[i].brmask = ldq_ff[i].brmask;

      ldq_searcher_ff[i].valid = ldq_ff[i].valid;
      ldq_searcher_ff[i].addr_valid = ldq_ff[i].addr_valid;
      ldq_searcher_ff[i].addr = ldq_ff[i].addr;
      ldq_searcher_ff[i].cache_requested = ldq_ff[i].cache_requested;
      ldq_searcher_ff[i].gone_to_wb = ldq_ff[i].gone_to_wb;
      ldq_searcher_ff[i].older_st_mask = ldq_ff[i].older_st_mask;
      ldq_searcher_ff[i].tail_stq_idx = ldq_ff[i].tail_stq_idx;
      ldq_searcher_ff[i].forwarded = ldq_ff[i].forwarded;
      ldq_searcher_ff[i].forward_stq_idx = ldq_ff[i].forward_stq_idx;
    end
  end

endmodule

`default_nettype wire
