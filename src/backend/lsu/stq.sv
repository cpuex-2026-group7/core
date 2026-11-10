`timescale 1ns / 1ps
`default_nettype none

module stq
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
  input wire logic flush,  // loadの順序違反でflush(ROBのFF)。commit済みは残す

  // dispatch
  input wire disp_stq_t disp_st[DISP_W],
  output stq_idx_t disp_stq_idx[DISP_W],
  output logic disp_full[DISP_W],
  // dispatch(branch)
  input wire logic disp_br_valid[DISP_W],
  input wire br_tag_t disp_br_tag[DISP_W],

  // LDQへ
  output st_dep_t st_dep[DISP_W],
  output stq_mask_t stq_release_mask,  // このサイクルに解放したエントリ

  // controller
  input wire st_addr_t st_addr,
  input wire st_data_t st_data,
  input wire logic st_requested,  // stq_exec_headを進める
  input wire stq_idx_with_valid_t st_ack,
  input wire stq_idx_with_valid_t st_nack,  // stq_exec_headをそこまで戻す
  output stq_controller_t stq_controller,  // stq_exec_headのstore

  // searcherへ
  output stq_searcher_t stq_searcher_ff[STQ_SIZE],

  // EXから
  input wire br_update_t br_update_ff,

  // ROB
  input wire logic commit_st[COMMIT_W],
  output complete_t complete_st,
  output logic stq_empty  // commit済みのstoreも全部D$に書き終わった(halt用)
);

  stq_idx_t stq_head, stq_commit_head, stq_exec_head, stq_tail;
  logic stq_full;  // stq_head == stq_tailのとき空か満杯かを区別する
  stq_idx_t stq_tail_snapshot[MAX_BR];
  stq_entry_t stq_ff[STQ_SIZE];

  always_comb begin
    for (int i = 0; i < STQ_SIZE; i++) begin
      stq_searcher_ff[i].addr_valid = stq_ff[i].addr_valid;
      stq_searcher_ff[i].addr = stq_ff[i].addr;
      stq_searcher_ff[i].data_valid = stq_ff[i].data_valid;
      stq_searcher_ff[i].data = stq_ff[i].data;
    end
  end

endmodule

`default_nettype wire
