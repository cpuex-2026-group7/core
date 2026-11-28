`timescale 1ns / 1ps
`default_nettype none

// todo: package内のlocalparamまわり、よくなさそうなのでどうにかする
// todo: RASの巻き戻しをどうするか

module frontend_top #(
    parameter int FETCH_W = 2,
    parameter int BTB_ENTRY_SIZE = 128,
    parameter int BTB_TAG_WIDTH = 9,
    parameter int RAS_SIZE = 8,
    parameter int MAX_BR = 8,
    parameter int GHR_ENTRY = 16,
    parameter int FETCHQ_IDX_WIDTH = 5,
    parameter int FTQ_IDX_WIDTH = 5
) (
    input wire logic clk,
    input wire logic rst,

    output types::pc_t fetch_pcs[FETCH_W],
    input wire isa::instr_t instrs[FETCH_W],

    input wire ooo_types::br_update_t br_update,

    // backend redirect以外でstallする場合、frontend_stallを1にする
    input wire logic req_stall,

    output frontend_pkg::fetch_packet_t fetchq_dout,
    input wire logic fetchq_pop,
    output logic fetchq_valid,

    input wire logic ftq_pop,

    input wire frontend_pkg::ghr_push_t ghr_push_comm,

    // load violation
    input wire logic excp,

    // from commit
    input wire frontend_pkg::gshare_idx_t gshare_upd_idx,
    input wire logic [FETCH_W-1:0] gshare_upd_taken,
    input wire logic gshare_upd_valid
);

  types::pc_t pc_seq;
  assign pc_seq = fetch_pcs[0] + types::pc_t'(FETCH_W);

  frontend_pkg::btb_resp_t btb_resp;

  logic ber;
  types::pc_t ber_target_pc;
  assign ber = br_update.mispredict;
  assign ber_target_pc = br_update.target;

  types::pc_t target_pc;

  types::pc_t next_pc;
  assign next_pc = ber ? ber_target_pc : target_pc;

  always_ff @(posedge clk) begin : update_fetch_pcs
    if (rst) begin
      for (int i = 0; i < FETCH_W; i++) begin
        fetch_pcs[i] <= '0;
      end
    end else if (!frontend_stall) begin
      fetch_pcs[0] <= next_pc;
      for (int i = 1; i < FETCH_W; i++) begin
        fetch_pcs[i] <= next_pc + types::pc_t'(i);
      end
    end
  end

  types::pc_t pcs_F1[FETCH_W];
  always_ff @(posedge clk) begin : update_pcs_F1
    if (rst) begin
      for (int i = 0; i < FETCH_W; i++) begin
        pcs_F1[i] <= '0;
      end
    end else if (!frontend_stall) begin
      pcs_F1 <= fetch_pcs;
    end
  end

  logic [FETCH_W-1:0] instr_valid;

  // output of brtag_mng
  logic brtag_empty;

  // 1 = fetchq is not full; output of fetchq
  logic fetchq_ready;

  logic ftq_full;
  logic ftq_empty;  // may be unnecessary

  logic ftq_ready;
  assign ftq_ready = !(|alive_branch_mask && ftq_full);

  logic frontend_stall;
  assign frontend_stall = 
    !ber && 
    (req_stall || 
      (|instr_valid && 
          (!(fetchq_ready && ftq_ready) || (brtag_empty && |alive_branch_mask)))
      );

  logic fire_instr;
  assign fire_instr = !ber && !excp && |instr_valid && !frontend_stall;

  // output of ftq
  frontend_pkg::ftq_data_t ftq_resp_redirect;

  btb #(
      .FETCH_W(FETCH_W),
      .BTB_ENTRY_SIZE(BTB_ENTRY_SIZE),
      .BTB_TAG_WIDTH(BTB_TAG_WIDTH)
  ) u_btb (
      .clk(clk),
      .rst(rst),
      .pc(fetch_pcs[0]),
      .resp(btb_resp),
      .update_en(ber),
      .btb_update('{pc: ftq_resp_redirect.pc, valid: ber, target: ber_target_pc})
  );

  // output from br_checker
  logic is_call;
  logic is_ret;

  types::pc_t ras_target;

  ras #(
      .RAS_SIZE(RAS_SIZE)
  ) u_ras (
      .clk(clk),
      .rst(rst),
      .ras_push(is_call),
      .ras_push_pc(target_pc),
      .ras_pop(is_ret),
      .ras_target(ras_target)
  );

  logic [GHR_ENTRY-1:0] ghr;

  // output from br_checker
  logic [$clog2(FETCH_W+1)-1:0] alive_branch_count;
  logic [FETCH_W-1:0] takens;

  logic [$clog2(MAX_BR)-1:0] snap_push_idx;

  ghr #(
      .GHR_ENTRY(GHR_ENTRY),
      .MAX_BR(MAX_BR)
  ) u_ghr (
      .clk(clk),
      .rst(rst),
      .ghr(ghr),
      .ghr_push_spec('{size: alive_branch_count, taken: takens}),
      .ghr_push_comm(ghr_push_comm),
      .snap_push(|alive_branch_mask),
      .snap_push_idx(snap_push_idx),
      .snap_recov(br_update.mispredict),
      .snap_recov_idx(ftq_resp_redirect.bp_data.ghr_snap_idx),
      .comm_recov(excp)
  );

  frontend_pkg::bpd_resp_t bpd_resp;
  gshare #(
      .FETCH_W(FETCH_W)
  ) u_gshare (
      .clk(clk),
      .rst(rst),
      .req_pc(fetch_pcs[0]),
      .ghr(ghr),
      .resp(bpd_resp),
      .upd_req_idx(gshare_upd_idx),
      .upd_req_taken(gshare_upd_taken),
      .upd_req_valid(gshare_upd_valid)
  );

  frontend_pkg::brdec_resp_t brdec_resp;

  br_decoder #(
      .FETCH_W(FETCH_W),
      .RA(1)
  ) u_br_decoder (
      .instr(instrs),
      .pcs(pcs_F1),
      .brdec_resp(brdec_resp)
  );

  // output from br_checker
  logic [FETCH_W-1:0] alive_branch_mask;
  types::pc_t predict_pcs[FETCH_W];

  frontend_pkg::branch_type_t br_type;

  br_checker #(
      .FETCH_W(FETCH_W)
  ) u_br_checker (
      .btb_resp(btb_resp),
      .bpd_resp(bpd_resp),
      .ras_target(ras_target),
      .brdec_resp(brdec_resp),
      .pc_seq(pc_seq),
      .instr_valid(instr_valid),
      .target_pc(target_pc),
      .predict_pcs(predict_pcs),
      .br_type(br_type),
      .alive_branch_mask(alive_branch_mask),
      .alive_branch_count(alive_branch_count),
      .takens(takens),
      .is_call(is_call),
      .is_ret(is_ret)
  );

  ooo_types::br_tag_t brtag_resp[FETCH_W];
  logic [FETCH_W-1:0] brtag_resp_valid;
  ooo_types::brmask_t brmask_resp[FETCH_W];

  brtag_mng #(
      .MAX_BR (MAX_BR),
      .FETCH_W(FETCH_W)
  ) u_brtag_mng (
      .clk(clk),
      .rst(rst),
      .req(alive_branch_mask),
      .resp(brtag_resp),
      .resp_valid(brtag_resp_valid),
      .resolve_mask(br_update.resolve_mask),
      .kill_mask(br_update.kill_mask),
      .brmask(brmask_resp),
      .empty(brtag_empty)
  );

  // output of ftq
  ooo_types::ftq_idx_t ftq_next_idx;

  frontend_pkg::fetch_packet_t fetchq_din;
  always_comb begin : calc_fetchq_din
    // packed-unpackedの変換が入っている。パフォーマンスに影響があるかは不明。
    for (int i = 0; i < FETCH_W; i++) begin
      fetchq_din.instr[i]      = instrs[i];
      fetchq_din.brmask[i]     = brmask_resp[i];
      fetchq_din.brtag[i]      = brtag_resp[i];
      fetchq_din.predict_pc[i] = predict_pcs[i];
    end
    fetchq_din.ftq_idx = ftq_next_idx;
    fetchq_din.pc_head = pcs_F1[0];
    fetchq_din.valid   = instr_valid;
  end

  fetchq #(
      .IDX_WIDTH(FETCHQ_IDX_WIDTH)
  ) u_fetchq (
      .clk  (clk),
      .rst  (rst),
      .din  (fetchq_din),
      .push (fire_instr),
      .dout (fetchq_dout),
      .pop  (fetchq_pop),
      .ready(fetchq_ready),
      .valid(fetchq_valid)
  );

  frontend_pkg::ftq_data_t ftq_din;
  always_comb begin : calc_ftq_din
    ftq_din.pc = pcs_F1[0];
    ftq_din.bp_data.ghr_snap_idx = snap_push_idx;
    ftq_din.bp_data.gshare_idx = bpd_resp.gshare_idx;
  end

  ftq #(
      .IDX_WIDTH(FTQ_IDX_WIDTH)
  ) u_ftq (
      .clk(clk),
      .rst(rst),
      .din(ftq_din),
      .push(fire_instr && |alive_branch_mask),
      .next_ftq_idx(ftq_next_idx),
      .ftq_idx_req_redirect(br_update.ftq_idx),
      .ftq_resp_redirect(ftq_resp_redirect),
      .pop(ftq_pop),
      .full(ftq_full),
      .empty(ftq_empty),
      .restore_en(ber),
      .restore_idx(br_update.ftq_idx)
  );

endmodule


`default_nettype wire
