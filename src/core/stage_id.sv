`timescale 1ns / 1ps
`default_nettype none

module stage_id
  import isa::*;
  import types::*;
(
  input clk,
  if_id_if.cons if_id,
  input logic reg_we_W,
  input rf_idx_t rd_W,
  input word_t result_W,
  input rf_idx_t r_dbg,  // dbg

  id_ex_if.prod id_ex,
  output rf_idx_t rs1_D,
  output rf_idx_t rs2_D,
  output word_t r_dbg_data  // dbg
);

  ctrl_t ctrl_D;
  decoder u_decoder (
    .op  (if_id.data.instr_D.op),
    .ctrl(ctrl_D)
  );
  rf_idx_t rd_D;
  assign rd_D  = {ctrl_D.rd_is_f, if_id.data.instr_D.rd};
  assign rs1_D = {ctrl_D.rs1_is_f, if_id.data.instr_D.rs1};
  assign rs2_D = {ctrl_D.rs2_is_f, if_id.data.instr_D.rs2};

  reg_file u_reg_file (
    .clk(~clk),  // writeをneg edge
    .rd(rd_W),
    .rs1(rs1_D),
    .rs2(rs2_D),
    .write_en(reg_we_W),
    .wdata(result_W),
    .r_dbg(r_dbg),
    .rdata1(id_ex.data.rdata1_D),
    .rdata2(id_ex.data.rdata2_D),
    .r_dbg_data(r_dbg_data)
  );

  imm_extend u_imm_extend (
    .instr(if_id.data.instr_D),
    .extended_imm(id_ex.data.extended_imm_D)
  );

  assign id_ex.data.ctrl_E = ctrl_D;
  assign if_ex.data.rd_E = rd_D;
  assign if_ex.data.rs1_E = rs1_D;
  assign if_ex.data.rs2_E = rs2_D;
  assign id_ex.data.pc_E = if_id.data.pc_D;
  assign id_ex.data.pc_plus_1_E = if_id.data.pc_plus_1_D;
endmodule

`default_nettype wire
