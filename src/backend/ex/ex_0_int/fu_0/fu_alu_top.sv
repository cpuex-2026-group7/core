`timescale 1ns / 1ps
`default_nettype none

module fu_alu_top
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

  word_t add_result;
  word_t sub_result;
  word_t sra_result;
  word_t link_result;
  logic  eq_taken;
  logic  lt_taken;
  logic  taken_mispredict;
  logic  not_taken_mispredict;

  add u_add (
    .clk(clk),
    .aux(fu_op[0]),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .imm(imm),
    .result(add_result)
  );

  sub u_sub (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .result(sub_result)
  );

  sra u_sra (
    .clk(clk),
    .rs1_val(rs1_val),
    .imm(imm),
    .result(sra_result)
  );

  cmp_eq u_cmp_eq (
    .clk(clk),
    .aux(fu_op[0]),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .taken(eq_taken)
  );

  cmp_lt u_cmp_lt (
    .clk(clk),
    .aux(fu_op[0]),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .taken(lt_taken)
  );

  link u_link (
    .clk(clk),
    .pc(pc),
    .result(link_result)
  );

  br_target u_br_target (
    .clk(clk),
    .aux({fu_op[2], fu_op[0]}),
    .rs1_val(rs1_val),
    .imm(imm),
    .pc(pc),
    .predict_pc(predict_pc),
    .target(target),
    .taken_mispredict(taken_mispredict),
    .not_taken_mispredict(not_taken_mispredict)
  );

  always_comb begin
    case (fu_op_ff)
      FU_OP_ADD, FU_OP_ADDI: result = add_result;
      FU_OP_SUB:             result = sub_result;
      FU_OP_SRA:             result = sra_result;
      default:               result = link_result;  // jal, jalr。分岐はresultを使わない
    endcase
  end

  always_comb begin
    case (fu_op_ff[3:2])
      2'b00:   taken = fu_op_ff[1] ? lt_taken : eq_taken;
      2'b01:   taken = 1'b1;
      default: taken = 1'b0;
    endcase
  end

  assign mispredict = taken ? taken_mispredict : not_taken_mispredict;

endmodule

`default_nettype wire
