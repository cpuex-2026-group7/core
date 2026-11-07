`timescale 1ns / 1ps
`default_nettype none

module fu_fcvt_top
  import types::*;
  import uop_types::*;
(
  input wire logic    clk,
  input wire word_t   rs1_val,
  input wire fu_op_t fu_op,  // itof / ftoi

  output word_t result
);

endmodule

`default_nettype wire
