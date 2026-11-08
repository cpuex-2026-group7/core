`timescale 1ns / 1ps
`default_nettype none

module eu_2_fu_0_top
  import types::*;
  import uop_types::*;
(
  input wire logic   clk,
  input wire word_t  rs1_val,
  input wire word_t  rs2_val,
  input wire fu_op_t fu_op,
  input wire word_t  imm,  // ex_topで符号拡張したもの
  input wire pc_t    pc,
  input wire pc_t    predict_pc,

  output word_t result,
  output logic  taken,
  output pc_t   target,
  output logic  mispredict
);

  fu_op_t fu_op_ff;
  pc_t    predict_pc_ff;

  always_ff @(posedge clk) begin
    fu_op_ff      <= fu_op;
    predict_pc_ff <= predict_pc;
  end

  word_t fli_result;
  word_t flhi_result;
  word_t fcsign_result;
  word_t pc_plus_1;
  logic  eq_taken;
  logic  lt_taken;
  pc_t   br_target_pc;

  fli u_fli (
    .clk(clk),
    .imm(imm),
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

  fbeq u_fbeq (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .taken(eq_taken)
  );

  fblt u_fblt (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .taken(lt_taken)
  );

  pc_plus_1_eu_2 u_pc_plus_1 (
    .clk(clk),
    .pc(pc),
    .result(pc_plus_1)
  );

  fbr_target u_fbr_target (
    .clk(clk),
    .pc(pc),
    .ofs(pc_t'(imm)),
    .target(br_target_pc)
  );

  always_comb begin
    case (fu_op_ff)
      FU_OP_FLI:  result = fli_result;
      FU_OP_FLHI: result = flhi_result;
      default:    result = fcsign_result;
    endcase
  end

  always_comb begin
    case (fu_op_ff[3:2])
      2'b00:   taken = fu_op_ff[1] ? lt_taken : eq_taken;
      default: taken = 1'b0;
    endcase
  end

  assign target = taken ? br_target_pc : pc_t'(pc_plus_1);
  assign mispredict = taken ? (target != predict_pc_ff) : (pc_t'(pc_plus_1) != predict_pc_ff);

endmodule

`default_nettype wire
