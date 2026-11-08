`timescale 1ns / 1ps
`default_nettype none

module fli
  import types::*;
(
  input wire logic  clk,
  input wire word_t imm,

  output word_t result
);

  word_t imm_ff;

  always_ff @(posedge clk) begin
    imm_ff <= imm;
  end

  assign result = imm_ff;

endmodule

`default_nettype wire
