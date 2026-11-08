`timescale 1ns / 1ps
`default_nettype none

module eu_3_fu_2_top
  import types::*;
  import uop_types::*;
(
  input wire logic   clk,
  input wire word_t  rs1_val,
  input wire word_t  rs2_val,
  input wire fu_op_t fu_op,

  output word_t result
);

  fadd u_fadd (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(fu_op[0]),
    .result(result)
  );

endmodule

`default_nettype wire
