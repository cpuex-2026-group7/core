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
  input wire logic flush, // loadの順序違反でflush

  // dispatch(スロットが小さい方が古い)
  // load
  input wire disp_lsu_t disp_ld[DISP_W],
  output ldq_idx_t disp_ldq_idx[DISP_W],
  output logic disp_ld_full[DISP_W],
  // store
  input wire disp_lsu_t disp_st[DISP_W],
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
  output load_violation_t load_violation,  // load順序違反

  // RFへ
  output ex_wb_t wb_mem[1],  // loadをRFへ

  // IQへ
  output wakeup_t slow_wakeup_mem,

  // D$へ
  // killされたloadは次のサイクル以降validなrespを返さない
  // killが届くまでに出したrespはcore側の責任で無視する
  // 生きている要求にはackかnackをちょうど1回返す
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

  always_ff @(posedge clk) begin
    dc_kill_all_ff <= !rst & flush;
  end

  st_dep_t st_dep[DISP_W];

  ldq_entry_t ldq[LDQ_SIZE];
  ldq_idx_t ldq_head;
  stq_entry_t stq[STQ_SIZE];
  stq_idx_t stq_head;
  stq_idx_t stq_exec_head;

  ld_addr_t ld_addr;
  ldq_idx_with_valid_t ld_requested, ld_nack;
  ld_wb_notice_t ld_gone_to_wb;
  st_addr_t st_addr;
  st_data_t st_data;
  logic st_requested;
  stq_idx_with_valid_t st_ack, st_nack;

  forward_search_t forward_search;
  forward_result_t forward_result;
  ldq_mask_t violation_mask;

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
    .st_dep(st_dep),
    .disp_br_valid(disp_br_valid),
    .disp_br_tag(disp_br_tag),
    .ld_addr(ld_addr),
    .ld_requested(ld_requested),
    .ld_nack(ld_nack),
    .ld_gone_to_wb(ld_gone_to_wb),
    .violation_mask(violation_mask),
    .br_update_ff(br_update_ff),
    .commit_ld(commit_ld),
    .ldq_ff(ldq),
    .ldq_head(ldq_head),
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
    .st_dep(st_dep),
    .disp_br_valid(disp_br_valid),
    .disp_br_tag(disp_br_tag),
    .st_addr(st_addr),
    .st_data(st_data),
    .st_requested(st_requested),
    .st_ack(st_ack),
    .st_nack(st_nack),
    .br_update_ff(br_update_ff),
    .commit_st(commit_st),
    .stq_ff(stq),
    .stq_head(stq_head),
    .exec_head(stq_exec_head),
    .complete_st(complete_st)
  );

  lsu_controller u_lsu_controller (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_lsu(ex_lsu[0]),
    .br_update_ff(br_update_ff),
    .rob_head_ld(rob_head_ld),
    .ldq(ldq),
    .ldq_head(ldq_head),
    .stq(stq),
    .stq_head(stq_head),
    .stq_exec_head(stq_exec_head),
    .ld_addr(ld_addr),
    .ld_requested(ld_requested),
    .ld_nack(ld_nack),
    .ld_gone_to_wb(ld_gone_to_wb),
    .st_addr(st_addr),
    .st_data(st_data),
    .st_requested(st_requested),
    .st_ack(st_ack),
    .st_nack(st_nack),
    .forward_search(forward_search),
    .forward_result(forward_result),
    .wb_mem(wb_mem[0]),
    .slow_wakeup_mem(slow_wakeup_mem),
    .dc_req_ff(dc_req_ff),
    .dc_accepted(dc_req_accepted),
    .dc_resp(dc_resp)
  );

  lsu_searcher u_lsu_searcher (
    .ldq(ldq),
    .stq(stq),
    .forward_search(forward_search),
    .forward_result(forward_result),
    .violation_search(st_addr),
    .violation_mask(violation_mask)
  );

endmodule

`default_nettype wire
