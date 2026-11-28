`timescale 1ns / 1ps
`default_nettype none

module frontend #(
    parameter int BTB_TAG_WIDTH = 9,
    parameter int BTB_IDX_WIDTH = 7,
    parameter int FETCHQ_IDX_WIDTH = 5,
    parameter int FTQ_IDX_WIDTH = 5,
    parameter types::pc_t RESET_PC = '0,
    parameter int FETCH_W = 2,
    parameter int MAX_BR = 8,
    parameter int BTB_ENTRY_SIZE = 128,
    parameter int RAS_SIZE = 8,
    parameter int GSHARE_ENTRY_SIZE = 128,
    parameter int GHR_ENTRY = 16
) (
    input wire logic clk,
    input wire logic rst,

    input wire types::pc_t pc_backend_redirect,
    input wire logic backend_redirect,
    input wire types::pc_t pc_backend_redirect_src,

    input wire ooo_types::brmask_t br_kill_mask,
    input wire ooo_types::brmask_t br_rslv_mask,

    output frontend_pkg::fetch_packet_t fetchq_dout,
    input logic fetchq_pop,
    output logic fetchq_valid,

    input wire logic [FTQ_IDX_WIDTH-1:0] ftq_get_idx,
    output frontend_pkg::ftq_data_t ftq_dout,
    input wire logic ftq_pop,
    input wire logic [FTQ_IDX_WIDTH-1:0] ftq_restore_idx,

    input wire ooo_types::br_update_t br_update_back
);

  types::pc_t pc_head_F0;  // combinational logic
  types::pc_t pc_head_F0_next;  // combinational logic
  types::pc_t pc_head_F1, pc_head_F2, pc_head_F3;  // reg

  types::pc_t pcs_F0[FETCH_W], pcs_F1[FETCH_W], pcs_F2[FETCH_W], pcs_F3[FETCH_W];

  isa::instr_t instr_F2[FETCH_W], instr_F3[FETCH_W];
  logic [FETCH_W-1:0] instr_valid_F1, instr_valid_F2, instr_valid_F3;
  logic [FETCH_W-1:0] instr_valid_F3_new;

  frontend_pkg::nlp_resp_t nlp_resp_F1, nlp_resp_F2, nlp_resp_F3;
  frontend_pkg::bpd_resp_t bpd_resp_F3[FETCH_W];

  frontend_pkg::branch_type_t branch_type_F3[FETCH_W];
  logic [FETCH_W-1:0] alive_branch_jmp_F3;
  logic branch_jmp_included_F3;  // 1 if branch/jmp is included in fetch packet.

  types::pc_t pc_frontend_redirect_F3;
  types::pc_t pc_frontend_redirect_F3_final;
  logic frontend_redirect_F3;

  logic ftq_full, ftq_empty;
  frontend_pkg::ftq_data_t ftq_din_F3;

  logic brtag_empty;

  logic stall;
  logic frontend_advance;
  logic reset_pending;
  logic frontend_redirect_fire;
  logic flush;

  frontend_pkg::pc_src_F0_t pc_src_F0;

  logic fetchq_ready, ftq_ready;
  logic fire_instr;  // push to fetch queue and FTQ

  ooo_types::ftq_idx_t next_ftq_idx;

  ooo_types::br_tag_t brtag_mng_resp[FETCH_W];
  logic [FETCH_W-1:0] brtag_mng_resp_val;
  ooo_types::brmask_t brtag_mng_brmask[FETCH_W];

  logic [FETCH_W-1:0] is_call_F3;
  logic [FETCH_W-1:0] is_ret_F3;

  frontend_pkg::branch_type_t br_type_F3_actual;
  logic is_ret_F3_actual;
  logic is_call_F3_actual;
  logic [$clog2(FETCH_W)-1:0] bidx_F3_actual;
  logic is_taken_F3_actual;

  logic ras_empty, ras_full;

  frontend_pkg::ftq_data_t ftq_resp_redirect;

  assign ftq_ready = !ftq_full | !branch_jmp_included_F3;

  // Only a valid F3 instruction needs space in the output queues.
  assign stall = (|instr_valid_F3) &&
  (!(fetchq_ready && ftq_ready) || (brtag_empty && branch_jmp_included_F3));
  // A backend redirect replaces the old pipeline even when its output is blocked.
  assign frontend_advance = !stall || backend_redirect;
  assign fire_instr = (|instr_valid_F3) && !stall && !backend_redirect;
  assign frontend_redirect_fire = frontend_redirect_F3 && !stall && !backend_redirect;
  assign flush = backend_redirect || frontend_redirect_fire;

  always_comb begin : calc_pcsrc
    if (backend_redirect) begin
      pc_src_F0 = frontend_pkg::PCSRCF0_BRD;
    end else if (frontend_redirect_F3) begin
      pc_src_F0 = frontend_pkg::PCSRCF0_FRD;
    end else if ((|instr_valid_F1) && (nlp_resp_F1.valid && nlp_resp_F1.taken)) begin
      pc_src_F0 = frontend_pkg::PCSRCF0_NLP;
    end else begin
      pc_src_F0 = frontend_pkg::PCSRCF0_SEQ;
    end
  end

  assign pc_head_F0_next = pc_head_F1 + types::pc_t'(FETCH_W);

  always_comb begin : calc_brjmp_inc
    branch_jmp_included_F3 = 1'b0;
    for (int i = 0; i < FETCH_W; i++) begin
      if (branch_type_F3[i] != frontend_pkg::BR_NONE) branch_jmp_included_F3 = 1'b1;
    end
  end

  always_comb begin : calc_pcs
    for (int i = 0; i < FETCH_W; i++) begin
      pcs_F0[i] = pc_head_F0 + types::pc_t'(i);
      pcs_F1[i] = pc_head_F1 + types::pc_t'(i);
      pcs_F2[i] = pc_head_F2 + types::pc_t'(i);
      pcs_F3[i] = pc_head_F3 + types::pc_t'(i);
    end
  end

  always_comb begin : assign_next_pc
    // A backend redirect may also replace the initial reset request.
    if (reset_pending && !backend_redirect) begin
      pc_head_F0 = RESET_PC;
    end else begin
      unique case (pc_src_F0)
        frontend_pkg::PCSRCF0_SEQ: pc_head_F0 = pc_head_F0_next;
        frontend_pkg::PCSRCF0_NLP: pc_head_F0 = nlp_resp_F1.target;
        frontend_pkg::PCSRCF0_FRD: pc_head_F0 = pc_frontend_redirect_F3_final;
        frontend_pkg::PCSRCF0_BRD: pc_head_F0 = pc_backend_redirect;
        default: pc_head_F0 = '0;
      endcase
    end
  end

  always_comb begin : calc_alive_brjmp_F3
    for (int i = 0; i < FETCH_W; i++) begin
      if (branch_type_F3[i] != frontend_pkg::BR_NONE) begin
        alive_branch_jmp_F3[i] = instr_valid_F3_new[i];
      end
    end
  end

  always_ff @(posedge clk) begin : pipeline_pc_instr
    if (rst) begin
      reset_pending <= 1'b1;
      pc_head_F1 <= '0;
      pc_head_F2 <= '0;
      pc_head_F3 <= '0;
      for (int i = 0; i < FETCH_W; i++) instr_F3[i] <= '0;
      nlp_resp_F3 <= '0;
    end else if (frontend_advance) begin
      reset_pending <= 1'b0;
      pc_head_F1 <= pc_head_F0;
      pc_head_F2 <= pc_head_F1;
      pc_head_F3 <= pc_head_F2;
      for (int i = 0; i < FETCH_W; i++) instr_F3[i] <= instr_F2[i];
      nlp_resp_F3 <= nlp_resp_F2;
    end
  end

  always_ff @(posedge clk) begin : pipeline_instr_valid
    if (rst) begin
      instr_valid_F1 <= '0;
      instr_valid_F2 <= '0;
      instr_valid_F3 <= '0;
    end else if (frontend_advance) begin
      // F0 already selects the redirect target; this new request is valid.
      instr_valid_F1 <= '1;
      instr_valid_F2 <= instr_valid_F1 & {FETCH_W{(!flush)}};
      instr_valid_F3 <= instr_valid_F2 & {FETCH_W{(!flush)}};
    end
  end

  i_mem #(
      .FETCH_W(FETCH_W)
  ) u_i_mem (
      .clk(clk),
      .en(frontend_advance),
      .addr(pcs_F0),
      .instr(instr_F2)
  );

  // TODO consider and connect remaining wires.

  // btb update の ret jmpあたりがあやしい
  // 実際のret jmpはFTQには入らない
  // br_update_tでおくられてくるので
  // その情報で読み取る必要がある
  // ftq_data_tを変更して、あらかじめ
  // bitvectorでもっておくのがよさそう
  nlp_top #(
      .FETCH_W(FETCH_W),
      .BTB_ENTRY_SIZE(BTB_ENTRY_SIZE),
      .BTB_TAG_WIDTH(BTB_TAG_WIDTH),
      .RAS_SIZE(RAS_SIZE)
  ) u_nlp_top (
      .clk(clk),
      .rst(rst),
      .nlp_pc_key(pc_head_F0),
      .nlp_resp_F1(nlp_resp_F1),
      .nlp_resp_F2(nlp_resp_F2),
      .nlp_pipeline_en(frontend_advance),
      .btb_update_en(frontend_redirect_fire || (backend_redirect && br_update_back.taken)),
      .btb_update(
      '{
          pc: backend_redirect ? ftq_resp_redirect.pc : pc_head_F3,
          valid: backend_redirect || branch_jmp_included_F3,
          ret: backend_redirect ? ftq_resp_redirect.bp_data.ret_actual : is_ret_F3_actual,
          jmp:
          backend_redirect
          ?
          (
          ftq_resp_redirect.bp_data.btype_actual
          ==
          frontend_pkg::BR_JAL
          ||
          ftq_resp_redirect.bp_data.btype_actual
          ==
          frontend_pkg::BR_JALR
          )
          : (
          br_type_F3_actual == frontend_pkg::BR_JAL || br_type_F3_actual == frontend_pkg::BR_JALR
          ),
          bidx:
          backend_redirect
          ?
          $clog2(FETCH_W)'(br_update_back.pc - ftq_resp_redirect.pc)
          :
          bidx_F3_actual,
          target: backend_redirect ? ftq_resp_redirect.target : pc_frontend_redirect_F3_final
      }
      ),
      .ras_push(is_call_F3_actual),
      .ras_push_pc(pc_frontend_redirect_F3_final),
      .ras_pop(is_ret_F3_actual),
      .ras_empty(ras_empty),
      .ras_full(ras_full)
  );

  logic [GHR_SIZE-1:0] ghr_gshare_wire;

  gshare #(
      .GSHARE_ENTRY_SIZE(GSHARE_ENTRY_SIZE),
      .FETCH_W(FETCH_W)
  ) u_gshare (
      .clk(clk),
      .rst(rst),
      .req_pcs(pcs_F0),
      .ghr(ghr_gshare_wire),
      .resp(bpd_resp_F3),
      .upd_req_pc(),
      .upd_req_taken(),
      .upd_req_valid()
  );

  ghr #(
      .GHR_ENTRY(GHR_ENTRY),
      .MAX_BR(MAX_BR)
  ) u_ghr (
      .clk(clk),
      .rst(rst),
      .ghr_push_spec(),
      .ghr_push_comm(),
      .snap_push(),
      .snap_push_idx(),
      .snap_recov(),
      .snap_recov_idx(),
      .comm_recov()
  );

  // bpd #(.FETCH_W(FETCH_W)) u_bpd (.resp(bpd_resp_F3));

  br_decoder u_br_decoder (
      .instr(instr_F3),
      .pc(pc_head_F3),
      .branch_type(branch_type_F3),
      .target_pc(pc_frontend_redirect_F3),
      .call(is_call_F3),
      .ret(is_ret_F3)
  );

  br_checker u_br_checker (
      .nlp_resp(nlp_resp_F3),
      .bpd_resp(bpd_resp_F3),
      .brdec_btype(branch_type_F3),
      .brdec_target_pc(pc_frontend_redirect_F3),
      .instr_valid_F3(instr_valid_F3),
      .is_call_F3(is_call_F3),
      .is_ret_F3(is_ret_F3),
      .instr_valid_F3_new(instr_valid_F3_new),
      .redirect_F(frontend_redirect_F3),
      .redirect_F_target(pc_frontend_redirect_F3_final),
      .br_type_F3_actual(br_type_F3_actual),
      .is_ret_F3_actual(is_ret_F3_actual),
      .is_call_F3_actual(is_call_F3_actual),
      .bidx(bidx_F3_actual),
      .is_taken_actual(is_taken_F3_actual)
  );

  brtag_mng u_brtag_mng (
      .rst(rst),
      .clk(clk),
      .req(alive_branch_jmp_F3),
      .resp(brtag_mng_resp),
      .resp_valid(brtag_mng_resp_val),
      .resolve_mask(br_rslv_mask),
      .kill_mask(br_kill_mask),
      .brmask(brtag_mng_brmask),
      .empty(brtag_empty)
  );

  fetchq #(
      .IDX_WIDTH(FETCHQ_IDX_WIDTH)
  ) u_fetchq (
      .clk(clk),
      .rst(rst | backend_redirect),
      .din(
      '{
          instr: instr_F3,
          ftq_idx: next_ftq_idx,
          brmask: brtag_mng_brmask,
          brtag: brtag_mng_resp,
          pc_head: pc_head_F3,
          predict_pc: nlp_resp_F3.target
      }
      ),
      .push(fire_instr),
      .dout(fetchq_dout),
      .pop(fetchq_pop),
      .ready(fetchq_ready),
      .valid(fetchq_valid)
  );

  // assign ftq_din_F3.pc = pc_head_F3;
  // assign ftq_din_F3.bp_data.btype = branch_type_F3;

  // jmpのデータはない。なぜなら、br_typeに真に含まれる情報だから。
  always_comb begin : construct_ftq_din_data
    ftq_din_F3.pc = pc_head_F3;
    ftq_din_F3.bp_data.btype_predict = br_type_F3_actual;
    ftq_din_F3.bp_data.predict_bidx = bidx_F3_actual;
    ftq_din_F3.bp_data.ret_predict = is_ret_F3_actual;
    ftq_din_F3.bp_data.predict_taken = is_taken_F3_actual;
    ftq_din_F3.bp_data.btype_actual = frontend_pkg::BR_NONE;  // not yet determined
    ftq_din_F3.bp_data.actually_taken = '0;  // not yet determined
    ftq_din_F3.bp_data.ret_actual = '0;  // not yet determined
  end

  ftq #(
      .IDX_WIDTH(FTQ_IDX_WIDTH)
  ) u_ftq (
      .clk(clk),
      .rst(rst),
      .din(ftq_din_F3),
      .push(fire_instr & (branch_type_F3 != frontend_pkg::BR_NONE)),
      .next_ftq_idx(next_ftq_idx),
      .restore_en(backend_redirect),// on backend_redirect, reject push. this should be okay because F3 should be flushed in that case.
      .restore_idx(ftq_restore_idx),
      .get_idx(ftq_get_idx),
      .dout(ftq_dout),
      .ftq_idx_req_redirect(br_update_back.ftq_idx),
      .ftq_resp_redirect(ftq_resp_redirect),
      .pop(ftq_pop),
      .full(ftq_full),
      .empty(ftq_empty)
  );

endmodule

`default_nettype wire
