`timescale 1ns / 1ps
`default_nettype none

module sra
  import types::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire word_t    rs1_val,
  input wire imm_raw_t imm,

  output word_t result
);

  word_t    rs1_ff;
  imm_raw_t imm_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    imm_ff <= imm;
  end

endmodule

`default_nettype wire
