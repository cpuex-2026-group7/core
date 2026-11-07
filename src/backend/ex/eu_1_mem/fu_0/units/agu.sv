`timescale 1ns / 1ps
`default_nettype none

module agu
  import types::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire word_t imm,

  output addr_t addr,
  output word_t data
);

  word_t rs1_ff;
  word_t rs2_ff;
  word_t imm_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
    imm_ff <= imm;
  end

  assign addr = rs1_ff + imm_ff;
  assign data = rs2_ff;

endmodule

`default_nettype wire
