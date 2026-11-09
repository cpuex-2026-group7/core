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
  parameter int DISP_W = 1,
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
  input wire st_dep_t st_dep[DISP_W],
  input wire stq_mask_t stq_release_mask,  // このサイクルに解放したSTQのエントリ。st_dep_maskから落とす

  // controller
  input wire ld_addr_t ld_addr,
  input wire ldq_idx_with_valid_t ld_requested,
  input wire ldq_idx_with_valid_t ld_nack,
  input wire ld_wb_notice_t ld_gone_to_wb,
  output ldq_idx_t ldq_head,

  // searcher
  input wire ldq_mask_t violation_mask,

  // controller、searcherへ
  output ldq_entry_t ldq_ff[LDQ_SIZE],

  // EXから
  input wire br_update_t br_update_ff,

  // ROB
  input wire logic commit_ld[COMMIT_W],
  output logic head_load_violation  // LDQの先頭のloadが順序違反
);

  ldq_idx_t ldq_tail;
  logic ldq_full;  // ldq_head == ldq_tailのとき空か満杯かを区別する
  ldq_idx_t ldq_tail_snapshot[MAX_BR];

endmodule

`default_nettype wire
