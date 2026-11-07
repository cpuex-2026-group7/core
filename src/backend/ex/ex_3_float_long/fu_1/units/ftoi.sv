`timescale 1ns / 1ps
`default_nettype none

module ftoi
  import types::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,

  output word_t result
);

  word_t rs1_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
  end

endmodule

`default_nettype wire
