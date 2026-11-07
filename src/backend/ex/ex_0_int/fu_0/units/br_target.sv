`timescale 1ns / 1ps
`default_nettype none

module br_target
  import types::*;
  import uop_types::*;
(
  input wire logic       clk,
  input wire logic [1:0] aux,  // 0x:条件分岐(pc+D), 10:jal(pc+B), 11:jalr(rs1+C)
  input wire word_t      rs1_val,
  input wire imm_raw_t   imm,
  input wire pc_t        pc,
  input wire pc_t        predict_pc,

  output pc_t  target,
  output logic taken_mispredict,     // target != predict_pc
  output logic not_taken_mispredict  // pc+1 != predict_pc
);

  logic [1:0] aux_ff;
  word_t      rs1_ff;
  imm_raw_t   imm_ff;
  pc_t        pc_ff;
  pc_t        predict_pc_ff;

  always_ff @(posedge clk) begin
    aux_ff        <= aux;
    rs1_ff        <= rs1_val;
    imm_ff        <= imm;
    pc_ff         <= pc;
    predict_pc_ff <= predict_pc;
  end

endmodule

`default_nettype wire
