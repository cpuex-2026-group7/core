`timescale 1ns / 1ps
`default_nettype none

module fu_alu_top
  import types::*;
  import isa::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire word_t    rs1_val,
  input wire word_t    rs2_val,
  input wire imm_t     imm_type,
  input wire fu_op_t   fu_op,
  input wire imm_raw_t imm,
  input wire pc_t      pc,
  input wire pc_t      predict_pc,

  output word_t result,
  output logic  taken,
  output pc_t   target,
  output logic  mispredict
);

  word_t    rs1_ff;
  word_t    rs2_ff;
  imm_t     imm_type_ff;
  fu_op_t   fu_op_ff;
  imm_raw_t imm_ff;
  pc_t      pc_ff;
  pc_t      predict_pc_ff;

  always_ff @(posedge clk) begin
    rs1_ff        <= rs1_val;
    rs2_ff        <= rs2_val;
    imm_type_ff   <= imm_type;
    fu_op_ff      <= fu_op;
    imm_ff        <= imm;
    pc_ff         <= pc;
    predict_pc_ff <= predict_pc;
  end

endmodule

`default_nettype wire
