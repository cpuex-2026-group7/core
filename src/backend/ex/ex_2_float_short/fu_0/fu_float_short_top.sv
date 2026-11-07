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

  // 最後のmuxの選択用
  fu_op_t fu_op_ff;

  always_ff @(posedge clk) begin
    fu_op_ff <= fu_op;
  end

  logic  eq_taken;
  logic  lt_taken;
  word_t fli_result;
  word_t flhi_result;
  word_t fcsign_result;
  logic  taken_mispredict;
  logic  not_taken_mispredict;

  fcmp_eq u_fcmp_eq (
    .clk(clk),
    .aux(fu_op[0]),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .taken(eq_taken)
  );

  fcmp_lt u_fcmp_lt (
    .clk(clk),
    .aux(fu_op[0]),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .taken(lt_taken)
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
    .aux(imm[1:0]),
    .rs1_val(rs1_val),
    .result(fcsign_result)
  );

  fbr_target u_fbr_target (
    .clk(clk),
    .imm(imm),
    .pc(pc),
    .predict_pc(predict_pc),
    .target(target),
    .taken_mispredict(taken_mispredict),
    .not_taken_mispredict(not_taken_mispredict)
  );

  always_comb begin
    case (fu_op_ff)
      FU_OP_FLI:  result = fli_result;
      FU_OP_FLHI: result = flhi_result;
      default:    result = fcsign_result;  // 分岐はresultを使わない
    endcase
  end

  assign taken = fu_op_ff[1] ? lt_taken : eq_taken;
  assign mispredict = taken ? taken_mispredict : not_taken_mispredict;

endmodule

`default_nettype wire
