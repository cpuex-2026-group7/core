`timescale 1ns / 1ps
`default_nettype none

module sra
  import types::*;
(
  input wire logic        clk,
  input wire word_t       rs1_val,
  input wire signed [5:0] shift,

  output word_t result
);

  logic signed [5:0] shift_ff;
  word_t    rs1_ff;

  always_ff @(posedge clk) begin
    rs1_ff   <= rs1_val;
    shift_ff <= shift;
  end

  always_comb begin
    if (shift_ff[5]) result = rs1_ff << (-shift_ff);
    else result = $signed(rs1_ff) >>> shift_ff;
  end

endmodule

`default_nettype wire
