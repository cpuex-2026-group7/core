`timescale 1ns / 1ps
`default_nettype none

// stallとredirect同時に起きた時こわいかも
module frontend #(
    parameter int BTB_TAG_WIDTH = 9,
    parameter int BTB_IDX_WIDTH = 7,
    parameter int FETCHQ_IDX_WIDTH = 5,
    parameter int FTQ_IDX_WIDTH = 5
) (
    input wire logic clk,
    input wire logic rst,
    input wire types::addr_t pc_backend_redirect,
    input wire logic backend_redirect,
    output isa::instr_t fetchq_dout,
    input logic fetchq_pop,
    input wire logic [FTQ_IDX_WIDTH-1:0] ftq_get_idx,
    output frontend_pkg::ftq_data_t ftq_dout,
    input wire logic ftq_pop
);

  types::addr_t pc_F0, pc_F1, pc_F2, pc_F3;
  isa::instr_t instr_F2, instr_F3;
  frontend_pkg::btb_resp_t btb_resp_F2, btb_resp_F3;
  frontend_pkg::bpd_resp_t bpd_resp_F3;
  frontend_pkg::branch_type_t branch_type_F3;
  types::addr_t pc_frontend_redirect_F3;
  logic frontend_redirect_F3;
  logic fetchq_full, fetchq_empty;
  logic ftq_full, ftq_empty;
  frontend_pkg::ftq_data_t ftq_din_F3;
  logic instr_valid_F2, instr_valid_F3;
  logic stall;
  frontend_pkg::pc_src_F0_t pc_src_F0;

  assign pc_src_F0 = backend_redirect ?
    frontend_pkg::PCSRCF0_BRD :
    (frontend_redirect_F3 ? frontend_pkg::PCSRCF0_FRD : frontend_pkg::PCSRCF0_SEQ);

  assign stall = fetchq_full | ftq_full;

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_F0 <= '0;
    end else if (!stall) begin
      unique case (pc_src_F0)
        frontend_pkg::PCSRCF0_SEQ: pc_F0 <= pc_F0 + types::addr_t'(1);
        frontend_pkg::PCSRCF0_FRD: pc_F0 <= pc_frontend_redirect_F3;
        frontend_pkg::PCSRCF0_BRD: pc_F0 <= pc_backend_redirect;
        default: pc_F0 <= '0;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_F1 <= '0;
      pc_F2 <= '0;
      pc_F3 <= '0;
      instr_F3 <= '0;
      btb_resp_F3 <= '0;
    end else if (!stall) begin
      pc_F1 <= pc_F0;
      pc_F2 <= pc_F1;
      pc_F3 <= pc_F2;
      instr_F3 <= instr_F2;
      btb_resp_F3 <= btb_resp_F2;
    end
  end

  logic not_redirected;
  assign not_redirected = !(frontend_redirect_F3 | backend_redirect);

  always_ff @(posedge clk) begin
    if (rst) begin
      instr_valid_F2 <= '0;
      instr_valid_F3 <= '0;
    end else if (!stall) begin
      instr_valid_F2 <= not_redirected;
      instr_valid_F3 <= instr_valid_F2 & not_redirected;
    end
  end

  i_mem u_i_mem (
      .clk(clk),
      .en(1'b1),
      .addr(pc_F0),
      .instr(instr_F2)
  );

  btb #(
      .TAG_WIDTH(BTB_TAG_WIDTH),
      .IDX_WIDTH(BTB_IDX_WIDTH)
  ) u_btb (
      .clk(clk),
      .rst(rst),
      .pc(pc_F0),
      .resp(btb_resp_F2),
      .update_en(frontend_redirect_F3),  //and more...(maybe)
      .update_pc(pc_F3),
      .update_target(pc_frontend_redirect_F3)
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
      .redirect_F(frontend_redirect_F3)
  );

  fetchq #(
      .IDX_WIDTH(FETCHQ_IDX_WIDTH)
  ) u_fetchq (
      .clk  (clk),
      .rst  (rst),
      .din  (instr_F3),
      .push (instr_valid_F3),
      .dout (fetchq_dout),
      .pop  (fetchq_pop),
      .full (fetchq_full),
      .empty(fetchq_empty)
  );

  assign ftq_din_F3.pc = pc_F3;
  assign ftq_din_F3.bp_data.btype = branch_type_F3;
  ftq #(
      .IDX_WIDTH(FTQ_IDX_WIDTH)
  ) u_ftq (
      .clk(clk),
      .rst(rst),
      .din(ftq_din_F3),
      .push(instr_valid_F3 & (branch_type_F3 != frontend_pkg::BR_NONE)),
      .get_idx(ftq_get_idx),
      .dout(ftq_dout),
      .pop(ftq_pop),
      .full(ftq_full),
      .empty(ftq_empty)
  );

endmodule

`default_nettype wire
