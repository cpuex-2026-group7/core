`timescale 1ns / 1ps
`default_nettype none

module add
  import types::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire logic     aux,  // 1でaddi
  input wire word_t    rs1_val,
  input wire word_t    rs2_val,
  input wire imm_raw_t imm,

  output word_t result
);

  logic     aux_ff;
  word_t    rs1_ff;
  word_t    rs2_ff;
  imm_raw_t imm_ff;

  always_ff @(posedge clk) begin
    aux_ff <= aux;
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
    imm_ff <= imm;
  end

endmodule

`default_nettype wire
