`timescale 1ns / 1ps
`default_nettype none

module add
  import types::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire word_t imm,
  input wire logic  aux,      // 1でaddi

  output word_t result
);

  word_t rs1_ff;
  word_t rs2_ff;
  word_t imm_ff;
  logic  aux_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
    imm_ff <= imm;
    aux_ff <= aux;
  end

  assign result = rs1_ff + (aux_ff ? imm_ff : rs2_ff);

endmodule

`default_nettype wire
