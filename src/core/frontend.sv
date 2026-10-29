`timescale 1ns / 1ps
`default_nettype none

module frontend #(
    parameter int BTB_TAG_WIDTH = 9,
    parameter int BTB_IDX_WIDTH = 7
) (
    input wire logic clk,
    input wire logic rst
);

  types::addr_t pc_F0, pc_F1, pc_F2, pc_F3;
  types::instr_t instr_F2, instr_F3;
  frontend::btb_resp_t btb_resp_F2;
  frontend::bpd_resp_t bpd_resp_F3;
  frontend::branch_type_t branch_type_F3;
  types::addr_t target_pc_F3;

  always_ff begin
    unique case (pc_src_F0)
      PCSRCF0_SEQ: pc_F0 <= pc_F0 + types::addr_t'(1);
      PCSRCF0_FRD: pc_F0 <= Todo;
      PCSRCF0_BRD: pc_F0 <= Todo;
      default: pc_F0 <= '0;
    endcase
  end

  i_mem u_i_mem (
      .clk(clk),
      .en(TODO),
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
      .update_en(TODO),
      .update_pc(TODO),
      .update_target(TODO)
  );

  bpd u_bpd (.resp(bpd_resp_F3));

  br_decoder u_br_decoder (
      .instr(instr_F3),
      .pc(pc_F3),
      .branch_type(branch_type_F3),
      .target_pc(target_pc_F3)
  );

  br_checker u_br_checker (TODO);

  fetchq u_fetchq (TODO);

  ftq u_ftq (TODO);


endmodule

`default_nettype wire
