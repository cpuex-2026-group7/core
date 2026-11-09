`timescale 1ns / 1ps
`default_nettype none

module backend_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
#(
  parameter int SIZE_INT = 16,
  parameter int SIZE_MEM = 16,
  parameter int SIZE_FPU = 16,
  parameter int DISPATCH_W_INT = 1,
  parameter int DISPATCH_W_MEM = 1,
  parameter int DISPATCH_W_FPU = 1,
  parameter int LSU_DISP_W = 1,
  parameter int COMMIT_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush(ROBのFF)

  // dispatchからIQへ
  input wire logic disp_valid_int[DISPATCH_W_INT],
  input wire disp_uop_t disp_uop_int[DISPATCH_W_INT],
  output logic disp_full_int,

  input wire logic disp_valid_mem[DISPATCH_W_MEM],
  input wire disp_uop_t disp_uop_mem[DISPATCH_W_MEM],
  output logic disp_full_mem,

  input wire logic disp_valid_fpu[DISPATCH_W_FPU],
  input wire disp_uop_t disp_uop_fpu[DISPATCH_W_FPU],
  output logic disp_full_fpu,

  // dispatchからLSUへ(スロットが小さい方が古い)
  input wire disp_ldq_t disp_ld[LSU_DISP_W],
  output ldq_idx_t disp_ldq_idx[LSU_DISP_W],
  output logic disp_ld_full[LSU_DISP_W],
  input wire disp_stq_t disp_st[LSU_DISP_W],
  output stq_idx_t disp_stq_idx[LSU_DISP_W],
  output logic disp_st_full[LSU_DISP_W],
  input wire logic disp_br_valid[LSU_DISP_W],
  input wire br_tag_t disp_br_tag[LSU_DISP_W],

  // 全体へ
  output br_update_t br_update_ff,

  // ROB
  output complete_t complete_idx[5],
  output complete_t complete_st,
  output logic stq_empty,
  output logic head_load_violation,
  input wire logic commit_ld[COMMIT_W],
  input wire logic commit_st[COMMIT_W],
  input wire logic rob_head_ld,

  // D$
  output logic dc_req_valid_ff,
  output logic dc_req_we_ff,
  output logic [31:0] dc_req_addr_ff,
  output logic [31:0] dc_req_wdata_ff,
  output logic [DC_TAG_W-1:0] dc_req_tag_ff,
  output logic [MAX_BR-1:0] dc_req_brmask_ff,

  input wire logic dc_req_accepted,

  input wire logic dc_resp_valid,
  input wire logic dc_resp_ack,
  input wire logic [31:0] dc_resp_rdata,
  input wire logic [DC_TAG_W-1:0] dc_resp_tag,

  output logic [MAX_BR-1:0] dc_br_kill_mask_ff,
  output logic [MAX_BR-1:0] dc_br_resolve_mask_ff,
  output logic dc_kill_all_ff
);

  // IQ -> RR
  iq_rr_t rr_int_ff[1];
  int_payload_t rr_payload_int_ff[1];
  iq_rr_t rr_mem_ff[1];
  mem_payload_t rr_payload_mem_ff[1];
  logic [1:0] rr_issue_part_mem_ff[1];
  iq_rr_t rr_fpu_ff[3];
  float_payload_t rr_payload_fpu_ff[3];

  // RR -> EX
  rr_ex_int_t rr_ex_int[1];
  rr_ex_mem_t rr_ex_mem[1];
  rr_ex_float_t rr_ex_fpu[3];

  // EX, LSU -> WB
  ex_wb_t wb_alu[1];
  ex_wb_t wb_mem[1];
  ex_wb_t wb_fpu[3];
  bypass_t bypass_fpu_f[2];
  bypass_t bypass_fpu_i[1];

  // EX -> LSU
  ex_lsu_t ex_lsu[1];

  // EX, LSU -> IQ
  wakeup_t slow_wakeup_fpu;
  wakeup_t slow_wakeup_mem;
  logic fdiv_blocked;
  logic fsqrt_blocked;

  wakeup_t coming_wakeup[2];
  assign coming_wakeup[0] = slow_wakeup_fpu;
  assign coming_wakeup[1] = slow_wakeup_mem;

  iq_top #(
    .I_PREG_NUM(NUM_PREG_I),
    .F_PREG_NUM(NUM_PREG_F),
    .SIZE_INT(SIZE_INT),
    .SIZE_MEM(SIZE_MEM),
    .SIZE_FPU(SIZE_FPU),
    .DISPATCH_W_INT(DISPATCH_W_INT),
    .DISPATCH_W_MEM(DISPATCH_W_MEM),
    .DISPATCH_W_FPU(DISPATCH_W_FPU),
    .WAKEUP_W(2)
  ) u_iq_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .disp_valid_int(disp_valid_int),
    .disp_uop_int(disp_uop_int),
    .disp_full_int(disp_full_int),
    .disp_valid_mem(disp_valid_mem),
    .disp_uop_mem(disp_uop_mem),
    .disp_full_mem(disp_full_mem),
    .disp_valid_fpu(disp_valid_fpu),
    .disp_uop_fpu(disp_uop_fpu),
    .disp_full_fpu(disp_full_fpu),
    .coming_wakeup(coming_wakeup),
    .br_update_ff(br_update_ff),
    .fdiv_blocked(fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked),
    .rr_int_ff(rr_int_ff),
    .rr_payload_int_ff(rr_payload_int_ff),
    .rr_mem_ff(rr_mem_ff),
    .rr_payload_mem_ff(rr_payload_mem_ff),
    .rr_issue_part_mem_ff(rr_issue_part_mem_ff),
    .rr_fpu_ff(rr_fpu_ff),
    .rr_payload_fpu_ff(rr_payload_fpu_ff)
  );

  rf_top #(
    .I_PREG_NUM(NUM_PREG_I),
    .F_PREG_NUM(NUM_PREG_F)
  ) u_rf_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_int_ff(rr_int_ff),
    .rr_payload_int_ff(rr_payload_int_ff),
    .rr_mem_ff(rr_mem_ff),
    .rr_payload_mem_ff(rr_payload_mem_ff),
    .rr_issue_part_mem_ff(rr_issue_part_mem_ff),
    .rr_fpu_ff(rr_fpu_ff),
    .rr_payload_fpu_ff(rr_payload_fpu_ff),
    .rr_ex_int(rr_ex_int),
    .rr_ex_mem(rr_ex_mem),
    .rr_ex_fpu(rr_ex_fpu),
    .wb_alu(wb_alu),
    .wb_mem(wb_mem),
    .wb_fpu(wb_fpu),
    .bypass_fpu_f(bypass_fpu_f),
    .bypass_fpu_i(bypass_fpu_i),
    .complete_idx(complete_idx),
    .br_update_ff(br_update_ff)
  );

  ex_top u_ex_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex_int(rr_ex_int),
    .rr_ex_mem(rr_ex_mem),
    .rr_ex_fpu(rr_ex_fpu),
    .wb_alu(wb_alu),
    .wb_fpu(wb_fpu),
    .bypass_fpu_f(bypass_fpu_f),
    .bypass_fpu_i(bypass_fpu_i),
    .ex_lsu(ex_lsu),
    .br_update_ff(br_update_ff),
    .slow_wakeup_fpu(slow_wakeup_fpu),
    .fdiv_blocked(fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked)
  );

  lsu_top #(
    .DISP_W  (LSU_DISP_W),
    .COMMIT_W(COMMIT_W)
  ) u_lsu_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .disp_ld(disp_ld),
    .disp_ldq_idx(disp_ldq_idx),
    .disp_ld_full(disp_ld_full),
    .disp_st(disp_st),
    .disp_stq_idx(disp_stq_idx),
    .disp_st_full(disp_st_full),
    .disp_br_valid(disp_br_valid),
    .disp_br_tag(disp_br_tag),
    .ex_lsu(ex_lsu),
    .br_update_ff(br_update_ff),
    .commit_ld(commit_ld),
    .commit_st(commit_st),
    .rob_head_ld(rob_head_ld),
    .complete_st(complete_st),
    .stq_empty(stq_empty),
    .head_load_violation(head_load_violation),
    .wb_mem(wb_mem),
    .slow_wakeup_mem(slow_wakeup_mem),
    .dc_req_valid_ff(dc_req_valid_ff),
    .dc_req_we_ff(dc_req_we_ff),
    .dc_req_addr_ff(dc_req_addr_ff),
    .dc_req_wdata_ff(dc_req_wdata_ff),
    .dc_req_tag_ff(dc_req_tag_ff),
    .dc_req_brmask_ff(dc_req_brmask_ff),
    .dc_req_accepted(dc_req_accepted),
    .dc_resp_valid(dc_resp_valid),
    .dc_resp_ack(dc_resp_ack),
    .dc_resp_rdata(dc_resp_rdata),
    .dc_resp_tag(dc_resp_tag),
    .dc_br_kill_mask_ff(dc_br_kill_mask_ff),
    .dc_br_resolve_mask_ff(dc_br_resolve_mask_ff),
    .dc_kill_all_ff(dc_kill_all_ff)
  );

endmodule

`default_nettype wire
