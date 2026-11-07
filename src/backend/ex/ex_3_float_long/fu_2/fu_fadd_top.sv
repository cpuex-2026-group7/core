`timescale 1ns / 1ps
`default_nettype none

module fu_fadd_top
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
    .aux(fu_op[0]),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .result(result)
  );

endmodule

`default_nettype wire
