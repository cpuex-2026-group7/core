`timescale 1ns / 1ps
`default_nettype none

module sub
  import types::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output word_t result
);

  word_t rs1_ff;
  word_t rs2_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
  end

endmodule

`default_nettype wire
