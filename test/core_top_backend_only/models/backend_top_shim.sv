`timescale 1ns / 1ps
`default_nettype none

// core_top の中の backend_top の代わり
// 本物（Makefile が src/backend/backend_top.sv のモジュール名を backend_top_real に変えたもの）を包む。
// core_top が繋いでいるポート（clk / rst / D$）はそのまま通し、まだ繋いでいない dispatch / ROB のポートは
// テストベンチ（tb_core_top_backend_only）の信号に繋ぐ。core_top が繋ぐポートを増やしたらここも合わせる
module backend_top
  import ooo_types::*;
  import lsu_types::*;
(
  input wire logic clk,
  input wire logic rst,

  output logic dc_req_valid_ff,
  output logic dc_req_we_ff,
  output logic [31:0] dc_req_addr_ff,
  output logic [31:0] dc_req_wdata_ff,
  output logic [DC_TAG_W-1:0] dc_req_tag_ff,
  output logic [MAX_BR-1:0] dc_req_brmask_ff,

  input wire logic dc_req_accepted,

  input wire logic dc_resp_valid_ff,
  input wire logic dc_resp_ack_ff,
  input wire logic [31:0] dc_resp_rdata_ff,
  input wire logic [DC_TAG_W-1:0] dc_resp_tag_ff,

  output logic [MAX_BR-1:0] dc_br_kill_mask_ff,
  output logic [MAX_BR-1:0] dc_br_resolve_mask_ff,
  output logic dc_kill_all_ff
);
  backend_top_real #(
    .LSU_DISP_W(tb_core_top_backend_only_pkg::LSU_DISP_W),
    .COMMIT_W(tb_core_top_backend_only_pkg::COMMIT_W)
  ) u_real (
    .clk(clk),
    .rst(rst),
    .flush(tb_core_top_backend_only.flush),
    .disp_valid_int(tb_core_top_backend_only.disp_valid_int),
    .disp_uop_int(tb_core_top_backend_only.disp_uop_int),
    .disp_full_int(tb_core_top_backend_only.disp_full_int),
    .disp_valid_mem(tb_core_top_backend_only.disp_valid_mem),
    .disp_uop_mem(tb_core_top_backend_only.disp_uop_mem),
    .disp_full_mem(tb_core_top_backend_only.disp_full_mem),
    .disp_valid_fpu(tb_core_top_backend_only.disp_valid_fpu),
    .disp_uop_fpu(tb_core_top_backend_only.disp_uop_fpu),
    .disp_full_fpu(tb_core_top_backend_only.disp_full_fpu),
    .disp_ld(tb_core_top_backend_only.disp_ld),
    .disp_ldq_idx(tb_core_top_backend_only.disp_ldq_idx),
    .disp_ld_full(tb_core_top_backend_only.disp_ld_full),
    .disp_st(tb_core_top_backend_only.disp_st),
    .disp_stq_idx(tb_core_top_backend_only.disp_stq_idx),
    .disp_st_full(tb_core_top_backend_only.disp_st_full),
    .disp_br_valid(tb_core_top_backend_only.disp_br_valid),
    .disp_br_tag(tb_core_top_backend_only.disp_br_tag),
    .br_update_ff(tb_core_top_backend_only.br_update_ff),
    .complete_idx(tb_core_top_backend_only.complete_idx),
    .complete_st(tb_core_top_backend_only.complete_st),
    .stq_empty(tb_core_top_backend_only.stq_empty),
    .load_violation(tb_core_top_backend_only.load_violation),
    .commit_ld(tb_core_top_backend_only.commit_ld),
    .commit_st(tb_core_top_backend_only.commit_st),
    .dc_req_valid_ff(dc_req_valid_ff),
    .dc_req_we_ff(dc_req_we_ff),
    .dc_req_addr_ff(dc_req_addr_ff),
    .dc_req_wdata_ff(dc_req_wdata_ff),
    .dc_req_tag_ff(dc_req_tag_ff),
    .dc_req_brmask_ff(dc_req_brmask_ff),
    .dc_req_accepted(dc_req_accepted),
    .dc_resp_valid_ff(dc_resp_valid_ff),
    .dc_resp_ack_ff(dc_resp_ack_ff),
    .dc_resp_rdata_ff(dc_resp_rdata_ff),
    .dc_resp_tag_ff(dc_resp_tag_ff),
    .dc_br_kill_mask_ff(dc_br_kill_mask_ff),
    .dc_br_resolve_mask_ff(dc_br_resolve_mask_ff),
    .dc_kill_all_ff(dc_kill_all_ff)
  );
endmodule

`default_nettype wire
