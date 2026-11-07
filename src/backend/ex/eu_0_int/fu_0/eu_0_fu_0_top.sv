`timescale 1ns / 1ps
`default_nettype none

module eu_0_fu_0_top
  import types::*;
  import uop_types::*;
(
  input wire logic   clk,
  input wire word_t  rs1_val,
  input wire word_t  rs2_val,
  input wire fu_op_t fu_op,
  input wire word_t  imm,  // EUで符号拡張したもの
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

  word_t add_result;
  word_t sub_result;
  word_t sra_result;
  word_t pc_plus_1;
  logic  eq_taken;
  logic  lt_taken;
  pc_t   br_target_pc;

  add u_add (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .imm(imm),
    .aux(fu_op[0]),
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
    .shift(imm[5:0]),
    .result(sra_result)
  );

  beq u_beq (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .taken(eq_taken)
  );

  blt u_blt (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .taken(lt_taken)
  );

  pc_plus_1_eu_0 u_pc_plus_1 (
    .clk(clk),
    .pc(pc),
    .result(pc_plus_1)
  );

  br_target u_br_target (
    .clk(clk),
    .rs1_val(rs1_val),
    .pc(pc),
    .ofs(pc_t'(imm)),
    .aux({fu_op[2], fu_op[0]}),
    .target(br_target_pc)
  );

  always_comb begin
    case (fu_op_ff)
      FU_OP_ADD, FU_OP_ADDI: result = add_result;
      FU_OP_SUB:             result = sub_result;
      FU_OP_SRA:             result = sra_result;
      default:               result = pc_plus_1;
    endcase
  end

  always_comb begin
    case (fu_op_ff[3:2])
      2'b00:   taken = fu_op_ff[1] ? lt_taken : eq_taken;
      2'b01:   taken = 1'b1;
      default: taken = 1'b0;
    endcase
  end

  assign target = taken ? br_target_pc : pc_t'(pc_plus_1);
  assign mispredict = taken ? (target != predict_pc_ff) : (pc_t'(pc_plus_1) != predict_pc_ff);

endmodule

`default_nettype wire
