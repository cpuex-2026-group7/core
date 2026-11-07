`timescale 1ns / 1ps
`default_nettype none

module lsu_controller
  import types::*;
  import ooo_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // AGUから
  input wire ex_lsu_t ex_lsu,

  // EXから
  input wire br_update_t br_update_ff,

  // ROBから
  input wire logic rob_head_ld,

  // LDQ
  input wire ldq_entry_t ldq[LDQ_SIZE],
  input wire ldq_idx_t ldq_head,  // loadの先頭(MMIO用)
  output ld_addr_t ld_addr,
  output ldq_idx_with_valid_t ld_requested,
  output ldq_idx_with_valid_t ld_nack,
  output ld_wb_notice_t ld_gone_to_wb,

  // STQ
  input wire stq_entry_t stq[STQ_SIZE],
  input wire stq_idx_t stq_head,  // storeの先頭(MMIO用)
  input wire stq_idx_t stq_exec_head,  // 次にD$に送るstore
  output st_addr_t st_addr,
  output st_data_t st_data,
  output logic st_requested,
  output stq_idx_with_valid_t st_ack,
  output stq_idx_with_valid_t st_nack,

  // searcher
  output forward_search_t forward_search,
  input wire forward_result_t forward_result,

  // RFへ
  output ex_wb_t wb_mem,

  // IQへ
  output wakeup_t slow_wakeup_mem,

  // D$
  // ここ3つはFF
  output dc_req_t dc_req_ff,  // acceptされるまで保持。毎サイクルbr_update_ffを当てる
  input wire logic dc_accepted,
  input wire dc_resp_t dc_resp
);

endmodule

`default_nettype wire
