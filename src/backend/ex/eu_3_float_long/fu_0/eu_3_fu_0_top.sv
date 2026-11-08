`timescale 1ns / 1ps
`default_nettype none

module eu_3_fu_0_top
  import types::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output word_t result
);

  fmul u_fmul (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .result(result)
  );

endmodule

`default_nettype wire
