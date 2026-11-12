`timescale 1ns / 1ps
`default_nettype none

module lsu_top
  import types::*;
  import ooo_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
#(
  parameter int DISP_W   = 2,
  parameter int COMMIT_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush(ROBのFF)

  // dispatch(スロットが小さい方が古い)
  // load
  input wire disp_ldq_t disp_ld[DISP_W],
  output ldq_idx_t disp_ldq_idx[DISP_W],
  output logic disp_ld_full[DISP_W],
  // store
  input wire disp_stq_t disp_st[DISP_W],
  output stq_idx_t disp_stq_idx[DISP_W],
  output logic disp_st_full[DISP_W],
  // branch(tail snapshotをLSU内で取らせる)
  input wire logic disp_br_valid[DISP_W],
  input wire br_tag_t disp_br_tag[DISP_W],

  // AGUから
  input wire ex_lsu_t ex_lsu[1],

  // EXから
  input wire br_update_t br_update_ff,

  // ROB
  input wire logic commit_ld[COMMIT_W],  // loadをコミットしたヨ
  input wire logic commit_st[COMMIT_W],  // storeをコミットしたヨ
  input wire logic rob_head_ld,  // MMIOのloadは取り消されるとまずいのでROBの先頭しか無理
  output complete_t complete_st,  // addressとdata揃ったらcomplete出す
  output logic stq_empty,  // commit済みのstoreも全部D$に書き終わった(halt用)
  output load_violation_t load_violation[COMMIT_W],  // headからk番目のloadまでについて情報提供

  // RFへ
  output lsu_wb_t wb_mem[1],  // loadをRFへ

  // IQへ
  output wakeup_t slow_wakeup_mem,

  // D$へ
  // killされたloadは次のサイクル以降validなrespを返さない
  // killが届くまでに出したrespはcore側の責任で無視する
  // 生きている要求にはackかnackをちょうど1回返す
  // MMIOはacceptしたらnackしない
  // パラメータとして DC_TAG_WとMAX_BRを渡す
  // clk(coreと同じ)、rst(coreと同じ)D$に渡す
  // 下は全部core側のFF
  output logic dc_req_valid_ff,
  output logic dc_req_we_ff,
  output logic [31:0] dc_req_addr_ff,  // ワードアドレッシング
  output logic [31:0] dc_req_wdata_ff,
  output logic [DC_TAG_W-1:0] dc_req_tag_ff,
  output logic [MAX_BR-1:0] dc_req_brmask_ff,  // storeはcommit後なので'0

  input wire logic dc_req_accepted,

  input wire logic dc_resp_valid,
  input wire logic dc_resp_ack,  // 1:ack, 0:nack (acceptした後)
  input wire logic [31:0] dc_resp_rdata,
  input wire logic [DC_TAG_W-1:0] dc_resp_tag,

  output logic [MAX_BR-1:0] dc_br_kill_mask_ff,  // 予測ミスしていてkillすべき分岐のmask
  output logic [MAX_BR-1:0] dc_br_resolve_mask_ff,  // 予測あっていてbitを落とすべき分岐のmask
  output logic dc_kill_all_ff  // loadを全kill
);

  dc_req_t  dc_req_ff;
  dc_resp_t dc_resp;

  assign dc_req_valid_ff = dc_req_ff.valid;
  assign dc_req_we_ff = dc_req_ff.we;
  assign dc_req_addr_ff = dc_req_ff.addr;
  assign dc_req_wdata_ff = dc_req_ff.wdata;
  assign dc_req_tag_ff = dc_req_ff.tag;
  assign dc_req_brmask_ff = dc_req_ff.brmask;

  assign dc_resp.valid = dc_resp_valid;
  assign dc_resp.tag = lsu_tag_t'(dc_resp_tag);
  assign dc_resp.ack = dc_resp_ack;
  assign dc_resp.rdata = dc_resp_rdata;

  assign dc_br_kill_mask_ff = br_update_ff.kill_mask;
  assign dc_br_resolve_mask_ff = br_update_ff.resolve_mask;

  assign dc_kill_all_ff = flush;

  older_st_t older_st[DISP_W];
  stq_mask_t stq_release_mask;

  ldq_controller_t ldq_controller[LDQ_SIZE];
  ldq_searcher_t ldq_searcher[LDQ_SIZE];
  ldq_idx_t ldq_head_idx;
  stq_controller_t stq_controller;
  stq_searcher_t stq_searcher[STQ_SIZE];

  ld_requested_t ld_requested;
  ldq_idx_with_valid_t ld_nack;
  ld_wb_notice_t ld_gone_to_wb;
  logic st_requested;
  stq_idx_with_valid_t st_ack, st_nack;

  ldq_idx_t forward_ldq_idx;
  forward_result_t forward_result;
  ldq_mask_t violation_mask, stale_mask;

  ldq #(
    .DISP_W  (DISP_W),
    .COMMIT_W(COMMIT_W)
  ) u_ldq (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .disp_ld(disp_ld),
    .disp_ldq_idx(disp_ldq_idx),
    .disp_full(disp_ld_full),
    .older_st(older_st),
    .stq_release_mask(stq_release_mask),
    .disp_br_valid(disp_br_valid),
    .disp_br_tag(disp_br_tag),
    .ex_lsu(ex_lsu[0]),
    .ld_requested(ld_requested),
    .ld_nack(ld_nack),
    .ld_gone_to_wb(ld_gone_to_wb),
    .violation_mask(violation_mask),
    .stale_mask(stale_mask),
    .br_update_ff(br_update_ff),
    .commit_ld(commit_ld),
    .ldq_controller_ff(ldq_controller),
    .ldq_searcher_ff(ldq_searcher),
    .ldq_head_idx(ldq_head_idx),
    .load_violation(load_violation)
  );

  stq #(
    .DISP_W  (DISP_W),
    .COMMIT_W(COMMIT_W)
  ) u_stq (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .disp_st(disp_st),
    .disp_stq_idx(disp_stq_idx),
    .disp_full(disp_st_full),
    .older_st(older_st),
    .stq_release_mask(stq_release_mask),
    .disp_br_valid(disp_br_valid),
    .disp_br_tag(disp_br_tag),
    .ex_lsu(ex_lsu[0]),
    .st_requested(st_requested),
    .st_ack(st_ack),
    .st_nack(st_nack),
    .br_update_ff(br_update_ff),
    .commit_st(commit_st),
    .stq_controller(stq_controller),
    .stq_searcher_ff(stq_searcher),
    .complete_st(complete_st),
    .stq_empty(stq_empty)
  );

  lsu_controller u_lsu_controller (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_lsu(ex_lsu[0]),
    .br_update_ff(br_update_ff),
    .rob_head_ld(rob_head_ld),
    .ldq(ldq_controller),
    .ldq_head_idx(ldq_head_idx),
    .stq(stq_controller),
    .ld_requested(ld_requested),
    .ld_nack(ld_nack),
    .ld_gone_to_wb(ld_gone_to_wb),
    .st_requested(st_requested),
    .st_ack(st_ack),
    .st_nack(st_nack),
    .forward_ldq_idx(forward_ldq_idx),
    .forward_result(forward_result),
    .stale_mask(stale_mask),
    .wb_mem(wb_mem[0]),
    .slow_wakeup_mem(slow_wakeup_mem),
    .dc_req_ff(dc_req_ff),
    .dc_accepted(dc_req_accepted),
    .dc_resp(dc_resp)
  );

  lsu_searcher u_lsu_searcher (
    .ldq(ldq_searcher),
    .stq(stq_searcher),
    .forward_ldq_idx(forward_ldq_idx),
    .forward_result(forward_result),
    .ex_lsu(ex_lsu[0]),
    .violation_mask(violation_mask),
    .stale_mask(stale_mask)
  );

endmodule

`default_nettype wire
