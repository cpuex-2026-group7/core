`timescale 1ns / 1ps
`default_nettype none

module frontend #(
    parameter int BTB_TAG_WIDTH = 9,
    parameter int BTB_IDX_WIDTH = 7,
    parameter int FETCHQ_IDX_WIDTH = 5,
    parameter int FTQ_IDX_WIDTH = 5,
    parameter types::addr_t RESET_PC = '0
) (
    input wire logic clk,
    input wire logic rst,
    input wire types::addr_t pc_backend_redirect,
    input wire logic backend_redirect,
    input wire types::addr_t pc_backend_redirect_src,
    output isa::instr_t fetchq_dout,
    input logic fetchq_pop,
    output logic fetchq_valid,
    input wire logic [FTQ_IDX_WIDTH-1:0] ftq_get_idx,
    output frontend_pkg::ftq_data_t ftq_dout,
    input wire logic ftq_pop,
    input wire logic [FTQ_IDX_WIDTH-1:0] ftq_restore_idx
);

  types::addr_t pc_F0;  // combinational logic
  types::addr_t pc_F0_next;  // combinational logic
  types::addr_t pc_F1, pc_F2, pc_F3;  // reg
  isa::instr_t instr_F2, instr_F3;
  frontend_pkg::btb_resp_t btb_resp_F0, btb_resp_F2, btb_resp_F3;
  frontend_pkg::bpd_resp_t bpd_resp_F3;
  frontend_pkg::branch_type_t branch_type_F3;
  types::addr_t pc_frontend_redirect_F3;
  logic frontend_redirect_F3;
  logic ftq_full, ftq_empty;
  frontend_pkg::ftq_data_t ftq_din_F3;
  logic instr_valid_F1, instr_valid_F2, instr_valid_F3;
  logic stall;
  logic frontend_advance;
  logic reset_pending;
  logic frontend_redirect_fire;
  logic flush;
  frontend_pkg::pc_src_F0_t pc_src_F0;
  logic fetchq_ready, ftq_ready;
  logic fire_instr;  // push to fetch queue and FTQ


  assign ftq_ready = !ftq_full | (branch_type_F3 == frontend_pkg::BR_NONE);

  // Only a valid F3 instruction needs space in the output queues.
  assign stall = instr_valid_F3 & !(fetchq_ready & ftq_ready);
  // A backend redirect replaces the old pipeline even when its output is blocked.
  assign frontend_advance = !stall | backend_redirect;
  assign fire_instr = instr_valid_F3 & !stall & !backend_redirect;
  assign frontend_redirect_fire = frontend_redirect_F3 & !stall & !backend_redirect;
  assign flush = backend_redirect | frontend_redirect_fire;

  assign pc_src_F0 = backend_redirect ?
    frontend_pkg::PCSRCF0_BRD :
    (frontend_redirect_F3 ? frontend_pkg::PCSRCF0_FRD :
    ((instr_valid_F1 & btb_resp_F0.valid) ?
      frontend_pkg::PCSRCF0_BTB : frontend_pkg::PCSRCF0_SEQ));

  assign pc_F0_next = pc_F1 + types::addr_t'(1);

  always_comb begin
    // A backend redirect may also replace the initial reset request.
    if (reset_pending && !backend_redirect) begin
      pc_F0 = RESET_PC;
    end else begin
      unique case (pc_src_F0)
        frontend_pkg::PCSRCF0_SEQ: pc_F0 = pc_F0_next;
        frontend_pkg::PCSRCF0_BTB: pc_F0 = btb_resp_F0.target;
        frontend_pkg::PCSRCF0_FRD: pc_F0 = pc_frontend_redirect_F3;
        frontend_pkg::PCSRCF0_BRD: pc_F0 = pc_backend_redirect;
        default: pc_F0 = '0;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      reset_pending <= 1'b1;
      pc_F1 <= '0;
      pc_F2 <= '0;
      pc_F3 <= '0;
      instr_F3 <= '0;
      btb_resp_F3 <= '0;
    end else if (frontend_advance) begin
      reset_pending <= 1'b0;
      pc_F1 <= pc_F0;
      pc_F2 <= pc_F1;
      pc_F3 <= pc_F2;
      instr_F3 <= instr_F2;
      btb_resp_F3 <= btb_resp_F2;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      instr_valid_F1 <= '0;
      instr_valid_F2 <= '0;
      instr_valid_F3 <= '0;
    end else if (frontend_advance) begin
      // F0 already selects the redirect target; this new request is valid.
      instr_valid_F1 <= 1'b1;
      instr_valid_F2 <= instr_valid_F1 & !flush;
      instr_valid_F3 <= instr_valid_F2 & !flush;
    end
  end

  i_mem u_i_mem (
      .clk(clk),
      .en(frontend_advance),
      .addr(pc_F0),
      .instr(instr_F2)
  );

  btb #(
      .TAG_WIDTH(BTB_TAG_WIDTH),
      .IDX_WIDTH(BTB_IDX_WIDTH)
  ) u_btb (
      .clk(clk),
      .rst(rst),
      .en(frontend_advance),
      .pc(pc_F0),
      .resp(btb_resp_F2),
      .resp_F0(btb_resp_F0),
      .update_en(frontend_redirect_fire | backend_redirect),
      .update_validness(backend_redirect | branch_type_F3 != frontend_pkg::BR_NONE),// only branch/jump cause backend redirection.
      .update_pc(backend_redirect ? pc_backend_redirect_src : pc_F3),
      .update_target(backend_redirect ? pc_backend_redirect : pc_frontend_redirect_F3)
  );

  bpd u_bpd (.resp(bpd_resp_F3));

  br_decoder u_br_decoder (
      .instr(instr_F3),
      .pc(pc_F3),
      .branch_type(branch_type_F3),
      .target_pc(pc_frontend_redirect_F3)
  );

  br_checker u_br_checker (
      .btb_resp(btb_resp_F3),
      .bpd_resp(bpd_resp_F3),
      .brdec_btype(branch_type_F3),
      .brdec_target_pc(pc_frontend_redirect_F3),
      .instr_valid_F3(instr_valid_F3),
      .redirect_F(frontend_redirect_F3)
  );

  fetchq #(
      .IDX_WIDTH(FETCHQ_IDX_WIDTH)
  ) u_fetchq (
      .clk  (clk),
      .rst  (rst | backend_redirect),
      .din  (instr_F3),
      .push (fire_instr),
      .dout (fetchq_dout),
      .pop  (fetchq_pop),
      .ready(fetchq_ready),
      .valid(fetchq_valid)
  );

  assign ftq_din_F3.pc = pc_F3;
  assign ftq_din_F3.bp_data.btype = branch_type_F3;
  ftq #(
      .IDX_WIDTH(FTQ_IDX_WIDTH)
  ) u_ftq (
      .clk(clk),
      .rst(rst),
      .din(ftq_din_F3),
      .push(fire_instr & (branch_type_F3 != frontend_pkg::BR_NONE)),
      .restore_en(backend_redirect),// on backend_redirect, reject push. this should be okay because F3 should be flushed in that case.
      .restore_idx(ftq_restore_idx),
      .get_idx(ftq_get_idx),
      .dout(ftq_dout),
      .pop(ftq_pop),
      .full(ftq_full),
      .empty(ftq_empty)
  );

endmodule

`default_nettype wire
