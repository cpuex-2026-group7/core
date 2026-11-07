`timescale 1ns / 1ps
`default_nettype none

module fu_fsqrt_top
  import types::*;
(
  input wire logic  clk,
  input wire logic  rst,
  input wire logic  start,
  input wire logic  abort,
  input wire word_t rs1_val,

  output logic  busy,
  output logic  done,
  output word_t result
);

endmodule

`default_nettype wire
