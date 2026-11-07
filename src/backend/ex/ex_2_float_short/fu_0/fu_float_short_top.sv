`timescale 1ns / 1ps
`default_nettype none

module fu_float_short_top
  import types::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire word_t    rs1_val,
  input wire word_t    rs2_val,
  input wire fu_op_t   fu_op,
  input wire imm_raw_t imm,
  input wire pc_t      pc,
  input wire pc_t      predict_pc,

  output word_t result,
  output logic  taken,
  output pc_t   target,
  output logic  mispredict
);

  fu_op_t   fu_op_ff;
  imm_raw_t imm_ff;
  pc_t      pc_ff;
  pc_t      predict_pc_ff;

  always_ff @(posedge clk) begin
    fu_op_ff      <= fu_op;
    imm_ff        <= imm;
    pc_ff         <= pc;
    predict_pc_ff <= predict_pc;
  end

  logic  eq;
  logic  lt;
  word_t fli_result;
  word_t flhi_result;
  word_t fcsign_result;

  fcmp_eq u_fcmp_eq (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .result(eq)
  );

  fcmp_lt u_fcmp_lt (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .result(lt)
  );

  fli u_fli (
    .clk(clk),
    .aux(imm),
    .result(fli_result)
  );

  flhi u_flhi (
    .clk(clk),
    .aux(imm[4:0]),
    .result(flhi_result)
  );

  fcsign u_fcsign (
    .clk(clk),
    .rs1_val(rs1_val),
    .aux(imm[1:0]),
    .result(fcsign_result)
  );

  // D形式のofsはimm[14:0]
  assign target = pc_ff + pc_t'($signed(imm_ff[14:0]));

endmodule

`default_nettype wire
